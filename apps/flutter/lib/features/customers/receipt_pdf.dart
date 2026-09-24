import 'dart:convert';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../settings/store_settings_api.dart';

/// Everything needed to render a payment receipt, gathered client-side from
/// data the app already has at the moment a receipt is recorded — no new
/// backend endpoint required: the payment amount/method/reference and
/// resulting balance are already known from the record-receipt response and
/// the customer detail reload that follows it, and the shop's own profile
/// (including its uploaded logo) is the same StoreSettingsApi the invoice
/// PDF's store snapshot is ultimately sourced from.
class PaymentReceiptData {
  final String paymentId;
  final DateTime receivedAt;
  final String customerName;
  final String customerCode;
  final String? customerPhone;
  final Decimal amount;
  final String method;
  final String? reference;
  final Decimal balanceBefore;
  final Decimal balanceAfter;
  final String? receivedByName;
  final StoreProfile store;

  PaymentReceiptData({
    required this.paymentId,
    required this.receivedAt,
    required this.customerName,
    required this.customerCode,
    required this.customerPhone,
    required this.amount,
    required this.method,
    required this.reference,
    required this.balanceBefore,
    required this.balanceAfter,
    required this.receivedByName,
    required this.store,
  });

  /// A short, human-friendly receipt number derived from the payment's own
  /// id and date — there is no separate receipt-numbering sequence
  /// server-side, so this is deterministic (same payment always yields the
  /// same number) without needing one.
  String get receiptNumber {
    final datePart = DateFormat('yyMMdd').format(receivedAt);
    final stripped = paymentId.replaceAll('-', '');
    final shortId = stripped.substring(0, stripped.length < 6 ? stripped.length : 6).toUpperCase();
    return 'RCPT-$datePart-$shortId';
  }
}

class _Palette {
  static const primary = PdfColor.fromInt(0xFF0D9488);
  static const primaryDark = PdfColor.fromInt(0xFF0F766E);
  static const slate = PdfColor.fromInt(0xFF475569);
  static const slateLight = PdfColor.fromInt(0xFF64748B);
  static const ink = PdfColor.fromInt(0xFF0F172A);
  static const tealTint = PdfColor.fromInt(0xFFECFDF9);
  static const zebra = PdfColor.fromInt(0xFFF1F5F9);
  static const border = PdfColor.fromInt(0xFFE2E8F0);
  static const amber = PdfColor.fromInt(0xFFD97706);
  static const indigo = PdfColor.fromInt(0xFF4F46E5);
}

/// The rupee sign is missing from the pdf package's default core Helvetica
/// font and renders as a blank box — every amount here goes through this
/// helper instead of a raw currency literal (see invoice_pdf.dart's fuller
/// explanation of the same constraint).
String _money(Decimal amount) => 'Rs. ${amount.toStringAsFixed(2)}';

PdfColor _methodColor(String method) {
  switch (method) {
    case 'CASH':
      return _Palette.primary;
    case 'BANK':
      return _Palette.indigo;
    case 'UPI':
      return const PdfColor.fromInt(0xFF7C3AED);
    case 'OTHER':
    default:
      return _Palette.amber;
  }
}

/// Builds a complete, colorful payment receipt PDF — same visual language
/// as the invoice PDF (branded header band with logo, bordered detail
/// cards, a highlighted totals banner) so the two documents this app
/// produces read as one consistent product, not two different tools bolted
/// together.
pw.Document buildReceiptPdf(PaymentReceiptData data) {
  final doc = pw.Document();
  final dateFmt = DateFormat('dd MMM yyyy, h:mm a');

  pw.MemoryImage? logo;
  final logoDataUri = data.store.logoDataUri;
  if (logoDataUri != null && logoDataUri.isNotEmpty) {
    try {
      logo = pw.MemoryImage(base64Decode(logoDataUri.substring(logoDataUri.indexOf(',') + 1)));
    } catch (_) {
      logo = null;
    }
  }

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a5,
      margin: pw.EdgeInsets.zero,
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          _headerBand(data, logo),
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _metaRow(data, dateFmt),
                pw.SizedBox(height: 14),
                _receivedFromCard(data),
                pw.SizedBox(height: 14),
                _amountBanner(data),
                pw.SizedBox(height: 14),
                _detailsCard(data),
                pw.SizedBox(height: 14),
                _balanceCard(data),
                if (data.store.receiptFooter != null && data.store.receiptFooter!.isNotEmpty) ...[
                  pw.SizedBox(height: 16),
                  _thankYouBand(data.store.receiptFooter!),
                ],
                pw.SizedBox(height: 14),
                pw.Text(
                  'This is a computer-generated receipt.',
                  style: const pw.TextStyle(fontSize: 7.5, color: _Palette.slateLight),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  return doc;
}

pw.Widget _headerBand(PaymentReceiptData data, pw.MemoryImage? logo) {
  final store = data.store;
  return pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.fromLTRB(24, 22, 24, 18),
    decoration: const pw.BoxDecoration(color: _Palette.primaryDark),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (logo != null) ...[
          pw.Container(
            width: 44,
            height: 44,
            decoration: pw.BoxDecoration(color: PdfColors.white, borderRadius: pw.BorderRadius.circular(8)),
            padding: const pw.EdgeInsets.all(3),
            child: pw.Image(logo, fit: pw.BoxFit.contain),
          ),
          pw.SizedBox(width: 12),
        ],
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                store.tradeName?.isNotEmpty == true ? store.tradeName! : store.legalName,
                style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              ),
              pw.SizedBox(height: 4),
              pw.Text(_fullAddress(store), style: pw.TextStyle(fontSize: 7.5, color: PdfColors.white.shade(0.1))),
              if (store.phone != null && store.phone!.isNotEmpty)
                pw.Text('Ph: ${store.phone}', style: pw.TextStyle(fontSize: 7.5, color: PdfColors.white.shade(0.1))),
            ],
          ),
        ),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: pw.BoxDecoration(color: PdfColors.white, borderRadius: pw.BorderRadius.circular(4)),
          child: pw.Text(
            'PAYMENT RECEIPT',
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _Palette.primaryDark, letterSpacing: 0.4),
          ),
        ),
      ],
    ),
  );
}

String _fullAddress(StoreProfile store) {
  final parts = [
    store.addressLine1,
    if (store.addressLine2 != null && store.addressLine2!.isNotEmpty) store.addressLine2,
    store.city,
    store.stateCode,
    if (store.postalCode != null && store.postalCode!.isNotEmpty) store.postalCode,
  ];
  return parts.where((p) => p != null && p.isNotEmpty).join(', ');
}

pw.Widget _metaRow(PaymentReceiptData data, DateFormat dateFmt) {
  return pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('Receipt No.', style: const pw.TextStyle(fontSize: 7.5, color: _Palette.slateLight)),
          pw.Text(data.receiptNumber, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _Palette.ink)),
        ],
      ),
      pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Text('Date', style: const pw.TextStyle(fontSize: 7.5, color: _Palette.slateLight)),
          pw.Text(dateFmt.format(data.receivedAt), style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _Palette.ink)),
        ],
      ),
    ],
  );
}

pw.Widget _receivedFromCard(PaymentReceiptData data) {
  return pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: PdfColors.white,
      borderRadius: pw.BorderRadius.circular(6),
      border: pw.Border.all(color: _Palette.primary, width: 0.8),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('RECEIVED FROM', style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: _Palette.primary, letterSpacing: 0.5)),
        pw.SizedBox(height: 5),
        pw.Text(data.customerName, style: pw.TextStyle(fontSize: 12.5, fontWeight: pw.FontWeight.bold, color: _Palette.ink)),
        pw.SizedBox(height: 2),
        pw.Text(
          [data.customerCode, if (data.customerPhone != null && data.customerPhone!.isNotEmpty) data.customerPhone].join('  ·  '),
          style: const pw.TextStyle(fontSize: 8.5, color: _Palette.slate),
        ),
      ],
    ),
  );
}

pw.Widget _amountBanner(PaymentReceiptData data) {
  return pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    decoration: pw.BoxDecoration(color: _Palette.primaryDark, borderRadius: pw.BorderRadius.circular(8)),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Text('AMOUNT RECEIVED', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.white, letterSpacing: 0.5)),
        pw.Text(_money(data.amount), style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
      ],
    ),
  );
}

pw.Widget _detailsCard(PaymentReceiptData data) {
  pw.Widget row(String label, pw.Widget value) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(label, style: const pw.TextStyle(fontSize: 9, color: _Palette.slateLight)),
            value,
          ],
        ),
      );

  return pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: _Palette.zebra,
      borderRadius: pw.BorderRadius.circular(6),
      border: pw.Border.all(color: _Palette.border, width: 0.6),
    ),
    child: pw.Column(
      children: [
        row(
          'Payment Method',
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: pw.BoxDecoration(color: _methodColor(data.method), borderRadius: pw.BorderRadius.circular(3)),
            child: pw.Text(data.method, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
          ),
        ),
        if (data.reference != null && data.reference!.isNotEmpty)
          row('Reference', pw.Text(data.reference!, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _Palette.ink))),
        if (data.receivedByName != null && data.receivedByName!.isNotEmpty)
          row('Received By', pw.Text(data.receivedByName!, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _Palette.ink))),
      ],
    ),
  );
}

pw.Widget _balanceCard(PaymentReceiptData data) {
  pw.Widget row(String label, String value, {bool bold = false, PdfColor? color}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(label, style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: color ?? _Palette.slate)),
            pw.Text(value, style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: color ?? _Palette.ink)),
          ],
        ),
      );

  return pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: PdfColors.white,
      borderRadius: pw.BorderRadius.circular(6),
      border: pw.Border.all(color: _Palette.border, width: 0.6),
    ),
    child: pw.Column(
      children: [
        row('Previous Outstanding', _money(data.balanceBefore)),
        row('Amount Received', '-${_money(data.amount)}'),
        pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 4), child: pw.Divider(color: _Palette.border, height: 1)),
        row(
          'New Outstanding Balance',
          _money(data.balanceAfter),
          bold: true,
          color: data.balanceAfter > Decimal.zero ? _Palette.amber : _Palette.primary,
        ),
      ],
    ),
  );
}

pw.Widget _thankYouBand(String text) {
  return pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: pw.BoxDecoration(
      color: _Palette.tealTint,
      borderRadius: pw.BorderRadius.circular(6),
      border: pw.Border.all(color: _Palette.primary, width: 0.5),
    ),
    child: pw.Center(
      child: pw.Text(text, style: pw.TextStyle(fontSize: 9, fontStyle: pw.FontStyle.italic, color: _Palette.primaryDark)),
    ),
  );
}

/// Renders [data] to a PDF and opens the platform share sheet — mirrors
/// invoice_pdf.dart's shareInvoicePdf() so every generated-document share
/// flow in this app behaves the same way.
Future<void> shareReceiptPdf(PaymentReceiptData data) async {
  final doc = buildReceiptPdf(data);
  final bytes = await doc.save();
  final fileName = '${data.receiptNumber}.pdf';
  final file = XFile.fromData(bytes, mimeType: 'application/pdf', name: fileName);
  await SharePlus.instance.share(ShareParams(files: [file], fileNameOverrides: [fileName]));
}

class ReceiptDownloadResult {
  final String? savedPath;
  final bool sharedInstead;
  const ReceiptDownloadResult({this.savedPath, this.sharedInstead = false});
}

/// Saves [data] as a real PDF file on disk — mirrors
/// invoice_pdf.dart's downloadInvoicePdf() exactly, including its web
/// fallback (no filesystem to write to there) and its Android/Windows/
/// macOS/Linux directory-resolution order.
Future<ReceiptDownloadResult> downloadReceiptPdf(PaymentReceiptData data) async {
  final doc = buildReceiptPdf(data);
  final bytes = await doc.save();
  final fileName = '${data.receiptNumber}.pdf';

  if (kIsWeb) {
    await shareReceiptPdf(data);
    return const ReceiptDownloadResult(sharedInstead: true);
  }

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
  return ReceiptDownloadResult(savedPath: path);
}
