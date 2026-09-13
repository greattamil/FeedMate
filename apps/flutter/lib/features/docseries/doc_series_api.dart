import '../../core/api_client.dart';

class FinancialYear {
  final String id;
  final String label;
  final DateTime startDate;
  final DateTime endDate;
  final String status; // OPEN or CLOSED
  final DateTime? closedAt;

  FinancialYear({
    required this.id,
    required this.label,
    required this.startDate,
    required this.endDate,
    required this.status,
    required this.closedAt,
  });

  factory FinancialYear.fromJson(Map<String, dynamic> json) {
    return FinancialYear(
      id: json['id'] as String,
      label: json['label'] as String,
      startDate: DateTime.parse(json['start_date'] as String),
      endDate: DateTime.parse(json['end_date'] as String),
      status: json['status'] as String,
      closedAt: json['closed_at'] == null ? null : DateTime.parse(json['closed_at'] as String),
    );
  }
}

class DocumentSeries {
  final String id;
  final String financialYearId;
  final String documentType;
  final String prefix;
  final int nextNumber;
  final int padding;
  final bool active;

  DocumentSeries({
    required this.id,
    required this.financialYearId,
    required this.documentType,
    required this.prefix,
    required this.nextNumber,
    required this.padding,
    required this.active,
  });

  factory DocumentSeries.fromJson(Map<String, dynamic> json) {
    return DocumentSeries(
      id: json['id'] as String,
      financialYearId: json['financial_year_id'] as String,
      documentType: json['document_type'] as String,
      prefix: json['prefix'] as String,
      nextNumber: json['next_number'] as int,
      padding: json['padding'] as int,
      active: json['active'] as bool,
    );
  }
}

/// Wraps the financial-year / document-series admin endpoints. See
/// services/api/internal/httpapi/docseries_handlers.go — this exists so a
/// missing series row never again surfaces only as an opaque
/// INTERNAL_ERROR at the moment a cashier tries to finalize a sale.
class DocSeriesApi {
  final ApiClient client;

  DocSeriesApi(this.client);

  Future<List<FinancialYear>> listFinancialYears() async {
    final response = await client.getAuthed('/api/v1/financial-years');
    return (response['financial_years'] as List<dynamic>)
        .map((f) => FinancialYear.fromJson(f as Map<String, dynamic>))
        .toList();
  }

  Future<String> createFinancialYear({
    required String label,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    String fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final response = await client.postAuthed('/api/v1/financial-years', {
      'label': label,
      'start_date': fmt(startDate),
      'end_date': fmt(endDate),
    });
    return response['id'] as String;
  }

  Future<void> closeFinancialYear(String id) async {
    await client.postAuthed('/api/v1/financial-years/$id/close', {});
  }

  Future<List<DocumentSeries>> listDocumentSeries(String financialYearId) async {
    final response = await client.getAuthed('/api/v1/financial-years/$financialYearId/document-series');
    return (response['document_series'] as List<dynamic>)
        .map((d) => DocumentSeries.fromJson(d as Map<String, dynamic>))
        .toList();
  }

  Future<String> createDocumentSeries({
    required String financialYearId,
    required String documentType,
    required String prefix,
    required int startingNumber,
    required int padding,
  }) async {
    final response = await client.postAuthed('/api/v1/financial-years/$financialYearId/document-series', {
      'document_type': documentType,
      'prefix': prefix,
      'starting_number': startingNumber,
      'padding': padding,
    });
    return response['id'] as String;
  }

  Future<void> setDocumentSeriesActive(String id, bool active) async {
    await client.postAuthed('/api/v1/document-series/$id/status', {'active': active});
  }

  /// One-click fix: creates an active series for every core document type
  /// (INVOICE/GRN/RETURN/CONTRA/RECEIPT) that doesn't already have one in
  /// this financial year.
  Future<List<DocumentSeries>> seedDefaultSeries(String financialYearId, {required String labelPrefix}) async {
    final response = await client.postAuthed('/api/v1/financial-years/$financialYearId/document-series/seed-defaults', {
      'label_prefix': labelPrefix,
    });
    return (response['created'] as List<dynamic>).map((d) => DocumentSeries.fromJson(d as Map<String, dynamic>)).toList();
  }
}
