import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import 'invoice_history_api.dart';

/// Color palette mirroring the app's on-screen design system
/// (core/theme/app_colors.dart) so the printed/shared invoice looks like it
/// belongs to the same product, not a plain black-and-white form.
class _Palette {
  static const primary = PdfColor.fromInt(0xFF0D9488); // teal
  static const primaryDark = PdfColor.fromInt(0xFF0F766E);
  static const indigo = PdfColor.fromInt(0xFF4F46E5);
  static const amber = PdfColor.fromInt(0xFFD97706);
  static const green = PdfColor.fromInt(0xFF16A34A);
  static const red = PdfColor.fromInt(0xFFDC2626);
  static const slate = PdfColor.fromInt(0xFF475569);
  static const slateLight = PdfColor.fromInt(0xFF64748B);
  static const ink = PdfColor.fromInt(0xFF0F172A);
  static const tealTint = PdfColor.fromInt(0xFFECFDF9);
  static const zebra = PdfColor.fromInt(0xFFF1F5F9);
  static const border = PdfColor.fromInt(0xFFE2E8F0);
}

/// The literal rupee sign glyph is missing from the pdf package's default
/// core Helvetica font and renders as a blank tofu box in the shared PDF (a
/// real device once showed boxes where every amount should be) — every
/// amount in this file is formatted through this helper instead of a raw
/// currency-symbol/"Rs." literal, so that constraint only has to be honored
/// in one place.
String _money(dynamic amount) => 'Rs. ${amount.toStringAsFixed(2)}';

PdfColor _statusColor(String status) {
  switch (status) {
    case 'PAID':
      return _Palette.green;
    case 'PARTIAL':
      return _Palette.amber;
    case 'CREDIT':
      return _Palette.indigo;
    case 'REFUNDED':
      return _Palette.slateLight;
    case 'UNPAID':
    default:
      return _Palette.red;
  }
}

/// Builds a complete, GST-compliant invoice PDF from a loaded [InvoiceDetail]:
/// a colorful branded header (with the shop's uploaded logo, if any),
/// shop identity/compliance details, customer, line items with per-line HSN
/// and CGST/SGST/IGST breakdown, tenders, and totals. This is the one place
/// the printed/shared invoice document is laid out, so the on-screen detail
/// view and the shared file never drift apart in what they claim to show.
pw.Document buildInvoicePdf(InvoiceDetail invoice) {
  final doc = pw.Document();
  final dateFmt = DateFormat('dd MMM yyyy, h:mm a');

  pw.MemoryImage? logo;
  final logoDataUri = invoice.store.logoDataUri;
  if (logoDataUri != null && logoDataUri.isNotEmpty) {
    try {
      final base64Part = logoDataUri.substring(logoDataUri.indexOf(',') + 1);
      logo = pw.MemoryImage(base64Decode(base64Part));
    } catch (_) {
      logo = null; // A corrupt/unsupported logo must never break the invoice.
    }
  }

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(0, 0, 0, 28),
      header: (context) => context.pageNumber == 1 ? pw.SizedBox() : _continuationBanner(invoice),
      footer: (context) => _pageFooter(context),
      build: (context) => [
        _headerBand(invoice, logo),
        pw.Padding(
          padding: const pw.EdgeInsets.fromLTRB(28, 16, 28, 0),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _metaAndPartiesRow(invoice, dateFmt),
              pw.SizedBox(height: 16),
              _lineItemsTable(invoice),
              pw.SizedBox(height: 14),
              _totalsAndTendersRow(invoice),
              if (invoice.store.receiptFooter != null && invoice.store.receiptFooter!.isNotEmpty) ...[
                pw.SizedBox(height: 20),
                _thankYouBand(invoice.store.receiptFooter!),
              ],
            ],
          ),
        ),
      ],
    ),
  );
  return doc;
}

/// The colored brand band across the top of page 1: logo, shop identity,
/// and a right-aligned "TAX INVOICE" title chip with the invoice number.
pw.Widget _headerBand(InvoiceDetail invoice, pw.MemoryImage? logo) {
  final store = invoice.store;
  return pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.fromLTRB(28, 24, 28, 20),
    decoration: const pw.BoxDecoration(color: _Palette.primaryDark),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (logo != null) ...[
          pw.Container(
            width: 56,
            height: 56,
            decoration: pw.BoxDecoration(
              color: PdfColors.white,
              borderRadius: pw.BorderRadius.circular(8),
            ),
            padding: const pw.EdgeInsets.all(4),
            child: pw.Image(logo, fit: pw.BoxFit.contain),
          ),
          pw.SizedBox(width: 14),
        ],
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                store.tradeName?.isNotEmpty == true ? store.tradeName! : store.legalName,
                style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              ),
              if (store.tradeName?.isNotEmpty == true && store.tradeName != store.legalName)
                pw.Text(store.legalName, style: pw.TextStyle(fontSize: 9, color: PdfColors.white.shade(0.15))),
              pw.SizedBox(height: 6),
              pw.Text(store.fullAddress, style: pw.TextStyle(fontSize: 8.5, color: PdfColors.white.shade(0.1))),
              pw.SizedBox(height: 3),
              pw.Wrap(
                spacing: 14,
                children: [
                  if (store.phone != null && store.phone!.isNotEmpty)
                    _headerChip('Ph: ${store.phone}'),
                  if (store.email != null && store.email!.isNotEmpty) _headerChip(store.email!),
                  if (store.gstin != null && store.gstin!.isNotEmpty) _headerChip('GSTIN: ${store.gstin}'),
                  if (store.fssaiLicenseNo != null && store.fssaiLicenseNo!.isNotEmpty)
                    _headerChip('FSSAI: ${store.fssaiLicenseNo}'),
                ],
              ),
            ],
          ),
        ),
        pw.SizedBox(width: 12),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: pw.BoxDecoration(
                color: PdfColors.white,
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Text(
                'TAX INVOICE',
                style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _Palette.primaryDark, letterSpacing: 0.6),
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Text('# ${invoice.invoiceNumber}', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
          ],
        ),
      ],
    ),
  );
}

pw.Widget _headerChip(String text) => pw.Text(text, style: pw.TextStyle(fontSize: 8, color: PdfColors.white.shade(0.1)));

/// A slim repeated banner shown on every page after the first, so a
/// multi-page invoice never loses track of which invoice/customer it is.
pw.Widget _continuationBanner(InvoiceDetail invoice) {
  return pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.symmetric(horizontal: 28, vertical: 10),
    color: _Palette.tealTint,
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text('Invoice ${invoice.invoiceNumber} (contd.)', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _Palette.primaryDark)),
        pw.Text(invoice.store.tradeName ?? invoice.store.legalName, style: const pw.TextStyle(fontSize: 9, color: _Palette.slate)),
      ],
    ),
  );
}

pw.Widget _pageFooter(pw.Context context) {
  return pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 28, vertical: 8),
    decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _Palette.border, width: 0.6))),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text('This is a computer-generated invoice.', style: const pw.TextStyle(fontSize: 7.5, color: _Palette.slateLight)),
        pw.Text('Page ${context.pageNumber} of ${context.pagesCount}', style: const pw.TextStyle(fontSize: 7.5, color: _Palette.slateLight)),
      ],
    ),
  );
}

/// Invoice date/payment-status meta on the left, "Bill To" customer card on
/// the right — both inside soft outlined cards for visual separation from
/// the items table below.
pw.Widget _metaAndPartiesRow(InvoiceDetail invoice, DateFormat dateFmt) {
  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(
            color: _Palette.zebra,
            borderRadius: pw.BorderRadius.circular(6),
            border: pw.Border.all(color: _Palette.border, width: 0.6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('INVOICE DETAILS', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _Palette.slateLight, letterSpacing: 0.5)),
              pw.SizedBox(height: 6),
              _metaLine('Invoice No.', invoice.invoiceNumber),
              if (invoice.finalizedAt != null) _metaLine('Date', dateFmt.format(invoice.finalizedAt!)),
              pw.SizedBox(height: 4),
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: pw.BoxDecoration(
                  color: _statusColor(invoice.paymentStatus),
                  borderRadius: pw.BorderRadius.circular(3),
                ),
                child: pw.Text(
                  invoice.paymentStatus,
                  style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: PdfColors.white, letterSpacing: 0.4),
                ),
              ),
            ],
          ),
        ),
      ),
      pw.SizedBox(width: 14),
      pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(
            color: PdfColors.white,
            borderRadius: pw.BorderRadius.circular(6),
            border: pw.Border.all(color: _Palette.primary, width: 0.8),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('BILL TO', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _Palette.primary, letterSpacing: 0.5)),
              pw.SizedBox(height: 6),
              pw.Text(
                invoice.customerName ?? 'Walk-in Customer',
                style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: _Palette.ink),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

pw.Widget _metaLine(String label, String value) {
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 3),
    child: pw.Row(
      children: [
        pw.SizedBox(width: 62, child: pw.Text(label, style: const pw.TextStyle(fontSize: 8.5, color: _Palette.slateLight))),
        pw.Text(value, style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: _Palette.ink)),
      ],
    ),
  );
}

pw.Widget _lineItemsTable(InvoiceDetail invoice) {
  final headers = ['#', 'Item', 'HSN', 'Qty', 'Rate', 'Disc', 'Taxable', 'Tax', 'Total'];
  const flex = [0.4, 2.3, 0.9, 0.7, 0.9, 0.7, 0.95, 1.5, 0.95];

  pw.Widget headerCell(String text, int i) => pw.Expanded(
        flex: (flex[i] * 100).round(),
        child: pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: pw.Text(text, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
        ),
      );

  pw.Widget bodyCell(String text, int i, {bool bold = false}) => pw.Expanded(
        flex: (flex[i] * 100).round(),
        child: pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          child: pw.Text(text, style: pw.TextStyle(fontSize: 8, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: _Palette.ink)),
        ),
      );

  final rows = <pw.Widget>[
    pw.Container(
      decoration: const pw.BoxDecoration(color: _Palette.primary),
      child: pw.Row(children: [for (var i = 0; i < headers.length; i++) headerCell(headers[i], i)]),
    ),
  ];

  for (var i = 0; i < invoice.lines.length; i++) {
    final l = invoice.lines[i];
    final taxLabel = l.taxBreakdown.isEmpty
        ? '0.00'
        : l.taxBreakdown.map((t) => '${t.taxType} ${t.rate.toStringAsFixed(2)}%: ${_money(t.amount)}').join('\n');
    rows.add(
      pw.Container(
        decoration: pw.BoxDecoration(
          color: i.isEven ? PdfColors.white : _Palette.zebra,
          border: const pw.Border(bottom: pw.BorderSide(color: _Palette.border, width: 0.5)),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            bodyCell('${i + 1}', 0),
            bodyCell('${l.productName}\n${l.sku} . ${l.uomCode}', 1, bold: true),
            bodyCell(l.hsn ?? '-', 2),
            bodyCell(l.quantity.toString(), 3),
            bodyCell(l.unitPrice.toStringAsFixed(2), 4),
            bodyCell(l.discountAmount.toStringAsFixed(2), 5),
            bodyCell(l.taxableValue.toStringAsFixed(2), 6),
            bodyCell(taxLabel, 7),
            bodyCell(l.lineTotal.toStringAsFixed(2), 8, bold: true),
          ],
        ),
      ),
    );
  }

  return pw.ClipRRect(
    horizontalRadius: 6,
    verticalRadius: 6,
    child: pw.Container(
      decoration: pw.BoxDecoration(border: pw.Border.all(color: _Palette.border, width: 0.6)),
      child: pw.Column(children: rows),
    ),
  );
}

/// Payment/tenders on the left, the totals breakdown with a highlighted
/// grand-total banner on the right — the classic two-column invoice footer.
pw.Widget _totalsAndTendersRow(InvoiceDetail invoice) {
  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(child: _tendersBlock(invoice)),
      pw.SizedBox(width: 16),
      pw.SizedBox(width: 230, child: _totalsBlock(invoice)),
    ],
  );
}

pw.Widget _totalsBlock(InvoiceDetail invoice) {
  pw.Widget row(String label, String value, {bool bold = false, PdfColor? color}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: color ?? _Palette.slate)),
          pw.Text(value, style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: color ?? _Palette.ink)),
        ],
      ),
    );
  }

  return pw.Container(
    padding: const pw.EdgeInsets.all(14),
    decoration: pw.BoxDecoration(
      color: _Palette.zebra,
      borderRadius: pw.BorderRadius.circular(6),
      border: pw.Border.all(color: _Palette.border, width: 0.6),
    ),
    child: pw.Column(
      children: [
        row('Subtotal', _money(invoice.subtotal)),
        if (invoice.discountTotal.toStringAsFixed(2) != '0.00') row('Discount', '-${_money(invoice.discountTotal)}', color: _Palette.red),
        row('Taxable Total', _money(invoice.taxableTotal)),
        row('Tax Total', _money(invoice.taxTotal)),
        if (invoice.roundingAmount.toStringAsFixed(2) != '0.00') row('Rounding', _money(invoice.roundingAmount)),
        pw.SizedBox(height: 4),
        pw.Container(
          margin: const pw.EdgeInsets.only(top: 4),
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: pw.BoxDecoration(color: _Palette.primaryDark, borderRadius: pw.BorderRadius.circular(5)),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('GRAND TOTAL', style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold, color: PdfColors.white, letterSpacing: 0.4)),
              pw.Text(_money(invoice.grandTotal), style: pw.TextStyle(fontSize: 12.5, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
            ],
          ),
        ),
      ],
    ),
  );
}

pw.Widget _tendersBlock(InvoiceDetail invoice) {
  return pw.Container(
    padding: const pw.EdgeInsets.all(14),
    decoration: pw.BoxDecoration(
      color: PdfColors.white,
      borderRadius: pw.BorderRadius.circular(6),
      border: pw.Border.all(color: _Palette.border, width: 0.6),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('PAYMENT DETAILS', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _Palette.slateLight, letterSpacing: 0.5)),
        pw.SizedBox(height: 8),
        if (invoice.tenders.isEmpty)
          pw.Text('No tender recorded', style: const pw.TextStyle(fontSize: 9, color: _Palette.slateLight))
        else
          ...invoice.tenders.map(
            (t) => pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 3),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: pw.BoxDecoration(color: _Palette.tealTint, borderRadius: pw.BorderRadius.circular(3)),
                    child: pw.Text(t.method, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _Palette.primaryDark)),
                  ),
                  pw.Text(_money(t.amount), style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: _Palette.ink)),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

pw.Widget _thankYouBand(String text) {
  return pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: pw.BoxDecoration(
      color: _Palette.tealTint,
      borderRadius: pw.BorderRadius.circular(6),
      border: pw.Border.all(color: _Palette.primary, width: 0.5),
    ),
    child: pw.Center(
      child: pw.Text(text, style: pw.TextStyle(fontSize: 9.5, fontStyle: pw.FontStyle.italic, color: _Palette.primaryDark)),
    ),
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
