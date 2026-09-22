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

/// One CGST/SGST/IGST/CESS component applied to a single invoice line.
class InvoiceLineTax {
  final String taxType;
  final Decimal rate;
  final Decimal amount;

  InvoiceLineTax({required this.taxType, required this.rate, required this.amount});

  factory InvoiceLineTax.fromJson(Map<String, dynamic> json) {
    return InvoiceLineTax(
      taxType: json['tax_type'] as String,
      rate: Decimal.parse(json['rate'] as String),
      amount: Decimal.parse(json['amount'] as String),
    );
  }
}

class InvoiceLineDetail {
  final String productName;
  final String sku;
  final String? hsn;
  final String uomCode;
  final Decimal quantity;
  final Decimal unitPrice;
  final Decimal discountAmount;
  final Decimal taxableValue;
  final Decimal taxTotal;
  final Decimal lineTotal;
  final List<InvoiceLineTax> taxBreakdown;

  InvoiceLineDetail({
    required this.productName,
    required this.sku,
    required this.hsn,
    required this.uomCode,
    required this.quantity,
    required this.unitPrice,
    required this.discountAmount,
    required this.taxableValue,
    required this.taxTotal,
    required this.lineTotal,
    required this.taxBreakdown,
  });

  factory InvoiceLineDetail.fromJson(Map<String, dynamic> json) {
    return InvoiceLineDetail(
      productName: json['product_name'] as String,
      sku: json['sku'] as String,
      hsn: json['hsn'] as String?,
      uomCode: json['uom_code'] as String,
      quantity: Decimal.parse(json['quantity'] as String),
      unitPrice: Decimal.parse(json['unit_price'] as String),
      discountAmount: Decimal.parse((json['discount_amount'] as String?) ?? '0'),
      taxableValue: Decimal.parse((json['taxable_value'] as String?) ?? '0'),
      taxTotal: Decimal.parse((json['tax_total'] as String?) ?? '0'),
      lineTotal: Decimal.parse(json['line_total'] as String),
      taxBreakdown: ((json['tax_breakdown'] as List<dynamic>?) ?? [])
          .map((t) => InvoiceLineTax.fromJson(t as Map<String, dynamic>))
          .toList(),
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

/// The tenant's shop identity/compliance details, embedded on every invoice
/// so a reprinted or shared invoice always reflects the store's details as
/// they were, matching the customer_name_snapshot precedent server-side.
class InvoiceStoreDetail {
  final String legalName;
  final String? tradeName;
  final String? gstin;
  final String? fssaiLicenseNo;
  final String? phone;
  final String? email;
  final String addressLine1;
  final String? addressLine2;
  final String city;
  final String? district;
  final String stateCode;
  final String? postalCode;
  final String? receiptHeader;
  final String? receiptFooter;
  final String? logoDataUri;

  InvoiceStoreDetail({
    required this.legalName,
    required this.tradeName,
    required this.gstin,
    required this.fssaiLicenseNo,
    required this.phone,
    required this.email,
    required this.addressLine1,
    required this.addressLine2,
    required this.city,
    required this.district,
    required this.stateCode,
    required this.postalCode,
    required this.receiptHeader,
    required this.receiptFooter,
    required this.logoDataUri,
  });

  factory InvoiceStoreDetail.fromJson(Map<String, dynamic> json) {
    return InvoiceStoreDetail(
      legalName: json['legal_name'] as String? ?? '',
      tradeName: json['trade_name'] as String?,
      gstin: json['gstin'] as String?,
      fssaiLicenseNo: json['fssai_license_no'] as String?,
      phone: json['phone'] as String?,
      email: json['email'] as String?,
      addressLine1: json['address_line1'] as String? ?? '',
      addressLine2: json['address_line2'] as String?,
      city: json['city'] as String? ?? '',
      district: json['district'] as String?,
      stateCode: json['state_code'] as String? ?? '',
      postalCode: json['postal_code'] as String?,
      receiptHeader: json['receipt_header'] as String?,
      receiptFooter: json['receipt_footer'] as String?,
      logoDataUri: json['logo_data_uri'] as String?,
    );
  }

  /// Single-line address for the invoice header/PDF.
  String get fullAddress {
    final parts = [
      addressLine1,
      if (addressLine2 != null && addressLine2!.isNotEmpty) addressLine2,
      city,
      if (district != null && district!.isNotEmpty) district,
      stateCode,
      if (postalCode != null && postalCode!.isNotEmpty) postalCode,
    ];
    return parts.where((p) => p != null && p.isNotEmpty).join(', ');
  }
}

/// The full reprint view of one past sale — mirrors the server's
/// GetInvoiceDetail response (services/api/internal/httpapi/pos_handlers.go).
class InvoiceDetail {
  final String id;
  final String invoiceNumber;
  final String? customerName;
  final Decimal subtotal;
  final Decimal discountTotal;
  final Decimal taxableTotal;
  final Decimal taxTotal;
  final Decimal roundingAmount;
  final Decimal grandTotal;
  final String paymentStatus;
  final DateTime? finalizedAt;
  final List<InvoiceLineDetail> lines;
  final List<InvoiceTenderDetail> tenders;
  final InvoiceStoreDetail store;

  InvoiceDetail({
    required this.id,
    required this.invoiceNumber,
    required this.customerName,
    required this.subtotal,
    required this.discountTotal,
    required this.taxableTotal,
    required this.taxTotal,
    required this.roundingAmount,
    required this.grandTotal,
    required this.paymentStatus,
    required this.finalizedAt,
    required this.lines,
    required this.tenders,
    required this.store,
  });

  factory InvoiceDetail.fromJson(Map<String, dynamic> json) {
    return InvoiceDetail(
      id: json['id'] as String,
      invoiceNumber: json['invoice_number'] as String,
      customerName: json['customer_name'] as String?,
      subtotal: Decimal.parse((json['subtotal'] as String?) ?? '0'),
      discountTotal: Decimal.parse((json['discount_total'] as String?) ?? '0'),
      taxableTotal: Decimal.parse(json['taxable_total'] as String),
      taxTotal: Decimal.parse(json['tax_total'] as String),
      roundingAmount: Decimal.parse((json['rounding_amount'] as String?) ?? '0'),
      grandTotal: Decimal.parse(json['grand_total'] as String),
      paymentStatus: json['payment_status'] as String,
      finalizedAt: json['finalized_at'] == null ? null : DateTime.parse(json['finalized_at'] as String),
      lines: (json['lines'] as List<dynamic>).map((l) => InvoiceLineDetail.fromJson(l as Map<String, dynamic>)).toList(),
      tenders: (json['tenders'] as List<dynamic>).map((t) => InvoiceTenderDetail.fromJson(t as Map<String, dynamic>)).toList(),
      store: InvoiceStoreDetail.fromJson((json['store'] as Map<String, dynamic>?) ?? const {}),
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
