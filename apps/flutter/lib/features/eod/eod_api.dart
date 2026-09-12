import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';

class EodSession {
  final String sessionId;
  final DateTime businessDate;
  final Decimal openingCash;
  final Decimal cashSales;
  final Decimal cashRefunds;
  final Decimal expectedCash;
  final Decimal? actualCash;
  final Decimal? variance;
  final String status; // OPEN, CLOSED, REOPENED

  EodSession({
    required this.sessionId,
    required this.businessDate,
    required this.openingCash,
    required this.cashSales,
    required this.cashRefunds,
    required this.expectedCash,
    required this.actualCash,
    required this.variance,
    required this.status,
  });

  factory EodSession.fromJson(Map<String, dynamic> json) {
    return EodSession(
      sessionId: json['session_id'] as String,
      businessDate: DateTime.parse(json['business_date'] as String),
      openingCash: Decimal.parse(json['opening_cash'] as String),
      cashSales: Decimal.parse(json['cash_sales'] as String),
      cashRefunds: Decimal.parse(json['cash_refunds'] as String),
      expectedCash: Decimal.parse(json['expected_cash'] as String),
      actualCash: json['actual_cash'] != null ? Decimal.parse(json['actual_cash'] as String) : null,
      variance: json['variance'] != null ? Decimal.parse(json['variance'] as String) : null,
      status: json['status'] as String,
    );
  }
}

class CloseSessionResult {
  final String sessionId;
  final Decimal expectedCash;
  final Decimal actualCash;
  final Decimal variance;

  CloseSessionResult({
    required this.sessionId,
    required this.expectedCash,
    required this.actualCash,
    required this.variance,
  });

  factory CloseSessionResult.fromJson(Map<String, dynamic> json) {
    return CloseSessionResult(
      sessionId: json['session_id'] as String,
      expectedCash: Decimal.parse(json['expected_cash'] as String),
      actualCash: Decimal.parse(json['actual_cash'] as String),
      variance: Decimal.parse(json['variance'] as String),
    );
  }
}

String formatBusinessDate(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

/// Wraps the end-of-day cash reconciliation endpoints. See
/// services/api/internal/httpapi/eod_handlers.go — the server is the sole
/// authority on expected cash (derived from the accounting journal's CASH
/// account, never a client-side running total) and on whether a variance
/// reason is required (PRD 12.2).
class EodApi {
  final ApiClient client;

  EodApi(this.client);

  /// Throws ApiError with code NOT_FOUND if no session exists yet for this
  /// business date — the screen treats that as "not opened today", not an
  /// error state.
  Future<EodSession> getSession({DateTime? businessDate}) async {
    final path = businessDate != null
        ? '/api/v1/eod?business_date=${formatBusinessDate(businessDate)}'
        : '/api/v1/eod';
    final response = await client.getAuthed(path);
    return EodSession.fromJson(response);
  }

  Future<String> openSession({required Decimal openingCash, DateTime? businessDate}) async {
    final body = {
      'opening_cash': openingCash.toString(),
      if (businessDate != null) 'business_date': formatBusinessDate(businessDate),
    };
    final response = await client.postAuthed('/api/v1/eod/open', body);
    return response['session_id'] as String;
  }

  Future<CloseSessionResult> closeSession({
    required Decimal actualCash,
    String? varianceReason,
    DateTime? businessDate,
  }) async {
    final body = {
      'actual_cash': actualCash.toString(),
      if (varianceReason != null && varianceReason.isNotEmpty) 'variance_reason': varianceReason,
      if (businessDate != null) 'business_date': formatBusinessDate(businessDate),
    };
    final response = await client.postAuthed('/api/v1/eod/close', body);
    return CloseSessionResult.fromJson(response);
  }

  Future<void> reopenSession({required String reason, DateTime? businessDate}) async {
    final body = {
      'reason': reason,
      if (businessDate != null) 'business_date': formatBusinessDate(businessDate),
    };
    await client.postAuthed('/api/v1/eod/reopen', body);
  }
}
