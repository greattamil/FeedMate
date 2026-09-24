import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'receipt_pdf.dart';

/// A real, zoomable preview of the exact PDF [shareReceiptPdf] and
/// [downloadReceiptPdf] would produce, built from the same
/// [buildReceiptPdf] both actions use — mirrors
/// pos/invoice_pdf_preview_screen.dart's InvoicePdfPreviewScreen so the
/// two documents this app generates share one consistent preview/print/
/// share experience.
class ReceiptPdfPreviewScreen extends StatelessWidget {
  final PaymentReceiptData receipt;
  const ReceiptPdfPreviewScreen({super.key, required this.receipt});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Receipt — ${receipt.receiptNumber}')),
      body: PdfPreview(
        key: const Key('receipt_pdf_preview'),
        build: (format) => buildReceiptPdf(receipt).save(),
        allowPrinting: true,
        allowSharing: true,
        canChangePageFormat: false,
        canChangeOrientation: false,
        pdfFileName: '${receipt.receiptNumber}.pdf',
      ),
    );
  }
}
