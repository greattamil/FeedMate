import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:feedmate_app/features/pos/invoice_history_api.dart';
import 'package:feedmate_app/features/pos/invoice_pdf.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
