import 'package:decimal/decimal.dart';
import 'package:uuid/uuid.dart';

import '../../core/api_client.dart';

class SupplierSummary {
  final String id;
  final String supplierCode;
  final String name;
  final String? phone;
  final String? gstin;

  SupplierSummary({
    required this.id,
    required this.supplierCode,
    required this.name,
    required this.phone,
    required this.gstin,
  });

  factory SupplierSummary.fromJson(Map<String, dynamic> json) {
    return SupplierSummary(
      id: json['id'] as String,
      supplierCode: json['supplier_code'] as String,
      name: json['name'] as String,
      phone: json['phone'] as String?,
      gstin: json['gstin'] as String?,
    );
  }
}

/// Mirrors CustomerDetail (customer_api.dart) on the payable side: identity
/// plus the live outstanding balance, always computed server-side from the
/// ledger — never cached client-side as a stored field.
class SupplierDetail {
  final String id;
  final String supplierCode;
  final String name;
  final String? tradeName;
  final String? phone;
  final String? gstin;
  final String? email;
  final int paymentTermsDays;
  final Decimal outstandingPayable;
  final bool active;

  SupplierDetail({
    required this.id,
    required this.supplierCode,
    required this.name,
    this.tradeName,
    required this.phone,
    required this.gstin,
    this.email,
    required this.paymentTermsDays,
    required this.outstandingPayable,
    this.active = true,
  });

  factory SupplierDetail.fromJson(Map<String, dynamic> json) {
    return SupplierDetail(
      id: json['id'] as String,
      supplierCode: json['supplier_code'] as String,
      name: json['name'] as String,
      tradeName: json['trade_name'] as String?,
      phone: json['phone'] as String?,
      gstin: json['gstin'] as String?,
      email: json['email'] as String?,
      paymentTermsDays: json['payment_terms_days'] as int? ?? 0,
      outstandingPayable: Decimal.parse(json['outstanding_payable'] as String),
      active: (json['status'] as String? ?? 'ACTIVE') == 'ACTIVE',
    );
  }
}

/// One posted, immutable supplier ledger row. A credit increases what the
/// shop owes the supplier (e.g. a GRN); a debit decreases it (e.g. a
/// payment) — the mirror image of a customer ledger entry.
class SupplierLedgerEntry {
  final String id;
  final DateTime entryDate;
  final String documentType;
  final Decimal debit;
  final Decimal credit;
  final String? description;

  SupplierLedgerEntry({
    required this.id,
    required this.entryDate,
    required this.documentType,
    required this.debit,
    required this.credit,
    required this.description,
  });

  factory SupplierLedgerEntry.fromJson(Map<String, dynamic> json) {
    return SupplierLedgerEntry(
      id: json['id'] as String,
      entryDate: DateTime.parse(json['entry_date'] as String),
      documentType: json['document_type'] as String,
      debit: Decimal.parse(json['debit'] as String),
      credit: Decimal.parse(json['credit'] as String),
      description: json['description'] as String?,
    );
  }
}

class RecordPaymentResult {
  final String paymentId;
  final bool duplicate;

  RecordPaymentResult({required this.paymentId, required this.duplicate});

  factory RecordPaymentResult.fromJson(Map<String, dynamic> json) {
    return RecordPaymentResult(
      paymentId: json['payment_id'] as String,
      duplicate: json['duplicate'] as bool? ?? false,
    );
  }
}

/// Wraps the supplier master + payable ledger + manual payment endpoints.
/// See services/api/internal/httpapi/supplier_handlers.go and
/// payment_handlers.go's RecordSupplierPayment.
class SupplierApi {
  final ApiClient client;

  SupplierApi(this.client);

  Future<List<SupplierSummary>> search(String query) async {
    final path = query.isEmpty
        ? '/api/v1/suppliers'
        : '/api/v1/suppliers?q=${Uri.encodeQueryComponent(query)}';
    final response = await client.getAuthed(path);
    return (response['suppliers'] as List<dynamic>)
        .map((s) => SupplierSummary.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  Future<SupplierDetail> getDetail(String supplierId) async {
    final response = await client.getAuthed('/api/v1/suppliers/$supplierId');
    return SupplierDetail.fromJson(response);
  }

  Future<List<SupplierLedgerEntry>> getLedger(String supplierId, {int limit = 100}) async {
    final response = await client.getAuthed('/api/v1/suppliers/$supplierId/ledger?limit=$limit');
    return (response['entries'] as List<dynamic>)
        .map((e) => SupplierLedgerEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Registers a new supplier (gated server-side on supplier.manage). Like
  /// CustomerApi.create/ProductAdminApi.create, re-fetches via getDetail()
  /// because the Create response (supplierToJSON) omits outstanding_payable,
  /// which is only ever computed live from the ledger.
  Future<SupplierDetail> create({
    required String supplierCode,
    required String name,
    String? tradeName,
    String? gstin,
    String? phone,
    String? email,
    int paymentTermsDays = 0,
  }) async {
    final body = {
      'supplier_code': supplierCode,
      'name': name,
      if (tradeName != null && tradeName.isNotEmpty) 'trade_name': tradeName,
      if (gstin != null && gstin.isNotEmpty) 'gstin': gstin,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (email != null && email.isNotEmpty) 'email': email,
      'payment_terms_days': paymentTermsDays,
    };
    final response = await client.postAuthed('/api/v1/suppliers', body);
    return getDetail(response['id'] as String);
  }

  /// Revises a supplier's editable fields. supplier_code is immutable and
  /// never sent — see supplier.Update's doc comment server-side.
  Future<SupplierDetail> update({
    required String supplierId,
    required String name,
    String? tradeName,
    String? gstin,
    String? phone,
    String? email,
    int paymentTermsDays = 0,
  }) async {
    final body = {
      'name': name,
      if (tradeName != null && tradeName.isNotEmpty) 'trade_name': tradeName,
      if (gstin != null && gstin.isNotEmpty) 'gstin': gstin,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (email != null && email.isNotEmpty) 'email': email,
      'payment_terms_days': paymentTermsDays,
    };
    await client.putAuthed('/api/v1/suppliers/$supplierId', body);
    return getDetail(supplierId);
  }

  /// Activates or deactivates a supplier — never a hard delete, since
  /// historical GRN/payment rows reference it.
  Future<SupplierDetail> setActive(String supplierId, bool active) async {
    await client.postAuthed('/api/v1/suppliers/$supplierId/status', {'active': active});
    return getDetail(supplierId);
  }

  Future<RecordPaymentResult> recordPayment({
    required String supplierId,
    required Decimal amount,
    required String method,
    String? reference,
  }) async {
    final body = {
      'supplier_id': supplierId,
      'amount': amount.toString(),
      'method': method,
      if (reference != null && reference.isNotEmpty) 'reference': reference,
      'idempotency_key': const Uuid().v4(),
    };
    final response = await client.postAuthed('/api/v1/payments/supplier-payments', body);
    return RecordPaymentResult.fromJson(response);
  }
}
