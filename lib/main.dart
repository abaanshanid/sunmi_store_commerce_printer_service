import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // REQUIRED FOR SystemNavigator.pop()
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:sunmi_printer_plus/sunmi_printer_plus.dart';
import 'package:xml/xml.dart';

import 'render_epos_image.dart';

// ==========================================
// CONSTANTS & HELPERS
// ==========================================
const int receiptImageTargetWidth = 576;
const int receiptTrimThreshold = 240;

void logToConsole(String message) {
  debugPrint("[ePOS Interceptor] $message");
}

// ==========================================
// DATA MODEL: PARSED RECEIPT
// ==========================================
class ParsedReceipt {
  String headerText = 'STORE NAME\nاسم المتجر';
  String printDateTime = 'N/A';
  String store = 'N/A';
  String salesEmp = 'N/A';
  String cashier = 'Administrator';
  String receiptNo = 'N/A';
  String units = '0';
  String grossSale = '0.00';
  String receiptTotal = '0.00';
  String barcodeData = '';

  List<Map<String, String>> items = [];
  List<Map<String, String>> tenders = [];
  List<Uint8List> images = [];
}

// ==========================================
// 1. BACKGROUND SERVICE INITIALIZATION
// ==========================================
Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'sunmi_epos_channel',
    'Sunmi Store Commerce Printer Service Running',
    description: 'Keeps the HTTP server alive to intercept print jobs.',
    importance: Importance.high,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
  FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'sunmi_epos_channel',
      initialNotificationTitle: 'ePOS Interceptor Active',
      initialNotificationContent: 'Listening on Port 9100',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(autoStart: false, onForeground: onStart),
  );
}

// ==========================================
// 2. BACKGROUND ENTRY POINT (Isolate)
// ==========================================
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  HttpServer? server;

  logToConsole("Service Isolate Started.");

  try {
    await SunmiPrinter.bindingPrinter();
    logToConsole("Printer Bound successfully in background.");
  } catch (e) {
    logToConsole("ERROR: Printer binding failed: $e");
  }

  try {
    server = await HttpServer.bind(InternetAddress.anyIPv4, 9100, shared: true);
    logToConsole("Interceptor Active! Listening on port 9100...");

    server.listen((HttpRequest request) async {
      if (request.method == 'POST') {
        try {
          final payload = await utf8.decoder.bind(request).join();
          await processPayload(payload);

          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType("text", "xml", charset: "utf-8")
            ..write(
              '<?xml version="1.0" encoding="utf-8"?><response success="true" code="SUCCESS" status="0"/>',
            );
        } catch (e) {
          logToConsole("ERROR processing payload: $e");
          request.response.statusCode = HttpStatus.internalServerError;
        } finally {
          await request.response.close();
        }
      } else {
        request.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..write('Accepts POST payloads only.');
        await request.response.close();
      }
    });
  } catch (error) {
    logToConsole("CRITICAL ERROR: Server failed to bind: $error");
  }

  service.on('stopService').listen((event) async {
    logToConsole("Shutting down interceptor...");
    await server?.close(force: true);
    await service.stopSelf();
  });
}

// ==========================================
// 3. TOP-LEVEL LOGIC
// ==========================================
Future<void> processPayload(String xmlSource) async {
  ParsedReceipt receipt = await parseXmlToReceipt(xmlSource);
  await printReceipt(receipt);
}

Future<ParsedReceipt> parseXmlToReceipt(String xmlSource) async {
  ParsedReceipt receipt = ParsedReceipt();
  String fullText = "";

  try {
    final document = XmlDocument.parse(xmlSource);
    final eposPrint = document.findAllElements('epos-print').firstOrNull;
    if (eposPrint == null)
      throw Exception("Invalid XML: <epos-print> not found");

    for (final element in eposPrint.children) {
      if (element is! XmlElement) continue;
      final tag = element.name.local.toLowerCase();

      if (tag == 'text') {
        fullText += element.innerText;
      } else if (tag == 'barcode') {
        receipt.barcodeData = element.innerText.trim();
      } else if (tag == 'image') {
        Uint8List? decodedImg = await renderEposImagePng(
          element,
          onLog: logToConsole,
        );
        if (decodedImg != null) receipt.images.add(decodedImg);
      }
    }

    fullText = fullText.replaceAll('\r', '');
    List<String> lines = fullText.split('\n');
    bool inTenderSection = false;

    List<String> headerLinesExtract = [];
    for (String line in lines) {
      String trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.toLowerCase().contains('print date')) continue;
      if (trimmed.toLowerCase().contains('date & time') ||
          trimmed.contains('التاريخ والوقت')) break;
      headerLinesExtract.add(trimmed);
    }
    if (headerLinesExtract.isNotEmpty) {
      receipt.headerText = headerLinesExtract.join('\n');
    }

    String singleLineText = fullText.replaceAll('\n', ' ');
    var dateMatch = RegExp(
        r'(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\s+(\d{1,2}:\d{2}(?::\d{2})?\s*[A-Za-z]{2})')
        .firstMatch(singleLineText);
    if (dateMatch != null) {
      receipt.printDateTime =
          "${dateMatch.group(1)} ${dateMatch.group(2)}".trim();
    }

    for (String line in lines) {
      if (line.contains('Store')) {
        receipt.store =
            RegExp(r'Store\s*:\s*([A-Za-z0-9]+)').firstMatch(line)?.group(1) ??
                receipt.store;
      }
      if (line.contains('Emp.No')) {
        receipt.salesEmp =
            RegExp(r'Emp\.No\s*:\s*(\d+)').firstMatch(line)?.group(1) ??
                receipt.salesEmp;
      }
      if (line.contains('Cashier')) {
        receipt.cashier =
            RegExp(r'Cashier\s*:\s*(.+)').firstMatch(line)?.group(1)?.trim() ??
                receipt.cashier;
      }
      if (line.contains('Receipt #') || line.contains('الفاتورة:')) {
        receipt.receiptNo =
            RegExp(r'([A-Z0-9]{10,})').firstMatch(line)?.group(1) ??
                receipt.receiptNo;
      }
      if (line.contains('Units')) {
        receipt.units = line
            .trim()
            .split(RegExp(r'\s+'))
            .last
            .replaceAll(RegExp(r'[()]'), '');
      }
      if (line.contains('Gross Sale')) {
        receipt.grossSale = line
            .trim()
            .split(RegExp(r'\s+'))
            .last
            .replaceAll(RegExp(r'[()]'), '');
      }
      if (line.contains('Receipt Total')) {
        receipt.receiptTotal = line
            .trim()
            .split(RegExp(r'\s+'))
            .last
            .replaceAll(RegExp(r'[()]'), '');
      }

      if (line.toLowerCase().contains('tendered')) {
        inTenderSection = true;
        continue;
      }

      if (inTenderSection) {
        String trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed.contains('Customer Signature') ||
            trimmed.contains('توقيع') ||
            trimmed.contains('===') ||
            (receipt.receiptNo != 'N/A' &&
                trimmed.contains(receipt.receiptNo))) {
          inTenderSection = false;
          continue;
        }

        List<String> parts = trimmed.split(RegExp(r'\s+'));
        if (parts.length >= 2 && RegExp(r'\d').hasMatch(parts.last)) {
          String val = parts.last.replaceAll(RegExp(r'[a-zA-Z()]'), '');
          if (parts.last.contains('(') || parts.last.contains('-')) {
            if (!val.startsWith('-')) val = "-$val";
          }
          String name = parts.sublist(0, parts.length - 1).join(' ').trim();
          receipt.tenders.add({'name': name, 'value': val});
        }
      }
    }

    if (receipt.barcodeData.isEmpty) receipt.barcodeData = receipt.receiptNo;

    Map<String, String>? currentItem;
    bool inItemsSection = false;

    for (int i = 0; i < lines.length; i++) {
      String line = lines[i];
      String trimmed = line.trim();

      if (trimmed.isEmpty) continue;
      if (trimmed.contains('Sr.#') &&
          (trimmed.contains('Desc') || trimmed.contains('الوصف'))) {
        inItemsSection = true;
        continue;
      }
      if (inItemsSection && trimmed.contains('ALU') && trimmed.contains('QTY')) {
        continue;
      }
      if (inItemsSection && trimmed.contains('---')) continue;
      if (inItemsSection && trimmed.contains('===')) continue;

      if (inItemsSection &&
          (trimmed.startsWith('Units') || trimmed.contains('Gross Sale'))) {
        inItemsSection = false;
        if (currentItem != null) {
          receipt.items.add(currentItem);
          currentItem = null;
        }
        continue;
      }

      if (!inItemsSection) continue;

      List<String> parts = trimmed.split(RegExp(r'\s+'));
      if (parts.isEmpty) continue;

      bool isPriceLine = parts.length >= 4 &&
          RegExp(r'^-?\d+(\.\d+)?$').hasMatch(parts[parts.length - 2]) &&
          RegExp(r'\d').hasMatch(parts.last) &&
          RegExp(r'\d').hasMatch(parts[1]);

      if (isPriceLine) {
        if (currentItem == null) {
          currentItem = {
            'sr': '-',
            'desc': 'Unknown Item',
            'barcode': '',
            'arabicDesc': '',
          };
        }
        currentItem['alu'] = parts[0];
        currentItem['qty'] = parts[parts.length - 2];
        currentItem['net'] = parts.last.replaceAll(RegExp(r'[()]'), '');

        if (parts.length == 5) {
          currentItem['orgPrice'] = parts[1].replaceAll(RegExp(r'[()]'), '');
          currentItem['disc'] = parts[2].replaceAll(RegExp(r'[()]'), '');
        } else if (parts.length > 5) {
          List<String> middle = parts.sublist(1, parts.length - 2);
          int midIndex = middle.length ~/ 2;
          currentItem['orgPrice'] = middle
              .sublist(0, midIndex)
              .join('')
              .replaceAll(RegExp(r'[()]'), '');
          currentItem['disc'] = middle
              .sublist(midIndex)
              .join('')
              .replaceAll(RegExp(r'[()]'), '');
        } else {
          currentItem['orgPrice'] = parts[1].replaceAll(RegExp(r'[()]'), '');
          currentItem['disc'] = "0";
        }
        receipt.items.add(currentItem);
        currentItem = null;
        continue;
      }

      if (currentItem == null) {
        String sr = parts.first;
        String barcode = "";
        String desc = "";

        if (parts.length >= 3 &&
            RegExp(r'^[A-Za-z0-9\-]{4,}$').hasMatch(parts.last)) {
          barcode = parts.last;
          desc = parts.sublist(1, parts.length - 1).join(' ');
        } else if (parts.length >= 2) {
          desc = parts.sublist(1).join(' ');
        } else {
          desc = sr;
        }
        currentItem = {
          'sr': sr,
          'desc': desc,
          'barcode': barcode,
          'arabicDesc': '',
        };
      } else {
        currentItem['arabicDesc'] =
            (currentItem['arabicDesc']! + " " + trimmed).trim();
      }
    }

    if (currentItem != null) receipt.items.add(currentItem);
    receipt.items.sort((a, b) {
      int srA = int.tryParse(a['sr'] ?? '0') ?? 0;
      int srB = int.tryParse(b['sr'] ?? '0') ?? 0;
      return srA.compareTo(srB);
    });
  } catch (e) {
    logToConsole("Extraction Error: $e");
  }
  return receipt;
}

Uint8List? receiptImageAt(List<Uint8List> images, int index) {
  return index < images.length ? images[index] : null;
}

bool isBlankReceiptPixel(img.Pixel pixel) {
  final luminance =
  (0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b).round();
  return luminance >= receiptTrimThreshold;
}

bool rowHasContent(img.Image source, int y) {
  int darkCount = 0;
  final minDark = (source.width * 0.001).ceil().clamp(1, 8);
  for (var x = 0; x < source.width; x++) {
    if (!isBlankReceiptPixel(source.getPixel(x, y))) {
      darkCount++;
      if (darkCount >= minDark) return true;
    }
  }
  return false;
}

img.Image trimReceiptWhitespace(img.Image source) {
  int minX = source.width;
  int minY = source.height;
  int maxX = -1;
  int maxY = -1;

  for (var y = 0; y < source.height; y++) {
    if (!rowHasContent(source, y)) continue;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
    for (var x = 0; x < source.width; x++) {
      if (!isBlankReceiptPixel(source.getPixel(x, y))) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
    }
  }
  if (maxX < minX || maxY < minY) return source;
  return img.copyCrop(
    source,
    x: minX,
    y: minY,
    width: maxX - minX + 1,
    height: maxY - minY + 1,
  );
}

img.Image scaleReceiptImageToTargetWidth(img.Image source) {
  if (source.width == receiptImageTargetWidth) return source;
  final targetHeight =
  (source.height * receiptImageTargetWidth / source.width).round();
  return img.copyResize(
    source,
    width: receiptImageTargetWidth,
    height: targetHeight,
  );
}

Uint8List prepareReceiptImage(Uint8List imageBytes) {
  try {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) return imageBytes;
    final trimmed = trimReceiptWhitespace(decoded);
    final scaled = scaleReceiptImageToTargetWidth(trimmed);
    return Uint8List.fromList(img.encodePng(scaled));
  } catch (e) {
    return imageBytes;
  }
}

Uint8List mergeTwoImagesVertical(Uint8List img1Bytes, Uint8List img2Bytes) {
  try {
    final prepared1 = img.decodeImage(prepareReceiptImage(img1Bytes));
    final prepared2 = img.decodeImage(prepareReceiptImage(img2Bytes));
    if (prepared1 == null || prepared2 == null) return img1Bytes;

    final merged = img.Image(
      width: receiptImageTargetWidth,
      height: prepared1.height + prepared2.height,
    );
    img.compositeImage(merged, prepared1, dstX: 0, dstY: 0);
    img.compositeImage(merged, prepared2, dstX: 0, dstY: prepared1.height);

    final trimmed = trimReceiptWhitespace(merged);
    return Uint8List.fromList(img.encodePng(trimmed));
  } catch (e) {
    return prepareReceiptImage(img1Bytes);
  }
}

Future<void> printReceiptImage(
    Uint8List imageBytes, {
      bool alreadyPrepared = false,
      bool tightTop = false,
    }) async {
  if (tightTop) await SunmiPrinter.printEscPos(const [0x1B, 0x33, 0x00]);
  final finalImage =
  alreadyPrepared ? imageBytes : prepareReceiptImage(imageBytes);
  await SunmiPrinter.setAlignment(SunmiPrintAlign.CENTER);
  await SunmiPrinter.printImage(finalImage);
  if (tightTop) await SunmiPrinter.printEscPos(const [0x1B, 0x32]);
}

Future<void> printCompactHeaderText(String headerText) async {
  final headerStyle = SunmiTextStyle(
    bold: true,
    align: SunmiPrintAlign.CENTER,
    fontSize: 24,
  );
  await SunmiPrinter.printEscPos(const [0x1B, 0x33, 0x00]);
  await SunmiPrinter.printText(headerText, style: headerStyle);
  await SunmiPrinter.printEscPos(const [0x1B, 0x32]);
}

Future<void> printReceipt(ParsedReceipt r) async {
  try {
    await SunmiPrinter.initPrinter();

    await SunmiPrinter.setAlignment(SunmiPrintAlign.LEFT);
    await SunmiPrinter.setFontSize(8);
    await SunmiPrinter.printRow(
      cols: [
        SunmiColumn(
          text: 'Print Date & Time :-',
          width: 14,
          style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
        ),
        SunmiColumn(
          text: r.printDateTime,
          width: 16,
          style: SunmiTextStyle(align: SunmiPrintAlign.RIGHT),
        ),
      ],
    );

    final headerImage1 = receiptImageAt(r.images, 0);
    final headerImage2 = receiptImageAt(r.images, 1);
    if (headerImage1 != null && headerImage2 != null) {
      final merged = mergeTwoImagesVertical(headerImage1, headerImage2);
      await printReceiptImage(merged, alreadyPrepared: true);
    } else {
      if (headerImage1 != null) await printReceiptImage(headerImage1);
      if (headerImage2 != null) await printReceiptImage(headerImage2);
    }

    await SunmiPrinter.setAlignment(SunmiPrintAlign.CENTER);
    await printCompactHeaderText(r.headerText);
    await SunmiPrinter.lineWrap(1);

    await SunmiPrinter.setAlignment(SunmiPrintAlign.LEFT);
    await SunmiPrinter.setFontSize(8);
    await SunmiPrinter.printText(
      'Date & Time:التاريخ والوقت:      Store: ${r.store}',
    );
    await SunmiPrinter.printRow(
      cols: [
        SunmiColumn(
          text: r.printDateTime,
          width: 16,
          style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
        ),
        SunmiColumn(
          text: 'sales Emp.No: ${r.salesEmp}',
          width: 14,
          style: SunmiTextStyle(align: SunmiPrintAlign.RIGHT),
        ),
      ],
    );
    await SunmiPrinter.printText('Cashier : ${r.cashier}');
    await SunmiPrinter.printText('Receipt #:الفاتورة: ${r.receiptNo}');
    await SunmiPrinter.lineWrap(1);
    await SunmiPrinter.setAlignment(SunmiPrintAlign.CENTER);
    await SunmiPrinter.printText(
      'COPY',
      style: SunmiTextStyle(bold: true, align: SunmiPrintAlign.CENTER),
    );
    await SunmiPrinter.lineWrap(1);

    await SunmiPrinter.setAlignment(SunmiPrintAlign.LEFT);
    await SunmiPrinter.printText(
      '================================================',
    );
    await SunmiPrinter.printRow(
      cols: [
        SunmiColumn(
          text: 'Sr.#',
          width: 4,
          style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
        ),
        SunmiColumn(
          text: 'Desc الوصف',
          width: 14,
          style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
        ),
        SunmiColumn(
          text: 'Barcode الرمز',
          width: 12,
          style: SunmiTextStyle(align: SunmiPrintAlign.RIGHT),
        ),
      ],
    );
    await SunmiPrinter.printRow(
      cols: [
        SunmiColumn(
          text: 'ALU',
          width: 6,
          style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
        ),
        SunmiColumn(
          text: 'OrgPrice',
          width: 9,
          style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
        ),
        SunmiColumn(
          text: 'Disc',
          width: 5,
          style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
        ),
        SunmiColumn(
          text: 'QTY',
          width: 4,
          style: SunmiTextStyle(align: SunmiPrintAlign.CENTER),
        ),
        SunmiColumn(
          text: 'Net',
          width: 6,
          style: SunmiTextStyle(align: SunmiPrintAlign.RIGHT),
        ),
      ],
    );
    await SunmiPrinter.printText(
      '------------------------------------------------',
    );

    for (var item in r.items) {
      await SunmiPrinter.printRow(
        cols: [
          SunmiColumn(
            text: item['sr'] ?? '',
            width: 4,
            style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
          ),
          SunmiColumn(
            text: item['desc'] ?? '',
            width: 14,
            style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
          ),
          SunmiColumn(
            text: item['barcode'] ?? '',
            width: 12,
            style: SunmiTextStyle(align: SunmiPrintAlign.RIGHT),
          ),
        ],
      );
      if ((item['arabicDesc'] ?? '').isNotEmpty) {
        await SunmiPrinter.printText('  ${item['arabicDesc']}');
      }
      await SunmiPrinter.printRow(
        cols: [
          SunmiColumn(
            text: item['alu'] ?? '',
            width: 6,
            style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
          ),
          SunmiColumn(
            text: item['orgPrice'] ?? '',
            width: 9,
            style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
          ),
          SunmiColumn(
            text: item['disc'] ?? '',
            width: 5,
            style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
          ),
          SunmiColumn(
            text: item['qty'] ?? '',
            width: 4,
            style: SunmiTextStyle(align: SunmiPrintAlign.CENTER),
          ),
          SunmiColumn(
            text: item['net'] ?? '',
            width: 6,
            style: SunmiTextStyle(align: SunmiPrintAlign.RIGHT),
          ),
        ],
      );
      await SunmiPrinter.printText(
        '------------------------------------------------',
      );
    }

    await SunmiPrinter.printRow(
      cols: [
        SunmiColumn(
          text: 'Units',
          width: 15,
          style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
        ),
        SunmiColumn(
          text: r.units,
          width: 15,
          style: SunmiTextStyle(align: SunmiPrintAlign.RIGHT),
        ),
      ],
    );
    await SunmiPrinter.printRow(
      cols: [
        SunmiColumn(
          text: 'Gross Sale المبلغ الإجمالي',
          width: 18,
          style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
        ),
        SunmiColumn(
          text: r.grossSale,
          width: 12,
          style: SunmiTextStyle(align: SunmiPrintAlign.RIGHT),
        ),
      ],
    );
    await SunmiPrinter.printRow(
      cols: [
        SunmiColumn(
          text: 'Receipt Total إجمالي الفاتور',
          width: 18,
          style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
        ),
        SunmiColumn(
          text: r.receiptTotal,
          width: 12,
          style: SunmiTextStyle(align: SunmiPrintAlign.RIGHT),
        ),
      ],
    );

    await SunmiPrinter.printRow(
      cols: [
        SunmiColumn(
          text: 'Tendered المبلغ المستل:',
          width: 30,
          style: SunmiTextStyle(bold: true, align: SunmiPrintAlign.LEFT),
        ),
      ],
    );
    for (var tender in r.tenders) {
      String name = tender['name'] ?? '';
      if (name.length > 20) name = name.substring(0, 20);
      await SunmiPrinter.printRow(
        cols: [
          SunmiColumn(
            text: '  $name',
            width: 22,
            style: SunmiTextStyle(align: SunmiPrintAlign.LEFT),
          ),
          SunmiColumn(
            text: tender['value'] ?? '',
            width: 8,
            style: SunmiTextStyle(align: SunmiPrintAlign.RIGHT),
          ),
        ],
      );
    }
    await SunmiPrinter.printText(
      '================================================',
    );

    final preBarcodeImage = receiptImageAt(r.images, 2);
    if (preBarcodeImage != null) await printReceiptImage(preBarcodeImage);

    if (r.barcodeData.isNotEmpty) {
      await SunmiPrinter.setAlignment(SunmiPrintAlign.CENTER);
      await SunmiPrinter.printBarCode(
        r.barcodeData,
        style: SunmiBarcodeStyle(
          type: SunmiBarcodeType.CODE128,
          height: 64,
          size: 2,
          textPos: SunmiBarcodeTextPos.TEXT_UNDER,
        ),
      );
      await SunmiPrinter.lineWrap(1);
    }

    await SunmiPrinter.setAlignment(SunmiPrintAlign.LEFT);
    await SunmiPrinter.printText(
      'توقيع العميل',
      style: SunmiTextStyle(bold: true),
    );
    await SunmiPrinter.printText('Customer Signature: __________________');

    final postBarcodeImage = receiptImageAt(r.images, 3);
    if (postBarcodeImage != null) {
      await SunmiPrinter.lineWrap(1);
      await printReceiptImage(postBarcodeImage);
    }

    await SunmiPrinter.lineWrap(4);
  } catch (e) {
    logToConsole("CRITICAL Printer Hardware Error: $e");
  }
}

// ==========================================
// 4. MAIN APP ENTRY
// ==========================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(const SunmiBridgeApp());
}

class SunmiBridgeApp extends StatelessWidget {
  const SunmiBridgeApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sunmi Store Commerce Print Service',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.amber,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const PermissionsScreen(), // ENTRY POINT
    );
  }
}

// ==========================================
// 5. PERMISSIONS SCREEN
// ==========================================
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({Key? key}) : super(key: key);

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  bool _isOverlayGranted = false;
  bool _isBatteryOptimizationsIgnored = false;
  bool _isChecking = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // Listen for return from settings
    _checkAllPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Triggers automatically when app is resumed (e.g., returning from Android Settings)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAllPermissions();
    }
  }

  Future<void> _checkAllPermissions() async {
    setState(() => _isChecking = true);

    _isOverlayGranted = await Permission.systemAlertWindow.isGranted;
    _isBatteryOptimizationsIgnored =
    await Permission.ignoreBatteryOptimizations.isGranted;

    setState(() => _isChecking = false);

    // If both are granted, automatically navigate to the main dashboard
    if (_isOverlayGranted && _isBatteryOptimizationsIgnored) {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const BridgeDashboard()),
      );
    }
  }

  Future<void> _requestOverlay() async {
    await Permission.systemAlertWindow.request();
    _checkAllPermissions();
  }

  Future<void> _requestBattery() async {
    await Permission.ignoreBatteryOptimizations.request();
    _checkAllPermissions();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Required Setup',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        elevation: 0,
      ),
      body: _isChecking
          ? const Center(child: CircularProgressIndicator(color: Colors.amber))
          : Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Action Required",
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.amber,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              "To ensure the print server runs reliably in the background without being killed by Android, please grant the following permissions.",
              style: TextStyle(fontSize: 16, color: Colors.white70),
            ),
            const SizedBox(height: 32),

            // Overlay Permission Card
            _buildPermissionCard(
              title: "Draw Over Other Apps",
              description:
              "Allows the print service to stay active in the background.",
              icon: Icons.layers,
              isGranted: _isOverlayGranted,
              onRequest: _requestOverlay,
            ),
            const SizedBox(height: 16),

            // Battery Optimization Card
            _buildPermissionCard(
              title: "Ignore Battery Optimization",
              description:
              "Prevents the operating system from putting the server to sleep.",
              icon: Icons.battery_charging_full,
              isGranted: _isBatteryOptimizationsIgnored,
              onRequest: _requestBattery,
            ),

            const Spacer(),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed:
                (_isOverlayGranted && _isBatteryOptimizationsIgnored)
                    ? () => Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                    const BridgeDashboard(),
                  ),
                )
                    : null, // Disabled if not fully granted
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: Colors.grey[800],
                  disabledForegroundColor: Colors.grey[500],
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  "CONTINUE",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionCard({
    required String title,
    required String description,
    required IconData icon,
    required bool isGranted,
    required VoidCallback onRequest,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isGranted ? Colors.green : Colors.amber.withOpacity(0.5),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 40, color: isGranted ? Colors.green : Colors.amber),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: isGranted ? null : onRequest,
            style: ElevatedButton.styleFrom(
              backgroundColor: isGranted ? Colors.green : Colors.amber,
              foregroundColor: isGranted ? Colors.white : Colors.black,
            ),
            child: Text(isGranted ? "Granted" : "Grant"),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// 6. UI DASHBOARD
// ==========================================
class BridgeDashboard extends StatefulWidget {
  const BridgeDashboard({Key? key}) : super(key: key);

  @override
  State<BridgeDashboard> createState() => _BridgeDashboardState();
}

class _BridgeDashboardState extends State<BridgeDashboard>
    with WidgetsBindingObserver {
  bool _isServerRunning = false;
  String _localIp = "Retrieving local network IP...";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // Listen for app backgrounding
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchLocalIp();
      _checkServiceStatus();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // NOTE: This triggers ONLY when the user is already on the dashboard and leaves the app.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (_isServerRunning) {
        // A slight delay prevents the pop from crashing the native Android transition animation.
        // Combined with android:excludeFromRecents="true" in the Manifest,
        // this will completely destroy the UI from RAM and hide it from the square button menu.
        Future.delayed(const Duration(milliseconds: 500), () {
          SystemNavigator.pop();
        });
      }
    }
  }

  Future<void> _checkServiceStatus() async {
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();
    if (!mounted) return;
    setState(() {
      _isServerRunning = isRunning;
    });
  }

  Future<void> _fetchLocalIp() async {
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            if (!mounted) return;
            setState(() {
              _localIp = addr.address;
            });
            return;
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _localIp = "No active Wi-Fi connection detected";
      });
    } catch (e) {
      debugPrint("Failed to resolve local IP: $e");
    }
  }

  Future<void> _toggleHttpServer() async {
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();

    if (isRunning) {
      service.invoke("stopService");
      setState(() {
        _isServerRunning = false;
      });
    } else {
      await service.startService();
      setState(() {
        _isServerRunning = true;
      });
      // Allow time for isolate to spin up and bind
      Future.delayed(const Duration(seconds: 1), _checkServiceStatus);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Sunmi ePOS Interceptor',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _fetchLocalIp();
              _checkServiceStatus();
            },
            tooltip: 'Refresh Status',
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 48.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _isServerRunning
                    ? "Print service running"
                    : "Print service not running",
                style: TextStyle(
                  fontSize: 25,
                  color: !_isServerRunning
                      ? Colors.redAccent
                      : Colors.greenAccent,
                ),
              ),
              const SizedBox(height: 48),
              SizedBox(
                width: double.infinity,
                height: 60,
                child: ElevatedButton.icon(
                  onPressed: _toggleHttpServer,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isServerRunning
                        ? Colors.redAccent
                        : Colors.green,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 4,
                  ),
                  icon: Icon(
                    _isServerRunning
                        ? Icons.stop_circle
                        : Icons.play_circle_fill,
                    color: Colors.white,
                    size: 28,
                  ),
                  label: Text(
                    _isServerRunning ? 'STOP SERVICE' : 'START SERVICE',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontSize: 18,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              Text(
                _isServerRunning
                    ? 'Listening for EPSON XML payloads in Background...\nYou may now close this app.'
                    : 'Service is stopped. Press Start to begin intercepting.',
                style: TextStyle(
                  color: _isServerRunning ? Colors.green : Colors.grey,
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}