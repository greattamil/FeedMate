import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:feedmate_app/features/customers/receipt_pdf.dart';
import 'package:feedmate_app/features/settings/store_settings_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Redirects path_provider's platform channel calls to a real temp
/// directory so downloadReceiptPdf() can be tested without a device — see
/// invoice_pdf_test.dart's identical fake for the same reasoning.
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

StoreProfile _sampleStore({String? logoDataUri}) {
  return StoreProfile(
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
    invoicePrefix: 'INV',
    receiptHeader: null,
    receiptFooter: 'Thank you for your business',
    logoDataUri: logoDataUri,
  );
}

PaymentReceiptData _sampleReceipt({String paymentId = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890', String? logoDataUri}) {
  return PaymentReceiptData(
    paymentId: paymentId,
    receivedAt: DateTime(2026, 9, 24, 10, 30),
    customerName: 'Ramadas Mariyappan',
    customerCode: 'ABCD0001',
    customerPhone: '9789233066',
    amount: Decimal.parse('800.00'),
    method: 'CASH',
    reference: null,
    balanceBefore: Decimal.parse('5000.00'),
    balanceAfter: Decimal.parse('4200.00'),
    receivedByName: 'Test Cashier',
    store: _sampleStore(logoDataUri: logoDataUri),
  );
}

void main() {
  test('the generated receipt PDF is a real, non-empty PDF document', () async {
    final doc = buildReceiptPdf(_sampleReceipt());
    final bytes = await doc.save();
    expect(bytes.length, greaterThan(500));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('embeds a real store logo image when one is set', () async {
    const onePixelPng =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    final doc = buildReceiptPdf(_sampleReceipt(logoDataUri: onePixelPng));
    final bytes = await doc.save();
    expect(bytes.length, greaterThan(500));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('a corrupt logo data URI never breaks PDF generation', () async {
    final doc = buildReceiptPdf(_sampleReceipt(logoDataUri: 'data:image/png;base64,not-valid!!!'));
    final bytes = await doc.save();
    expect(bytes.length, greaterThan(500));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test(
    'receipt_pdf.dart never emits the literal rupee sign — same core-font constraint as invoice_pdf.dart',
    () {
      final source = File('lib/features/customers/receipt_pdf.dart').readAsStringSync();
      expect(source.contains('₹'), isFalse, reason: 'Found a literal ₹ in receipt_pdf.dart — it will render as a blank box in the PDF.');
    },
  );

  group('receiptNumber', () {
    test('derives a short, readable number from a real UUID payment id', () {
      final receipt = _sampleReceipt(paymentId: 'a1b2c3d4-e5f6-7890-abcd-ef1234567890');
      expect(receipt.receiptNumber, 'RCPT-260924-A1B2C3');
    });

    test('never throws for a payment id shorter than the usual UUID shape', () {
      // A real backend always returns a UUID, but the receipt number must
      // never crash regardless — this exact case (a short mock payment_id
      // like "pay-1") previously threw a RangeError from an unguarded
      // substring(0, 6) call.
      final receipt = _sampleReceipt(paymentId: 'pay-1');
      expect(() => receipt.receiptNumber, returnsNormally);
      expect(receipt.receiptNumber, 'RCPT-260924-PAY1');
    });

    test('never throws for an empty payment id', () {
      final receipt = _sampleReceipt(paymentId: '');
      expect(() => receipt.receiptNumber, returnsNormally);
      expect(receipt.receiptNumber, 'RCPT-260924-');
    });
  });

  test('downloadReceiptPdf writes a real, non-empty PDF file to disk', () async {
    final tempDir = await Directory.systemTemp.createTemp('receipt_pdf_test');
    addTearDown(() => tempDir.delete(recursive: true));
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir);

    final result = await downloadReceiptPdf(_sampleReceipt());

    expect(result.sharedInstead, isFalse);
    expect(result.savedPath, isNotNull);
    final file = File(result.savedPath!);
    expect(file.existsSync(), isTrue);
    final bytes = await file.readAsBytes();
    expect(bytes.length, greaterThan(500));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(result.savedPath, contains('RCPT-260924-A1B2C3.pdf'));
  });
}
