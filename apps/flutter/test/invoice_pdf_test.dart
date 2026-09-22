import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:feedmate_app/features/pos/invoice_history_api.dart';
import 'package:feedmate_app/features/pos/invoice_pdf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Redirects path_provider's platform channel calls to a real temp
/// directory so downloadInvoicePdf() can be tested without a device —
/// getDownloadsDirectory() intentionally returns null here to exercise the
/// same "unsupported on this platform" fallback path Android takes.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.dir);
  final Directory dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;

  @override
  Future<String?> getExternalStoragePath() async => dir.path;

  @override
  Future<String?> getDownloadsPath() async => null;
}

InvoiceDetail _sampleInvoice() {
  return InvoiceDetail(
    id: 'inv-1',
    invoiceNumber: 'INV-0001',
    customerName: null,
    subtotal: Decimal.parse('1050.00'),
    discountTotal: Decimal.parse('0.00'),
    taxableTotal: Decimal.parse('1050.00'),
    taxTotal: Decimal.parse('52.50'),
    roundingAmount: Decimal.parse('0.00'),
    grandTotal: Decimal.parse('1102.50'),
    paymentStatus: 'PAID',
    finalizedAt: DateTime(2026, 9, 15, 8, 23),
    lines: [
      InvoiceLineDetail(
        productName: 'Cattle Feed Economy 50kg',
        sku: 'CF-ECO-01',
        hsn: null,
        uomCode: 'BAG',
        quantity: Decimal.parse('1'),
        unitPrice: Decimal.parse('1050.00'),
        discountAmount: Decimal.parse('0.00'),
        taxableValue: Decimal.parse('1050.00'),
        taxTotal: Decimal.parse('52.50'),
        lineTotal: Decimal.parse('1102.50'),
        taxBreakdown: [
          InvoiceLineTax(taxType: 'CGST', rate: Decimal.parse('2.50'), amount: Decimal.parse('26.25')),
          InvoiceLineTax(taxType: 'SGST', rate: Decimal.parse('2.50'), amount: Decimal.parse('26.25')),
        ],
      ),
    ],
    tenders: [InvoiceTenderDetail(method: 'CASH', amount: Decimal.parse('1102.50'))],
    store: InvoiceStoreDetail(
      legalName: 'Bala Feeds',
      tradeName: null,
      gstin: '33AAAAA0000A1Z5',
      fssaiLicenseNo: null,
      phone: '9998887770',
      email: null,
      addressLine1: 'Main Road',
      addressLine2: null,
      city: 'Andipatti',
      district: null,
      stateCode: 'TN',
      postalCode: null,
      receiptHeader: null,
      receiptFooter: 'Thank you for your business',
      logoDataUri: null,
    ),
  );
}

InvoiceDetail _sampleInvoiceWithLogo() {
  final base = _sampleInvoice();
  // A minimal valid 1x1 PNG, base64-encoded — enough to prove the PDF
  // builder actually decodes and embeds real image bytes rather than
  // silently ignoring the field.
  const onePixelPng =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
  return InvoiceDetail(
    id: base.id,
    invoiceNumber: base.invoiceNumber,
    customerName: base.customerName,
    subtotal: base.subtotal,
    discountTotal: base.discountTotal,
    taxableTotal: base.taxableTotal,
    taxTotal: base.taxTotal,
    roundingAmount: base.roundingAmount,
    grandTotal: base.grandTotal,
    paymentStatus: base.paymentStatus,
    finalizedAt: base.finalizedAt,
    lines: base.lines,
    tenders: base.tenders,
    store: InvoiceStoreDetail(
      legalName: base.store.legalName,
      tradeName: base.store.tradeName,
      gstin: base.store.gstin,
      fssaiLicenseNo: base.store.fssaiLicenseNo,
      phone: base.store.phone,
      email: base.store.email,
      addressLine1: base.store.addressLine1,
      addressLine2: base.store.addressLine2,
      city: base.store.city,
      district: base.store.district,
      stateCode: base.store.stateCode,
      postalCode: base.store.postalCode,
      receiptHeader: base.store.receiptHeader,
      receiptFooter: base.store.receiptFooter,
      logoDataUri: onePixelPng,
    ),
  );
}

void main() {
  test('the generated invoice PDF is a real, non-empty PDF document', () async {
    final doc = buildInvoicePdf(_sampleInvoice());
    final bytes = await doc.save();
    expect(bytes.length, greaterThan(500));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('embeds a real store logo image when one is set on the invoice', () async {
    final doc = buildInvoicePdf(_sampleInvoiceWithLogo());
    final bytes = await doc.save();
    expect(bytes.length, greaterThan(500));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('a corrupt logo data URI never breaks PDF generation', () async {
    final base = _sampleInvoice();
    final withBadLogo = InvoiceDetail(
      id: base.id,
      invoiceNumber: base.invoiceNumber,
      customerName: base.customerName,
      subtotal: base.subtotal,
      discountTotal: base.discountTotal,
      taxableTotal: base.taxableTotal,
      taxTotal: base.taxTotal,
      roundingAmount: base.roundingAmount,
      grandTotal: base.grandTotal,
      paymentStatus: base.paymentStatus,
      finalizedAt: base.finalizedAt,
      lines: base.lines,
      tenders: base.tenders,
      store: InvoiceStoreDetail(
        legalName: base.store.legalName,
        tradeName: base.store.tradeName,
        gstin: base.store.gstin,
        fssaiLicenseNo: base.store.fssaiLicenseNo,
        phone: base.store.phone,
        email: base.store.email,
        addressLine1: base.store.addressLine1,
        addressLine2: base.store.addressLine2,
        city: base.store.city,
        district: base.store.district,
        stateCode: base.store.stateCode,
        postalCode: base.store.postalCode,
        receiptHeader: base.store.receiptHeader,
        receiptFooter: base.store.receiptFooter,
        logoDataUri: 'data:image/png;base64,not-actually-valid-base64!!!',
      ),
    );
    final doc = buildInvoicePdf(withBadLogo);
    final bytes = await doc.save();
    expect(bytes.length, greaterThan(500));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test(
    'invoice_pdf.dart never emits the literal rupee sign — the pdf package\'s '
    'default core Helvetica font has no glyph for U+20B9, so any "₹" literal '
    'renders as a blank tofu box in the shared PDF (caught live on a real '
    'device: the PDF opened via the share sheet showed boxes where every '
    'amount should be). Currency must be formatted as "Rs.<amount>" instead.',
    () {
      final source = File('lib/features/pos/invoice_pdf.dart').readAsStringSync();
      expect(source.contains('₹'), isFalse, reason: 'Found a literal ₹ in invoice_pdf.dart — it will render as a blank box in the PDF.');
    },
  );

  test('downloadInvoicePdf writes a real, non-empty PDF file to disk', () async {
    final tempDir = await Directory.systemTemp.createTemp('invoice_pdf_test');
    addTearDown(() => tempDir.delete(recursive: true));
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir);

    final result = await downloadInvoicePdf(_sampleInvoice());

    expect(result.sharedInstead, isFalse);
    expect(result.savedPath, isNotNull);
    final file = File(result.savedPath!);
    expect(file.existsSync(), isTrue);
    final bytes = await file.readAsBytes();
    expect(bytes.length, greaterThan(500));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(result.savedPath, contains('Invoice_INV-0001.pdf'));
  });
}
