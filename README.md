# SUNMI Store Commerce Printer Bridge Service

A robust background print server built with Flutter designed to intercept, parse, and print EPSON XML (ePOS-Print) payloads natively on Sunmi POS hardware.

## Overview

The **SUNMI Store Commerce Printer Bridge Service** acts as a middleware bridge for modern web-based Point of Sale (POS) systems that expect to communicate with EPSON network printers. Instead of requiring expensive external hardware, this application runs silently in the background of a Sunmi device, listening on the standard EPSON print port (`9100`).

When an ePOS XML payload is received, the interceptor parses the raw data, extracts the receipt information (including dynamically decoding Base64 images), formats it for the narrow thermal paper format, and dispatches the job directly to the built-in Sunmi printer.

## Key Features

* **Always-On Background Service:** Utilizes a detached Android Foreground Isolate, ensuring the print server stays alive and listening even when the app is minimized or swiped away from memory.
* **ePOS XML Parsing:** Accurately dissects complex EPSON XML structures, extracting metadata, multi-tender transactions, and tabular item lists.
* **Dynamic Image Decoding:** Capable of rendering raster graphics embedded within the XML payload, applying smart trimming algorithms to remove excess whitespace and scale images for the 58mm/80mm thermal paper width.
* **Sunmi Hardware Integration:** Built on top of `sunmi_printer_plus` to natively bind to the device's internal thermal printer without requiring external drivers.
* **Auto-Start on Boot:** Configured to automatically initialize the background isolate when the Sunmi device turns on, guaranteeing zero-touch operation for cashiers.
* **Graceful Memory Management:** Acts as a true headless utility. The UI interface politely destroys itself to save RAM while the print service continues unhindered in the background.

## Prerequisites

To run this project, you will need:
* Flutter SDK (`>=3.0.0`)
* A physical Sunmi POS device (e.g., Sunmi V2, V2 Pro, T2s) or a supported Android terminal with built-in thermal printing capabilities.
* *Note: iOS is not supported as this relies heavily on Android Service Architecture and Sunmi's proprietary hardware SDK.*

## Core Dependencies

This project relies on several key packages to function:

* [`flutter_background_service`](https://pub.dev/packages/flutter_background_service) - Manages the detached Isolate and Foreground notification.
* [`sunmi_printer_plus`](https://pub.dev/packages/sunmi_printer_plus) - Handles the low-level communication with the Sunmi printing hardware.
* [`xml`](https://pub.dev/packages/xml) - Provides fast, robust parsing for incoming ePOS payloads.
* [`image`](https://pub.dev/packages/image) - Used for decoding, trimming, and scaling raster graphics before printing.
* [`permission_handler`](https://pub.dev/packages/permission_handler) - Ensures all required Android background execution permissions are granted.

## How it Works

1.  **Initialization:** Upon launch (or device boot), the app requests necessary permissions (`Draw Over Other Apps`, `Ignore Battery Optimizations`).
2.  **The Isolate:** Once granted, a separate Dart Isolate is spun up. This isolate binds an `HttpServer` to `0.0.0.0:9100`.
3.  **The UI Retreats:** The user presses the Home button. The Flutter UI calls `SystemNavigator.pop()` and vanishes from the Android Recents menu (`excludeFromRecents="true"`), freeing up memory.
4.  **Interception:** A web POS sends a POST request containing an EPSON XML string to the Sunmi's IP address on Port 9100.
5.  **Processing & Printing:** The background isolate catches the payload, decodes the XML via the `ParsedReceipt` data model, and issues raw ESC/POS commands via the Sunmi SDK to print the physical receipt.

## Important Sunmi Configuration

Sunmi devices utilize an aggressive, highly customized Android OS designed to maximize battery life. Even with a Foreground Service, Sunmi's OS may eventually kill the app.

**You MUST configure the following on the device:**
1.  Go to Android Settings -> Apps -> *Your App Name*.
2.  Navigate to **Battery**.
3.  Change the setting to **Unrestricted** (or "Don't Optimize").

## Usage Notes

This application accepts standard POST requests. The payload must be valid `epos-print` XML.

Example acceptable payload structure:
```xml
<?xml version="1.0" encoding="utf-8"?>
<epos-print xmlns="[http://www.epson-pos.com/schemas/2011/11/epos-print](http://www.epson-pos.com/schemas/2011/11/epos-print)">
    <text>STORE NAME\n</text>
    <text>Receipt #: 123456789\n</text>
    <barcode type="code128">123456789</barcode>
</epos-print>