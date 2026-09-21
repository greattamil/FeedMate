import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import 'invoice_history_api.dart';

/// Builds a complete, GST-compliant invoice PDF from a loaded [InvoiceDetail]:
/// shop identity/compliance header, customer, line items with per-line HSN
/// and CGST/SGST/IGST breakdown, tenders, and totals. This is the one place
/// the printed/shared invoice document is laid out, so the on-screen detail
/// view and the shared file never drift apart in what they claim to show.
pw.Document buildInvoicePdf(InvoiceDetail invoice) {
  final doc = pw.Document();
  final dateFmt = DateFormat('dd MMM yyyy, h:mm a');

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (context) => [
        _shopHeader(invoice.store),
        pw.SizedBox(height: 12),
        pw.Divider(),
        _invoiceMeta(invoice, dateFmt),
        pw.SizedBox(height: 12),
        _lineItemsTable(invoice),
        pw.SizedBox(height: 12),
        _totalsBlock(invoice),
        pw.SizedBox(height: 12),
        _tendersBlock(invoice),
        if (invoice.store.receiptFooter != null && invoice.store.receiptFooter!.isNotEmpty) ...[
          pw.SizedBox(height: 20),
          pw.Divider(),
          pw.Center(
            child: pw.Text(invoice.store.receiptFooter!, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
          ),
        ],
      ],
    ),
  );
  return doc;
}

pw.Widget _shopHeader(InvoiceStoreDetail store) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        store.tradeName?.isNotEmpty == true ? store.tradeName! : store.legalName,
        style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
      ),
      if (store.tradeName?.isNotEmpty == true && store.tradeName != store.legalName)
        pw.Text(store.legalName, style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
      pw.SizedBox(height: 4),
      pw.Text(store.fullAddress, style: const pw.TextStyle(fontSize: 9)),
      pw.Row(
        children: [
          if (store.phone != null && store.phone!.isNotEmpty) pw.Text('Ph: ${store.phone}  ', style: const pw.TextStyle(fontSize: 9)),
          if (store.email != null && store.email!.isNotEmpty) pw.Text(store.email!, style: const pw.TextStyle(fontSize: 9)),
        ],
      ),
      pw.Row(
        children: [
          if (store.gstin != null && store.gstin!.isNotEmpty) pw.Text('GSTIN: ${store.gstin}  ', style: const pw.TextStyle(fontSize: 9)),
          if (store.fssaiLicenseNo != null && store.fssaiLicenseNo!.isNotEmpty)
            pw.Text('FSSAI: ${store.fssaiLicenseNo}', style: const pw.TextStyle(fontSize: 9)),
        ],
      ),
      if (store.receiptHeader != null && store.receiptHeader!.isNotEmpty) ...[
        pw.SizedBox(height: 4),
        pw.Text(store.receiptHeader!, style: pw.TextStyle(fontSize: 9, fontStyle: pw.FontStyle.italic)),
      ],
    ],
  );
}

pw.Widget _invoiceMeta(InvoiceDetail invoice, DateFormat dateFmt) {
  return pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('TAX INVOICE', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
          pw.Text('Invoice No: ${invoice.invoiceNumber}', style: const pw.TextStyle(fontSize: 10)),
          if (invoice.finalizedAt != null)
            pw.Text('Date: ${dateFmt.format(invoice.finalizedAt!)}', style: const pw.TextStyle(fontSize: 10)),
          pw.Text('Payment: ${invoice.paymentStatus}', style: const pw.TextStyle(fontSize: 10)),
        ],
      ),
      pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Text('Bill To', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
          pw.Text(invoice.customerName ?? 'Walking Customer', style: const pw.TextStyle(fontSize: 10)),
        ],
      ),
    ],
  );
}

pw.Widget _lineItemsTable(InvoiceDetail invoice) {
  final headers = ['#', 'Item', 'HSN', 'Qty', 'Rate', 'Disc', 'Taxable', 'Tax', 'Total'];
  final rows = <List<String>>[];
  for (var i = 0; i < invoice.lines.length; i++) {
    final l = invoice.lines[i];
    final taxLabel = l.taxBreakdown.isEmpty
        ? '0.00'
        : l.taxBreakdown.map((t) => '${t.taxType} ${t.rate.toStringAsFixed(2)}%: Rs.${t.amount.toStringAsFixed(2)}').join('\n');
    rows.add([
      '${i + 1}',
      '${l.productName}\n${l.sku} · ${l.uomCode}',
      l.hsn ?? '-',
      l.quantity.toString(),
      l.unitPrice.toStringAsFixed(2),
      l.discountAmount.toStringAsFixed(2),
      l.taxableValue.toStringAsFixed(2),
      taxLabel,
      l.lineTotal.toStringAsFixed(2),
    ]);
  }
  return pw.TableHelper.fromTextArray(
    headers: headers,
    data: rows,
    headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
    cellStyle: const pw.TextStyle(fontSize: 8),
    cellAlignment: pw.Alignment.centerLeft,
    columnWidths: const {
      0: pw.FlexColumnWidth(0.4),
      1: pw.FlexColumnWidth(2.2),
      2: pw.FlexColumnWidth(0.9),
      3: pw.FlexColumnWidth(0.9),
      4: pw.FlexColumnWidth(1),
      5: pw.FlexColumnWidth(0.8),
      6: pw.FlexColumnWidth(1),
      7: pw.FlexColumnWidth(1.6),
      8: pw.FlexColumnWidth(1),
    },
    border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
  );
}

pw.Widget _totalsBlock(InvoiceDetail invoice) {
  pw.Widget row(String label, String value, {bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: pw.TextStyle(fontSize: 10, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          pw.Text('Rs.$value', style: pw.TextStyle(fontSize: 10, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        ],
      ),
    );
  }

  return pw.Align(
    alignment: pw.Alignment.centerRight,
    child: pw.SizedBox(
      width: 220,
      child: pw.Column(
        children: [
          row('Subtotal', invoice.subtotal.toStringAsFixed(2)),
          if (invoice.discountTotal.toStringAsFixed(2) != '0.00') row('Discount', '-${invoice.discountTotal.toStringAsFixed(2)}'),
          row('Taxable Total', invoice.taxableTotal.toStringAsFixed(2)),
          row('Tax Total', invoice.taxTotal.toStringAsFixed(2)),
          if (invoice.roundingAmount.toStringAsFixed(2) != '0.00') row('Rounding', invoice.roundingAmount.toStringAsFixed(2)),
          pw.Divider(),
          row('Grand Total', invoice.grandTotal.toStringAsFixed(2), bold: true),
        ],
      ),
    ),
  );
}

pw.Widget _tendersBlock(InvoiceDetail invoice) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text('Payment', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
      ...invoice.tenders.map(
        (t) => pw.Text('${t.method}: Rs.${t.amount.toStringAsFixed(2)}', style: const pw.TextStyle(fontSize: 9)),
      ),
    ],
  );
}

/// Renders [invoice] to a PDF and opens the platform share sheet — mirrors
/// core/csv_export.dart's shareCsv() pattern so every "share a generated
/// document" flow in this app works the same way, including on platforms
/// (web) with no filesystem to write a temp file to: XFile.fromData() wraps
/// the bytes directly rather than going through dart:io's File.
Future<void> shareInvoicePdf(InvoiceDetail invoice) async {
  final doc = buildInvoicePdf(invoice);
  final bytes = await doc.save();
  final fileName = 'Invoice_${invoice.invoiceNumber.replaceAll('/', '-')}.pdf';
  final file = XFile.fromData(bytes, mimeType: 'application/pdf', name: fileName);
  await SharePlus.instance.share(ShareParams(files: [file], fileNameOverrides: [fileName]));
}

/// Where [downloadInvoicePdf] actually put the file, so the caller can show
/// a real path (or explain that "download" meant "share" on this platform)
/// rather than a generic "saved" toast that might be wrong.
class InvoiceDownloadResult {
  final String? savedPath;
  final bool sharedInstead;
  const InvoiceDownloadResult({this.savedPath, this.sharedInstead = false});
}

/// Saves [invoice] as a real PDF file on disk (Downloads on Android/
/// Windows/macOS/Linux) instead of only handing it to the share sheet —
/// the user asked for these as two distinct actions on the invoice detail
/// page. Web has no filesystem to write to, so it falls back to the same
/// share flow as [shareInvoicePdf], which on a desktop browser already
/// triggers a native "Save As" download.
Future<InvoiceDownloadResult> downloadInvoicePdf(InvoiceDetail invoice) async {
  final doc = buildInvoicePdf(invoice);
  final bytes = await doc.save();
  final fileName = 'Invoice_${invoice.invoiceNumber.replaceAll('/', '-')}.pdf';

  if (kIsWeb) {
    await shareInvoicePdf(invoice);
    return const InvoiceDownloadResult(sharedInstead: true);
  }

  // getDownloadsDirectory() is only implemented on Windows/macOS/Linux —
  // it throws UnsupportedError on Android, where the closest real,
  // file-manager-visible equivalent is the app's external storage
  // directory (falling back further to the private app documents
  // directory only if even that is unavailable).
  Directory? targetDir;
  try {
    targetDir = await getDownloadsDirectory();
  } catch (_) {
    targetDir = null;
  }
  if (targetDir == null) {
    try {
      targetDir = await getExternalStorageDirectory();
    } catch (_) {
      targetDir = null;
    }
  }
  targetDir ??= await getApplicationDocumentsDirectory();

  final path = '${targetDir.path}${Platform.pathSeparator}$fileName';
  final file = File(path);
  await file.writeAsBytes(bytes, flush: true);
  return InvoiceDownloadResult(savedPath: path);
}
