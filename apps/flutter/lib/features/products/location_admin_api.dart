import '../../core/api_client.dart';

const locationTypes = ['SHOP', 'GODOWN', 'TRANSIT', 'QUARANTINE', 'RETURN'];

String locationTypeLabel(String value) {
  switch (value) {
    case 'SHOP':
      return 'Shop Counter';
    case 'GODOWN':
      return 'Godown / Warehouse';
    case 'TRANSIT':
      return 'Transit';
    case 'QUARANTINE':
      return 'Quarantine';
    case 'RETURN':
      return 'Returns Area';
    default:
      return value;
  }
}

/// A full inventory location record for the dedicated management screen.
/// Mirrors services/api/internal/httpapi/location_handlers.go's
/// locationJSON.
class LocationDetail {
  final String id;
  final String code;
  final String name;
  final String type;
  final bool active;

  LocationDetail({required this.id, required this.code, required this.name, required this.type, required this.active});

  factory LocationDetail.fromJson(Map<String, dynamic> json) {
    return LocationDetail(
      id: json['id'] as String,
      code: json['code'] as String,
      name: json['name'] as String,
      type: json['type'] as String,
      active: json['active'] as bool,
    );
  }
}

/// Wraps the location master-data CRUD endpoints — previously list-only,
/// which meant a brand-new tenant with zero locations had no in-app way to
/// add one at all (GRN, POS, and stock-count all depend on at least one
/// existing).
class LocationAdminApi {
  final ApiClient client;

  LocationAdminApi(this.client);

  /// Includes inactive locations too, for this management screen.
  Future<List<LocationDetail>> listAll() async {
    final response = await client.getAuthed('/api/v1/locations/all');
    return (response['locations'] as List<dynamic>)
        .map((l) => LocationDetail.fromJson(l as Map<String, dynamic>))
        .toList();
  }

  Future<LocationDetail> create({required String code, required String name, required String type}) async {
    final response = await client.postAuthed('/api/v1/locations', {'code': code, 'name': name, 'type': type});
    return LocationDetail.fromJson(response);
  }

  Future<void> update(String locationId, {required String name, required String type}) async {
    await client.putAuthed('/api/v1/locations/$locationId', {'name': name, 'type': type});
  }

  Future<void> setActive(String locationId, bool active) async {
    await client.postAuthed('/api/v1/locations/$locationId/status', {'active': active});
  }
}
