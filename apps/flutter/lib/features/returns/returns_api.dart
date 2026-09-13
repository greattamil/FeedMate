import 'package:decimal/decimal.dart';

import '../../core/api_client.dart';

/// One line of a past sale, with how much of it is still eligible to
/// return (never more than sold minus what's already been returned via a
/// POSTED return — PRD 9.7). The server always re-derives this at post
/// time; `remainingEligible` here is only a display/pre-check hint.
class InvoiceLineForReturn {
  final String id;
  final String productId;
  final String productName;
  final String sku;
  final Decimal quantity;
  final Decimal unitPrice;
  final Decimal lineTotal;
  final Decimal alreadyReturned;
  final Decimal remainingEligible;

  InvoiceLineForReturn({
    required this.id,
    required this.productId,
    required this.productName,
    required this.sku,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    required this.alreadyReturned,
    required this.remainingEligible,
  });

  factory InvoiceLineForReturn.fromJson(Map<String, dynamic> json) {
    return InvoiceLineForReturn(
      id: json['id'] as String,
      productId: json['product_id'] as String,
      productName: json['product_name'] as String,
      sku: json['sku'] as String,
      quantity: Decimal.parse(json['quantity'] as String),
      unitPrice: Decimal.parse(json['unit_price'] as String),
      lineTotal: Decimal.parse(json['line_total'] as String),
      alreadyReturned: Decimal.parse(json['already_returned'] as String),
      remainingEligible: Decimal.parse(json['remaining_eligible'] as String),
    );
  }
}

class InvoiceForReturn {
  final String id;
  final String invoiceNumber;
  final Decimal grandTotal;
  final String status;
  final List<InvoiceLineForReturn> lines;

  InvoiceForReturn({
    required this.id,
    required this.invoiceNumber,
    required this.grandTotal,
    required this.status,
    required this.lines,
  });

  factory InvoiceForReturn.fromJson(Map<String, dynamic> json) {
    return InvoiceForReturn(
      id: json['id'] as String,
      invoiceNumber: json['invoice_number'] as String,
      grandTotal: Decimal.parse(json['grand_total'] as String),
      status: json['status'] as String,
      lines: (json['lines'] as List<dynamic>)
          .map((l) => InvoiceLineForReturn.fromJson(l as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// One line the cashier has decided to return, built from an
/// InvoiceLineForReturn plus what they entered.
class ReturnLineDraft {
  final InvoiceLineForReturn original;
  Decimal quantity;
  String conditionStatus; // SELLABLE, DAMAGED, EXPIRED, QUARANTINE, OTHER
  String? restockLocationId; // required unless conditionStatus == SELLABLE

  ReturnLineDraft({
    required this.original,
    required this.quantity,
    this.conditionStatus = 'SELLABLE',
    this.restockLocationId,
  });
}

class PostReturnResult {
  final String returnId;
  final String returnNumber;
  final Decimal totalRefund;

  PostReturnResult({required this.returnId, required this.returnNumber, required this.totalRefund});

  factory PostReturnResult.fromJson(Map<String, dynamic> json) {
    return PostReturnResult(
      returnId: json['return_id'] as String,
      returnNumber: json['return_number'] as String,
      totalRefund: Decimal.parse(json['total_refund'] as String),
    );
  }
}

/// Wraps the sales-return endpoints: looking an invoice up by its printed
/// number to see what's still eligible to return, and posting the return
/// itself. All business logic (eligible-quantity validation, restock vs.
/// quarantine routing, proportional tax reversal, refund posting) lives
/// server-side — see services/api/internal/domain/returns/service.go.
class ReturnsApi {
  final ApiClient client;

  ReturnsApi(this.client);

  Future<InvoiceForReturn> lookupInvoice(String invoiceNumber) async {
    final response = await client.getAuthed('/api/v1/pos/invoices?number=${Uri.encodeQueryComponent(invoiceNumber)}');
    return InvoiceForReturn.fromJson(response);
  }

  Future<PostReturnResult> postReturn({
    required String originalInvoiceId,
    String? reason,
    required List<ReturnLineDraft> lines,
    required String refundMethod,
  }) async {
    final body = {
      'original_invoice_id': originalInvoiceId,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
      'refund_method': refundMethod,
      'lines': lines
          .map((l) => {
                'original_line_id': l.original.id,
                'quantity': l.quantity.toString(),
                'condition_status': l.conditionStatus,
                if (l.conditionStatus != 'SELLABLE' && l.restockLocationId != null)
                  'restock_location_id': l.restockLocationId,
              })
          .toList(),
    };
    final response = await client.postAuthed('/api/v1/pos/returns', body);
    return PostReturnResult.fromJson(response);
  }
}
