import 'package:decimal/decimal.dart';

import '../../core/api_client.dart';

class CustomerSummary {
  final String id;
  final String customerCode;
  final String name;
  final String? phone;
  final String customerType;

  CustomerSummary({
    required this.id,
    required this.customerCode,
    required this.name,
    required this.phone,
    required this.customerType,
  });

  factory CustomerSummary.fromJson(Map<String, dynamic> json) {
    return CustomerSummary(
      id: json['id'] as String,
      customerCode: json['customer_code'] as String,
      name: json['name'] as String,
      phone: json['phone'] as String?,
      customerType: json['customer_type'] as String,
    );
  }
}

/// The full Khata statement header: customer identity plus their live credit
/// position. Mirrors services/api/internal/httpapi/customer_handlers.go's
/// Get response — outstanding_balance/available_credit are always computed
/// server-side from the ledger, never cached client-side as a stored field.
class CustomerDetail {
  final String id;
  final String customerCode;
  final String name;
  final String? phone;
  final String customerType;
  final Decimal creditLimit;
  final Decimal outstandingBalance;
  final Decimal availableCredit;
  final String riskStatus;

  CustomerDetail({
    required this.id,
    required this.customerCode,
    required this.name,
    required this.phone,
    required this.customerType,
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
      phone: json['phone'] as String?,
      customerType: json['customer_type'] as String,
      creditLimit: Decimal.parse(json['credit_limit'] as String),
      outstandingBalance: Decimal.parse(json['outstanding_balance'] as String),
      availableCredit: Decimal.parse(json['available_credit'] as String),
      riskStatus: json['risk_status'] as String,
    );
  }
}

/// One posted, immutable Khata ledger row. A debit increases what the
/// customer owes (e.g. a credit sale); a credit decreases it (e.g. a
/// receipt) — see customer.PostLedgerEntry server-side.
class LedgerEntry {
  final String id;
  final DateTime entryDate;
  final String documentType;
  final Decimal debit;
  final Decimal credit;
  final String? description;

  LedgerEntry({
    required this.id,
    required this.entryDate,
    required this.documentType,
    required this.debit,
    required this.credit,
    required this.description,
  });

  factory LedgerEntry.fromJson(Map<String, dynamic> json) {
    return LedgerEntry(
      id: json['id'] as String,
      entryDate: DateTime.parse(json['entry_date'] as String),
      documentType: json['document_type'] as String,
      debit: Decimal.parse(json['debit'] as String),
      credit: Decimal.parse(json['credit'] as String),
      description: json['description'] as String?,
    );
  }
}

/// Wraps the customer master + Khata ledger endpoints.
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
}
