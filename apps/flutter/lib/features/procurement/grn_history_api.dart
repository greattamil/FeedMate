import 'package:decimal/decimal.dart';

import '../../core/api_client.dart';

class GRNSummary {
  final String id;
  final String grnNumber;
  final String supplierName;
  final String? supplierDocumentNo;
  final DateTime? postedAt;

  GRNSummary({
    required this.id,
    required this.grnNumber,
    required this.supplierName,
    required this.supplierDocumentNo,
    required this.postedAt,
  });

  factory GRNSummary.fromJson(Map<String, dynamic> json) {
    return GRNSummary(
      id: json['id'] as String,
      grnNumber: json['grn_number'] as String,
      supplierName: json['supplier_name'] as String,
      supplierDocumentNo: json['supplier_document_no'] as String?,
      postedAt: json['posted_at'] == null ? null : DateTime.parse(json['posted_at'] as String),
    );
  }
}

class GRNLineDetail {
  final String productName;
  final String sku;
  final String batchCode;
  final Decimal receivedQty;
  final String uomCode;
  final Decimal unitCost;
  final String qualityStatus;

  GRNLineDetail({
    required this.productName,
    required this.sku,
    required this.batchCode,
    required this.receivedQty,
    required this.uomCode,
    required this.unitCost,
    required this.qualityStatus,
  });

  factory GRNLineDetail.fromJson(Map<String, dynamic> json) {
    return GRNLineDetail(
      productName: json['product_name'] as String,
      sku: json['sku'] as String,
      batchCode: json['batch_code'] as String,
      receivedQty: Decimal.parse(json['received_qty'] as String),
      uomCode: json['uom_code'] as String,
      unitCost: Decimal.parse(json['unit_cost'] as String),
      qualityStatus: json['quality_status'] as String,
    );
  }
}

/// Mirrors services/api/internal/httpapi/procurement_handlers.go's
/// GetGRNDetail response — the full history view of one posted GRN.
class GRNDetail {
  final String id;
  final String grnNumber;
  final String supplierName;
  final String? supplierDocumentNo;
  final String? vehicleNo;
  final Decimal? netWeightKg;
  final DateTime? postedAt;
  final List<GRNLineDetail> lines;

  GRNDetail({
    required this.id,
    required this.grnNumber,
    required this.supplierName,
    required this.supplierDocumentNo,
    required this.vehicleNo,
    required this.netWeightKg,
    required this.postedAt,
    required this.lines,
  });

  factory GRNDetail.fromJson(Map<String, dynamic> json) {
    return GRNDetail(
      id: json['id'] as String,
      grnNumber: json['grn_number'] as String,
      supplierName: json['supplier_name'] as String,
      supplierDocumentNo: json['supplier_document_no'] as String?,
      vehicleNo: json['vehicle_no'] as String?,
      netWeightKg: json['net_weight_kg'] == null ? null : Decimal.parse(json['net_weight_kg'] as String),
      postedAt: json['posted_at'] == null ? null : DateTime.parse(json['posted_at'] as String),
      lines: (json['lines'] as List<dynamic>).map((l) => GRNLineDetail.fromJson(l as Map<String, dynamic>)).toList(),
    );
  }
}

/// Wraps GET /api/v1/procurement/grns and GET /api/v1/procurement/grns/{id}
/// — the GRN history screen's read endpoints.
class GRNHistoryApi {
  final ApiClient client;

  GRNHistoryApi(this.client);

  Future<List<GRNSummary>> list({String query = '', int limit = 50, int offset = 0}) async {
    final params = {
      if (query.isNotEmpty) 'q': query,
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    final qs = params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
    final response = await client.getAuthed('/api/v1/procurement/grns?$qs');
    return (response['grns'] as List<dynamic>).map((g) => GRNSummary.fromJson(g as Map<String, dynamic>)).toList();
  }

  Future<GRNDetail> getDetail(String grnId) async {
    final response = await client.getAuthed('/api/v1/procurement/grns/$grnId');
    return GRNDetail.fromJson(response);
  }
}
