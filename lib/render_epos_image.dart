import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:xml/xml.dart';

enum EposPackingMode { byteAlignedCeil, continuous, byteAlignedFloor }

EposPackingMode detectPackingMode(Uint8List raster, int width, int height) {
  final byteAlignedCeil = (width / 8).ceil() * height;
  final byteAlignedFloor = (width >> 3) * height;
  final continuous = ((width * height) / 8).ceil();

  if (raster.length == byteAlignedCeil) {
    return EposPackingMode.byteAlignedCeil;
  }
  if (raster.length == continuous) {
    return EposPackingMode.continuous;
  }
  if (raster.length == byteAlignedFloor) {
    return EposPackingMode.byteAlignedFloor;
  }

  final candidates = <(EposPackingMode, int)>[
    (EposPackingMode.byteAlignedCeil, byteAlignedCeil),
    (EposPackingMode.continuous, continuous),
    (EposPackingMode.byteAlignedFloor, byteAlignedFloor),
  ];
  candidates.sort(
    (a, b) => (raster.length - a.$2).abs().compareTo((raster.length - b.$2).abs()),
  );

  return candidates.first.$1;
}

({int width, int height, String color, Uint8List raster, EposPackingMode mode})
    decodeEposMonoRaster(String base64, int width, int height) {
  final raster = base64Decode(base64);
  final mode = detectPackingMode(raster, width, height);
  final pixels = Uint8List(width * height * 4);

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      late int byteIndex;
      late int bitPos;

      if (mode == EposPackingMode.continuous) {
        final bitIndex = y * width + x;
        byteIndex = bitIndex >> 3;
        bitPos = 7 - (bitIndex & 7);
      } else {
        final bytesPerRow = mode == EposPackingMode.byteAlignedCeil
            ? (width / 8).ceil()
            : width >> 3;
        byteIndex = y * bytesPerRow + (x >> 3);
        bitPos = 7 - (x & 7);
      }

      if (byteIndex >= raster.length) {
        continue;
      }

      final bit = (raster[byteIndex] >> bitPos) & 1;
      final shade = bit == 1 ? 0 : 255;
      final offset = (y * width + x) * 4;
      pixels[offset] = shade;
      pixels[offset + 1] = shade;
      pixels[offset + 2] = shade;
      pixels[offset + 3] = 255;
    }
  }

  return (width: width, height: height, color: 'mono', raster: pixels, mode: mode);
}

Future<Uint8List> rgbaToPng(Uint8List pixels, int width, int height) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (byteData == null) {
    throw StateError('Failed to encode decoded raster as PNG');
  }
  return byteData.buffer.asUint8List();
}

/// Decodes an EPSON ePOS `<image>` element to PNG bytes using the same
/// mono raster algorithm as render-epos-image.js.
Future<Uint8List?> renderEposImagePng(
  XmlElement imageElement, {
  void Function(String message)? onLog,
}) async {
  try {
    final widthAttr = imageElement.getAttribute('width');
    final heightAttr = imageElement.getAttribute('height');
    if (widthAttr == null || heightAttr == null) return null;

    final width = int.parse(widthAttr.trim());
    final height = int.parse(heightAttr.trim());
    final color = imageElement.getAttribute('color') ?? 'mono';

    if (color != 'mono') {
      throw Exception('Unsupported color mode "$color" (only mono is supported)');
    }

    var base64Str = imageElement.innerText.replaceAll(RegExp(r'\s+'), '');
    while (base64Str.length % 4 != 0) {
      base64Str += '=';
    }

    if (width <= 0 || height <= 0 || base64Str.isEmpty) return null;

    final decoded = decodeEposMonoRaster(base64Str, width, height);
    onLog?.call('Rendered ${width}x$height image (packing: ${decoded.mode.name})');
    return await rgbaToPng(decoded.raster, width, height);
  } catch (e) {
    onLog?.call('Image decode error: $e');
    return null;
  }
}
