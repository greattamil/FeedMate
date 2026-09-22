import 'package:decimal/decimal.dart';

import '../../core/api_client.dart';

class CustomerSummary {
  final String id;
  final String customerCode;
  final String name;
  final String? phone;
  final String customerType;
  final Decimal balance;

  CustomerSummary({
    required this.id,
    required this.customerCode,
    required this.name,
    required this.phone,
    required this.customerType,
    required this.balance,
  });

  factory CustomerSummary.fromJson(Map<String, dynamic> json) {
    return CustomerSummary(
      id: json['id'] as String,
      customerCode: json['customer_code'] as String,
      name: json['name'] as String,
      phone: json['phone'] as String?,
      customerType: json['customer_type'] as String,
      balance: json['balance'] != null ? Decimal.parse(json['balance'] as String) : Decimal.zero,
    );
  }
}

/// The full customer master-record + live credit position. Mirrors
/// services/api/internal/httpapi/customer_handlers.go's Get response —
/// outstanding_balance/available_credit are always computed server-side
/// from the ledger, never cached client-side as a stored field.
class CustomerDetail {
  final String id;
  final String customerCode;
  final String name;
  final String? localName;
  final String? phone;
  final String? whatsAppPhone;
  final String? email;
  final String? gstin;
  final String customerType;
  final bool active;
  final Decimal creditLimit;
  final Decimal outstandingBalance;
  final Decimal availableCredit;
  final String riskStatus;

  CustomerDetail({
    required this.id,
    required this.customerCode,
    required this.name,
    required this.localName,
    required this.phone,
    required this.whatsAppPhone,
    required this.email,
    required this.gstin,
    required this.customerType,
    required this.active,
    required this.creditLimit,
    required this.outstandingBalance,
    required this.availableCredit,
    required this.riskStatus,
  });

  factory CustomerDetail.fromJson(Map<String, dynamic> json) {
    return CustomerDetail(
      id: json['id'] as String,
      customerCode: json['customer_code'] as String,
      name: json['name'] as String,
      localName: json['local_name'] as String?,
      phone: json['phone'] as String?,
      whatsAppPhone: json['whatsapp_phone'] as String?,
      email: json['email'] as String?,
      gstin: json['gstin'] as String?,
      customerType: json['customer_type'] as String,
      active: (json['status'] as String? ?? 'ACTIVE') == 'ACTIVE',
      creditLimit: Decimal.parse(json['credit_limit'] as String),
      outstandingBalance: Decimal.parse(json['outstanding_balance'] as String),
      availableCredit: Decimal.parse(json['available_credit'] as String),
      riskStatus: json['risk_status'] as String,
    );
  }
}

/// One posted, immutable customer ledger row. A debit increases what the
/// customer owes (e.g. a credit sale); a credit decreases it (e.g. a
/// receipt) — see customer.PostLedgerEntry server-side.
class LedgerEntry {
  final String id;
  final DateTime entryDate;
  final String documentType;
  final String documentId;
  final Decimal debit;
  final Decimal credit;
  final String? description;

  LedgerEntry({
    required this.id,
    required this.entryDate,
    required this.documentType,
    required this.documentId,
    required this.debit,
    required this.credit,
    required this.description,
  });

  factory LedgerEntry.fromJson(Map<String, dynamic> json) {
    return LedgerEntry(
      id: json['id'] as String,
      entryDate: DateTime.parse(json['entry_date'] as String),
      documentType: json['document_type'] as String,
      documentId: json['document_id'] as String? ?? '',
      debit: Decimal.parse(json['debit'] as String),
      credit: Decimal.parse(json['credit'] as String),
      description: json['description'] as String?,
    );
  }
}

/// Wraps the customer master-data + ledger endpoints.
/// See services/api/internal/httpapi/customer_handlers.go.
class CustomerApi {
  final ApiClient client;

  CustomerApi(this.client);

  Future<List<CustomerSummary>> search(String query) async {
    final path = query.isEmpty
        ? '/api/v1/customers'
        : '/api/v1/customers?q=${Uri.encodeQueryComponent(query)}';
    final response = await client.getAuthed(path);
    return (response['customers'] as List<dynamic>)
        .map((c) => CustomerSummary.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<CustomerDetail> getDetail(String customerId) async {
    final response = await client.getAuthed('/api/v1/customers/$customerId');
    return CustomerDetail.fromJson(response);
  }

  Future<List<LedgerEntry>> getLedger(String customerId, {int limit = 100}) async {
    final response = await client.getAuthed('/api/v1/customers/$customerId/ledger?limit=$limit');
    return (response['entries'] as List<dynamic>)
        .map((e) => LedgerEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Registers a new customer (gated server-side on credit.configure — same
  /// permission required to later change their credit limit, since setting
  /// the initial limit is the same trust decision). [customerType] must be
  /// one of FARMER, WHOLESALE_DEALER, AAVIN_SUBCONTRACTOR, or OTHER — the
  /// exact set the customers_customer_type_check DB constraint allows (see
  /// customer.validCustomerTypes server-side); anything else is rejected
  /// with a clear validation error rather than an opaque 500.
  Future<CustomerDetail> create({
    required String name,
    String? localName,
    String? phone,
    String? whatsAppPhone,
    String? email,
    String? gstin,
    String customerType = 'OTHER',
    Decimal? creditLimit,
  }) async {
    final body = {
      'name': name,
      if (localName != null && localName.isNotEmpty) 'local_name': localName,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (whatsAppPhone != null && whatsAppPhone.isNotEmpty) 'whatsapp_phone': whatsAppPhone,
      if (email != null && email.isNotEmpty) 'email': email,
      if (gstin != null && gstin.isNotEmpty) 'gstin': gstin,
      'customer_type': customerType,
      if (creditLimit != null) 'credit_limit': creditLimit.toStringAsFixed(2),
    };
    final response = await client.postAuthed('/api/v1/customers', body);
    return getDetail(response['id'] as String);
  }

  /// Revises a customer's editable fields. customer_code is immutable and
  /// never sent — see customer.Update's doc comment server-side.
  Future<CustomerDetail> update({
    required String customerId,
    required String name,
    String? localName,
    String? phone,
    String? whatsAppPhone,
    String? email,
    String? gstin,
    required String customerType,
  }) async {
    final body = {
      'name': name,
      if (localName != null && localName.isNotEmpty) 'local_name': localName,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (whatsAppPhone != null && whatsAppPhone.isNotEmpty) 'whatsapp_phone': whatsAppPhone,
      if (email != null && email.isNotEmpty) 'email': email,
      if (gstin != null && gstin.isNotEmpty) 'gstin': gstin,
      'customer_type': customerType,
    };
    await client.putAuthed('/api/v1/customers/$customerId', body);
    return getDetail(customerId);
  }

  /// Activates or deactivates a customer — never a hard delete, since
  /// historical invoice/ledger rows reference it.
  Future<CustomerDetail> setActive(String customerId, bool active) async {
    await client.postAuthed('/api/v1/customers/$customerId/status', {'active': active});
    return getDetail(customerId);
  }

  Future<void> setCreditLimit(String customerId, Decimal creditLimit) async {
    await client.putAuthed('/api/v1/customers/$customerId/credit-limit', {
      'credit_limit': creditLimit.toStringAsFixed(2),
    });
  }
}
