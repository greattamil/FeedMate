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

/// Wraps the customer master endpoints for the POS cart's customer picker.
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
}
