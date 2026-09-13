import 'package:decimal/decimal.dart';

import '../../core/api_client.dart';
import '../pos/product.dart';

/// One line of a GRN being built client-side, before posting. UOM and tax
/// profile are always taken from the product's own defaults (set once when
/// the product was created) rather than picked ad hoc at receiving time —
/// mirrors how the shop actually treats these as fixed product properties.
class GRNLineDraft {
  final Product product;
  String batchCode;
  DateTime? manufactureDate;
  DateTime? expiryDate;
  Decimal receivedQty;
  Decimal unitCost;
  String qualityStatus;

  // Weight/tare capture (PRD A7) is optional per line: a product received
  // purely by count may skip it entirely.
  bool captureWeight;
  Decimal? grossWeightKg;
  String tareMethod; // MEASURED or STANDARD_PER_BAG
  Decimal? measuredTareKg;
  int? bagCount;
  Decimal? standardTarePerBagKg;

  GRNLineDraft({
    required this.product,
    this.batchCode = '',
    this.manufactureDate,
    this.expiryDate,
    required this.receivedQty,
    required this.unitCost,
    this.qualityStatus = 'ACCEPTED',
    this.captureWeight = false,
    this.grossWeightKg,
    this.tareMethod = 'MEASURED',
    this.measuredTareKg,
    this.bagCount,
    this.standardTarePerBagKg,
  });

  Map<String, dynamic> toJson() {
    String? dateStr(DateTime? d) => d == null
        ? null
        : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return {
      'product_id': product.id,
      'batch_code': batchCode,
      if (dateStr(manufactureDate) != null) 'manufacture_date': dateStr(manufactureDate),
      if (dateStr(expiryDate) != null) 'expiry_date': dateStr(expiryDate),
      'received_qty': receivedQty.toString(),
      'uom_id': product.defaultPurchaseUomId,
      'unit_cost': unitCost.toString(),
      if (product.taxProfileId != null) 'tax_profile_id': product.taxProfileId!,
      'quality_status': qualityStatus,
      if (captureWeight && grossWeightKg != null) ...{
        'gross_weight_kg': grossWeightKg.toString(),
        'tare_method': tareMethod,
        if (tareMethod == 'MEASURED' && measuredTareKg != null) 'measured_tare_kg': measuredTareKg.toString(),
        if (tareMethod == 'STANDARD_PER_BAG') ...{
          if (bagCount != null) 'bag_count': bagCount,
          if (standardTarePerBagKg != null) 'standard_tare_per_bag_kg': standardTarePerBagKg.toString(),
        },
      },
    };
  }
}

class PostGRNResult {
  final String grnId;
  final String grnNumber;

  PostGRNResult({required this.grnId, required this.grnNumber});

  factory PostGRNResult.fromJson(Map<String, dynamic> json) {
    return PostGRNResult(grnId: json['grn_id'] as String, grnNumber: json['grn_number'] as String);
  }
}

/// Wraps POST /api/v1/procurement/grns. All business logic (weight/tare
/// validation, batch creation, payable posting, accounting journal) lives
/// server-side — see services/api/internal/domain/procurement/service.go.
class ProcurementApi {
  final ApiClient client;

  ProcurementApi(this.client);

  Future<PostGRNResult> postGRN({
    required String supplierId,
    required String locationId,
    String? supplierDocumentNo,
    String? vehicleNo,
    required List<GRNLineDraft> lines,
    bool overrideTare = false,
    String? overrideTareReason,
  }) async {
    final body = {
      'supplier_id': supplierId,
      if (supplierDocumentNo != null && supplierDocumentNo.isNotEmpty) 'supplier_document_no': supplierDocumentNo,
      if (vehicleNo != null && vehicleNo.isNotEmpty) 'vehicle_no': vehicleNo,
      'lines': lines.map((l) {
        final line = l.toJson();
        line['location_id'] = locationId;
        return line;
      }).toList(),
      if (overrideTare) 'override_tare': true,
      if (overrideTareReason != null) 'override_tare_reason': overrideTareReason,
    };
    final response = await client.postAuthed('/api/v1/procurement/grns', body);
    return PostGRNResult.fromJson(response);
  }
}
