import 'package:decimal/decimal.dart';
import 'package:uuid/uuid.dart';

import '../../core/api_client.dart';

class RecordReceiptResult {
  final String paymentId;
  final bool duplicate;

  RecordReceiptResult({required this.paymentId, required this.duplicate});

  factory RecordReceiptResult.fromJson(Map<String, dynamic> json) {
    return RecordReceiptResult(
      paymentId: json['payment_id'] as String,
      duplicate: json['duplicate'] as bool? ?? false,
    );
  }
}

/// Records a receipt collected in person against a customer's Khata — see
/// services/api/internal/httpapi/payment_handlers.go's RecordManualReceipt.
/// UPI collection goes through a different, provider-verified path
/// (pos_api.dart's quote/finalize flow uses payment intents, not this).
class ReceiptApi {
  final ApiClient client;

  ReceiptApi(this.client);

  Future<RecordReceiptResult> recordReceipt({
    required String customerId,
    required Decimal amount,
    required String method,
    String? reference,
  }) async {
    final body = {
      'customer_id': customerId,
      'amount': amount.toString(),
      'method': method,
      if (reference != null && reference.isNotEmpty) 'reference': reference,
      // A fresh idempotency key per submission — the retry-safety this key
      // provides matters for a single logical tap (e.g. the response is
      // lost to a network blip and the client layer retries the exact same
      // request), not for the user tapping "Record" twice on purpose.
      'idempotency_key': const Uuid().v4(),
    };
    final response = await client.postAuthed('/api/v1/payments/receipts', body);
    return RecordReceiptResult.fromJson(response);
  }
}
