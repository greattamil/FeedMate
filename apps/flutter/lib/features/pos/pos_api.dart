import 'package:decimal/decimal.dart';
import 'package:uuid/uuid.dart';

import '../../core/api_client.dart';
import 'cart_model.dart';

class QuoteLineResult {
  final String productId;
  final String productName;
  final Decimal lineTotal;

  QuoteLineResult({required this.productId, required this.productName, required this.lineTotal});
}

class QuoteResult {
  final List<QuoteLineResult> lines;
  final Decimal taxableTotal;
  final Decimal taxTotal;
  final Decimal grandTotal;

  QuoteResult({required this.lines, required this.taxableTotal, required this.taxTotal, required this.grandTotal});

  factory QuoteResult.fromJson(Map<String, dynamic> json) {
    return QuoteResult(
      lines: (json['lines'] as List<dynamic>)
          .map((l) => QuoteLineResult(
                productId: l['product_id'] as String,
                productName: l['product_name'] as String,
                lineTotal: Decimal.parse(l['line_total'] as String),
              ))
          .toList(),
      taxableTotal: Decimal.parse(json['taxable_total'] as String),
      taxTotal: Decimal.parse(json['tax_total'] as String),
      grandTotal: Decimal.parse(json['grand_total'] as String),
    );
  }
}

class FinalizeResult {
  final String invoiceId;
  final String invoiceNumber;
  final Decimal grandTotal;
  final bool duplicate;

  FinalizeResult({
    required this.invoiceId,
    required this.invoiceNumber,
    required this.grandTotal,
    required this.duplicate,
  });

  factory FinalizeResult.fromJson(Map<String, dynamic> json) {
    return FinalizeResult(
      invoiceId: json['invoice_id'] as String,
      invoiceNumber: json['invoice_number'] as String,
      grandTotal: Decimal.parse(json['grand_total'] as String),
      duplicate: json['duplicate'] as bool? ?? false,
    );
  }
}

/// One tender line in a (possibly split) sale — e.g. part CASH, part CREDIT,
/// part UPI, in a single invoice. The server sums all tenders and requires
/// the total to exactly equal the invoice grand total (see
/// pos.ErrTenderMismatch); only the CREDIT portion counts toward a
/// customer's credit limit check.
class TenderInput {
  final String method; // CASH, UPI, BANK, CREDIT, OTHER
  final Decimal amount;

  TenderInput({required this.method, required this.amount});
}

class LocationInfo {
  final String id;
  final String name;

  LocationInfo({required this.id, required this.name});
}

/// Wraps the POS-related backend endpoints. Business logic (pricing, tax,
/// stock, credit) all lives server-side (see services/api/internal/domain/pos)
/// — this class only shapes requests/responses.
class PosApi {
  final ApiClient client;

  PosApi(this.client);

  List<Map<String, dynamic>> _linesPayload(List<CartLine> lines) {
    return lines
        .map((l) => {
              'product_id': l.product.id,
              'quantity': l.quantity.toString(),
            })
        .toList();
  }

  Future<QuoteResult> quote(List<CartLine> lines) async {
    final response = await client.postAuthed('/api/v1/pos/quote', {'lines': _linesPayload(lines)});
    return QuoteResult.fromJson(response);
  }

  /// Finalizes a sale with one or more tenders (CASH, CREDIT, UPI, BANK,
  /// OTHER) that must sum to exactly the invoice grand total — a single
  /// full-amount CASH or CREDIT tender is just the one-element case. A
  /// CREDIT tender requires a customer (the receivable is posted against
  /// their Khata ledger — see customer.PostLedgerEntry). If the CREDIT
  /// portion would push the customer over their configured credit limit,
  /// the server rejects it unless the cashier supplies an explicit override
  /// reason and holds the credit.override permission — permission alone is
  /// never sufficient (see docs/IMPLEMENTATION_STATUS.md's credit-override
  /// fix).
  Future<FinalizeResult> finalizeSale({
    required List<CartLine> lines,
    required String locationId,
    required List<TenderInput> tenders,
    String? customerId,
    bool overrideCreditLimit = false,
    String? overrideReason,
  }) async {
    final body = {
      'client_transaction_id': const Uuid().v4(),
      'location_id': locationId,
      'lines': _linesPayload(lines),
      'tenders': tenders.map((t) => {'method': t.method, 'amount': t.amount.toStringAsFixed(2)}).toList(),
      if (customerId != null) 'customer_id': customerId,
      if (overrideCreditLimit) 'override_credit_limit': true,
      if (overrideReason != null) 'override_reason': overrideReason,
    };
    final response = await client.postAuthed('/api/v1/pos/invoices', body);
    return FinalizeResult.fromJson(response);
  }

  Future<List<LocationInfo>> listLocations() async {
    final response = await client.getAuthed('/api/v1/locations');
    return (response['locations'] as List<dynamic>)
        .map((l) => LocationInfo(id: l['id'] as String, name: l['name'] as String))
        .toList();
  }
}
