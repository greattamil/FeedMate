import 'package:decimal/decimal.dart';

import '../../core/api_client.dart';
import '../pos/product.dart';

/// One line of a contra (buy-back) transaction being built client-side.
/// Mirrors GRNLineDraft's shape — a contra is, from an inventory point of
/// view, a receipt of stock — but valued and posted against a customer's
/// receivable instead of a supplier's payable. See PRD 8 / contra.Service.
class ContraLineDraft {
  final Product product;
  String batchCode;
  DateTime? manufactureDate;
  DateTime? expiryDate;
  Decimal quantity;
  Decimal valuationUnitPrice;
  String qualityStatus;

  ContraLineDraft({
    required this.product,
    this.batchCode = '',
    this.manufactureDate,
    this.expiryDate,
    required this.quantity,
    required this.valuationUnitPrice,
    this.qualityStatus = 'ACCEPTED',
  });

  Map<String, dynamic> toJson({required String locationId}) {
    String? dateStr(DateTime? d) => d == null
        ? null
        : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return {
      'product_id': product.id,
      'batch_code': batchCode,
      if (dateStr(manufactureDate) != null) 'manufacture_date': dateStr(manufactureDate),
      if (dateStr(expiryDate) != null) 'expiry_date': dateStr(expiryDate),
      'quantity': quantity.toString(),
      'uom_id': product.defaultPurchaseUomId,
      'valuation_unit_price': valuationUnitPrice.toStringAsFixed(2),
      'quality_status': qualityStatus,
      'location_id': locationId,
    };
  }
}

class PostContraResult {
  final String contraId;
  final String contraNumber;
  final Decimal totalValue;

  PostContraResult({required this.contraId, required this.contraNumber, required this.totalValue});

  factory PostContraResult.fromJson(Map<String, dynamic> json) {
    return PostContraResult(
      contraId: json['contra_id'] as String,
      contraNumber: json['contra_number'] as String,
      totalValue: Decimal.parse(json['total_value'] as String),
    );
  }
}

/// Wraps POST /api/v1/contra. All business logic (rejecting REJECTED-quality
/// lines from sellable stock, receivable reduction, accounting journal)
/// lives server-side — see services/api/internal/domain/contra/service.go.
class ContraApi {
  final ApiClient client;

  ContraApi(this.client);

  Future<PostContraResult> postContra({
    required String customerId,
    required String locationId,
    String? sourceReference,
    required List<ContraLineDraft> lines,
  }) async {
    final body = {
      'customer_id': customerId,
      if (sourceReference != null && sourceReference.isNotEmpty) 'source_reference': sourceReference,
      'lines': lines.map((l) => l.toJson(locationId: locationId)).toList(),
    };
    final response = await client.postAuthed('/api/v1/contra', body);
    return PostContraResult.fromJson(response);
  }
}
