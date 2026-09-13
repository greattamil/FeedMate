import 'package:decimal/decimal.dart';

import '../../core/api_client.dart';

class StockCountSummary {
  final String id;
  final String locationName;
  final String countMode; // FULL or CYCLE
  final String status; // IN_PROGRESS, PENDING_APPROVAL, POSTED, CANCELLED
  final DateTime startedAt;
  final DateTime? completedAt;

  StockCountSummary({
    required this.id,
    required this.locationName,
    required this.countMode,
    required this.status,
    required this.startedAt,
    required this.completedAt,
  });

  factory StockCountSummary.fromJson(Map<String, dynamic> json) {
    return StockCountSummary(
      id: json['id'] as String,
      locationName: json['location_name'] as String,
      countMode: json['count_mode'] as String,
      status: json['status'] as String,
      startedAt: DateTime.parse(json['started_at'] as String),
      completedAt: json['completed_at'] == null ? null : DateTime.parse(json['completed_at'] as String),
    );
  }
}

class CountLine {
  final String id;
  final String productId;
  final String productName;
  final String sku;
  final String batchId;
  final String batchCode;
  final Decimal expectedQty;
  final Decimal countedQty;
  final Decimal varianceQty;
  final String? reason;

  CountLine({
    required this.id,
    required this.productId,
    required this.productName,
    required this.sku,
    required this.batchId,
    required this.batchCode,
    required this.expectedQty,
    required this.countedQty,
    required this.varianceQty,
    required this.reason,
  });

  factory CountLine.fromJson(Map<String, dynamic> json) {
    return CountLine(
      id: json['id'] as String,
      productId: json['product_id'] as String,
      productName: json['product_name'] as String,
      sku: json['sku'] as String,
      batchId: json['batch_id'] as String,
      batchCode: json['batch_code'] as String,
      expectedQty: Decimal.parse(json['expected_qty'] as String),
      countedQty: Decimal.parse(json['counted_qty'] as String),
      varianceQty: Decimal.parse(json['variance_qty'] as String),
      reason: json['reason'] as String?,
    );
  }
}

class StockCountDetail {
  final String id;
  final String locationId;
  final String countMode;
  final String status;
  final DateTime startedAt;
  final DateTime? completedAt;
  final List<CountLine> lines;

  StockCountDetail({
    required this.id,
    required this.locationId,
    required this.countMode,
    required this.status,
    required this.startedAt,
    required this.completedAt,
    required this.lines,
  });

  factory StockCountDetail.fromJson(Map<String, dynamic> json) {
    return StockCountDetail(
      id: json['id'] as String,
      locationId: json['location_id'] as String,
      countMode: json['count_mode'] as String,
      status: json['status'] as String,
      startedAt: DateTime.parse(json['started_at'] as String),
      completedAt: json['completed_at'] == null ? null : DateTime.parse(json['completed_at'] as String),
      lines: (json['lines'] as List<dynamic>).map((l) => CountLine.fromJson(l as Map<String, dynamic>)).toList(),
    );
  }
}

class BatchOption {
  final String id;
  final String batchCode;
  final Decimal availableQty;

  BatchOption({required this.id, required this.batchCode, required this.availableQty});

  factory BatchOption.fromJson(Map<String, dynamic> json) {
    return BatchOption(
      id: json['id'] as String,
      batchCode: json['batch_code'] as String,
      availableQty: Decimal.parse(json['available_qty'] as String),
    );
  }
}

class PostCountResult {
  final int linesAdjusted;
  final Decimal netValueDelta;

  PostCountResult({required this.linesAdjusted, required this.netValueDelta});

  factory PostCountResult.fromJson(Map<String, dynamic> json) {
    return PostCountResult(
      linesAdjusted: json['lines_adjusted'] as int,
      netValueDelta: Decimal.parse(json['net_value_delta'] as String),
    );
  }
}

/// Wraps the physical stock-count endpoints. See
/// services/api/internal/httpapi/stockcount_handlers.go. All inventory math
/// (expected quantity, variance, the actual ADJUSTMENT posting) is
/// authoritative server-side — this only collects what a human physically
/// counted.
class StockCountApi {
  final ApiClient client;

  StockCountApi(this.client);

  Future<String> startCount({required String locationId, required String countMode}) async {
    final response = await client.postAuthed('/api/v1/stock-counts', {
      'location_id': locationId,
      'count_mode': countMode,
    });
    return response['id'] as String;
  }

  Future<void> recordCount({
    required String stockCountId,
    required String productId,
    required String batchId,
    required Decimal countedQty,
    String? reason,
  }) async {
    await client.postAuthed('/api/v1/stock-counts/$stockCountId/lines', {
      'product_id': productId,
      'batch_id': batchId,
      'counted_qty': countedQty.toString(),
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
  }

  Future<List<BatchOption>> listBatchesForProduct(String stockCountId, String productId) async {
    final response = await client.getAuthed('/api/v1/stock-counts/$stockCountId/batches?product_id=$productId');
    return (response['batches'] as List<dynamic>).map((b) => BatchOption.fromJson(b as Map<String, dynamic>)).toList();
  }

  Future<PostCountResult> postCount(String stockCountId) async {
    final response = await client.postAuthed('/api/v1/stock-counts/$stockCountId/post', {});
    return PostCountResult.fromJson(response);
  }

  Future<void> cancelCount(String stockCountId) async {
    await client.postAuthed('/api/v1/stock-counts/$stockCountId/cancel', {});
  }

  Future<List<StockCountSummary>> list({int limit = 50, int offset = 0}) async {
    final response = await client.getAuthed('/api/v1/stock-counts?limit=$limit&offset=$offset');
    return (response['stock_counts'] as List<dynamic>)
        .map((c) => StockCountSummary.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<StockCountDetail> getDetail(String stockCountId) async {
    final response = await client.getAuthed('/api/v1/stock-counts/$stockCountId');
    return StockCountDetail.fromJson(response);
  }
}
