/// Mirrors the Go backend's standardized error envelope (services/api
/// internal/httpapi/errors.go) so the app can branch on the machine-readable
/// `code`, never on the human-readable message string.
class ApiError implements Exception {
  final String code;
  final String message;
  final String? requestId;
  final bool retryable;
  final int statusCode;

  ApiError({
    required this.code,
    required this.message,
    required this.statusCode,
    this.requestId,
    this.retryable = false,
  });

  factory ApiError.fromJson(Map<String, dynamic> json, int statusCode) {
    final error = json['error'] as Map<String, dynamic>? ?? {};
    return ApiError(
      code: error['code'] as String? ?? 'UNKNOWN_ERROR',
      message: error['message'] as String? ?? 'An error occurred',
      requestId: error['request_id'] as String?,
      retryable: error['retryable'] as bool? ?? false,
      statusCode: statusCode,
    );
  }

  factory ApiError.network(String detail) => ApiError(
        code: 'NETWORK_ERROR',
        message: detail,
        statusCode: 0,
        retryable: true,
      );

  @override
  String toString() => 'ApiError($code): $message';
}
