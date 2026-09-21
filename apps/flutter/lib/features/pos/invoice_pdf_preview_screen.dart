import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'invoice_history_api.dart';
import 'invoice_pdf.dart';

/// A real, paginated, zoomable preview of the exact PDF [shareInvoicePdf]
/// and [downloadInvoicePdf] would produce — built from the same
/// [buildInvoicePdf] the other two actions use, so what the cashier
/// previews here is never a different document from what gets shared or
/// saved. Uses the `printing` package's PdfPreview widget (from the same
/// author as the `pdf` package this app already depends on), which also
/// gives print and share affordances of its own for free.
class InvoicePdfPreviewScreen extends StatelessWidget {
  final InvoiceDetail invoice;
  const InvoicePdfPreviewScreen({super.key, required this.invoice});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Preview — ${invoice.invoiceNumber}')),
      body: PdfPreview(
        key: const Key('invoice_pdf_preview'),
        build: (format) => buildInvoicePdf(invoice).save(),
        allowPrinting: true,
        allowSharing: true,
        canChangePageFormat: false,
        canChangeOrientation: false,
        pdfFileName: 'Invoice_${invoice.invoiceNumber.replaceAll('/', '-')}.pdf',
      ),
    );
  }
}
