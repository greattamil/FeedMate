import 'package:decimal/decimal.dart';

import '../../core/api_client.dart';

class InvoiceSummary {
  final String id;
  final String invoiceNumber;
  final String? customerName;
  final Decimal grandTotal;
  final String paymentStatus;
  final DateTime? finalizedAt;

  InvoiceSummary({
    required this.id,
    required this.invoiceNumber,
    required this.customerName,
    required this.grandTotal,
    required this.paymentStatus,
    required this.finalizedAt,
  });

  factory InvoiceSummary.fromJson(Map<String, dynamic> json) {
    return InvoiceSummary(
      id: json['id'] as String,
      invoiceNumber: json['invoice_number'] as String,
      customerName: json['customer_name'] as String?,
      grandTotal: Decimal.parse(json['grand_total'] as String),
      paymentStatus: json['payment_status'] as String,
      finalizedAt: json['finalized_at'] == null ? null : DateTime.parse(json['finalized_at'] as String),
    );
  }
}

class InvoiceLineDetail {
  final String productName;
  final String sku;
  final String uomCode;
  final Decimal quantity;
  final Decimal unitPrice;
  final Decimal lineTotal;

  InvoiceLineDetail({
    required this.productName,
    required this.sku,
    required this.uomCode,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
  });

  factory InvoiceLineDetail.fromJson(Map<String, dynamic> json) {
    return InvoiceLineDetail(
      productName: json['product_name'] as String,
      sku: json['sku'] as String,
      uomCode: json['uom_code'] as String,
      quantity: Decimal.parse(json['quantity'] as String),
      unitPrice: Decimal.parse(json['unit_price'] as String),
      lineTotal: Decimal.parse(json['line_total'] as String),
    );
  }
}

class InvoiceTenderDetail {
  final String method;
  final Decimal amount;

  InvoiceTenderDetail({required this.method, required this.amount});

  factory InvoiceTenderDetail.fromJson(Map<String, dynamic> json) {
    return InvoiceTenderDetail(method: json['method'] as String, amount: Decimal.parse(json['amount'] as String));
  }
}

/// The full reprint view of one past sale — mirrors the server's
/// GetInvoiceDetail response (services/api/internal/httpapi/pos_handlers.go).
class InvoiceDetail {
  final String id;
  final String invoiceNumber;
  final String? customerName;
  final Decimal taxableTotal;
  final Decimal taxTotal;
  final Decimal grandTotal;
  final String paymentStatus;
  final DateTime? finalizedAt;
  final List<InvoiceLineDetail> lines;
  final List<InvoiceTenderDetail> tenders;

  InvoiceDetail({
    required this.id,
    required this.invoiceNumber,
    required this.customerName,
    required this.taxableTotal,
    required this.taxTotal,
    required this.grandTotal,
    required this.paymentStatus,
    required this.finalizedAt,
    required this.lines,
    required this.tenders,
  });

  factory InvoiceDetail.fromJson(Map<String, dynamic> json) {
    return InvoiceDetail(
      id: json['id'] as String,
      invoiceNumber: json['invoice_number'] as String,
      customerName: json['customer_name'] as String?,
      taxableTotal: Decimal.parse(json['taxable_total'] as String),
      taxTotal: Decimal.parse(json['tax_total'] as String),
      grandTotal: Decimal.parse(json['grand_total'] as String),
      paymentStatus: json['payment_status'] as String,
      finalizedAt: json['finalized_at'] == null ? null : DateTime.parse(json['finalized_at'] as String),
      lines: (json['lines'] as List<dynamic>).map((l) => InvoiceLineDetail.fromJson(l as Map<String, dynamic>)).toList(),
      tenders: (json['tenders'] as List<dynamic>).map((t) => InvoiceTenderDetail.fromJson(t as Map<String, dynamic>)).toList(),
    );
  }
}

/// Wraps GET /api/v1/pos/invoices/history and GET /api/v1/pos/invoices/{id}
/// — the invoice history/reprint screen's read endpoints.
class InvoiceHistoryApi {
  final ApiClient client;

  InvoiceHistoryApi(this.client);

  Future<List<InvoiceSummary>> list({String query = '', int limit = 50, int offset = 0}) async {
    final params = {
      if (query.isNotEmpty) 'q': query,
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    final qs = params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
    final response = await client.getAuthed('/api/v1/pos/invoices/history?$qs');
    return (response['invoices'] as List<dynamic>)
        .map((i) => InvoiceSummary.fromJson(i as Map<String, dynamic>))
        .toList();
  }

  Future<InvoiceDetail> getDetail(String invoiceId) async {
    final response = await client.getAuthed('/api/v1/pos/invoices/$invoiceId');
    return InvoiceDetail.fromJson(response);
  }
}
