// Real tests of ProductRepository's read-through cache: a live search always
// hits the server and refreshes the cache; only a genuine network failure
// falls back to the cache. Uses FakeLocalDatabase (plain test(), no widget
// pump involved).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/pos/product_repository.dart';

import 'fake_local_db.dart';

Future<ApiClient> _authedClient(http.Client httpClient) async {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  await storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  return ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
}

void main() {
  test('a successful live search returns server results and caches them locally', () async {
    final localDb = FakeLocalDatabase();
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'results': [
            {
              'product': {
                'id': 'p1', 'sku': 'CF-01', 'name': 'Cattle Feed 50kg',
                'selling_price': '1200.00', 'batch_required': false,
                'loose_sale_allowed': false, 'active': true,
              },
              'match_type': 'NAME',
            }
          ]
        }),
        200,
      );
    });
    final repo = ProductRepository(client: await _authedClient(client), localDb: localDb);

    final result = await repo.search('cattle');

    expect(result.fromCache, isFalse);
    expect(result.products.single.name, 'Cattle Feed 50kg');
    expect(await localDb.productCacheSize(), 1);
  });

  test('a network failure falls back to the local cache, marked fromCache', () async {
    final localDb = FakeLocalDatabase();
    await localDb.upsertProducts([
      {
        'id': 'p1', 'sku': 'CF-01', 'name': 'Cattle Feed 50kg', 'local_name_ta': null,
        'mrp': null, 'selling_price': '1200.00', 'batch_required': 0,
        'loose_sale_allowed': 0, 'active': 1,
      },
    ]);
    final client = MockClient((request) async => throw Exception('Connection refused'));
    final repo = ProductRepository(client: await _authedClient(client), localDb: localDb);

    final result = await repo.search('cattle');

    expect(result.fromCache, isTrue);
    expect(result.products.single.id, 'p1');
    expect(result.products.single.matchType, 'CACHED');
  });

  test('a non-network API error (e.g. unauthenticated) is not swallowed into a cache fallback', () async {
    final localDb = FakeLocalDatabase();
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'error': {'code': 'UNAUTHENTICATED', 'message': 'token expired', 'retryable': false}
        }),
        401,
      );
    });
    final repo = ProductRepository(client: await _authedClient(client), localDb: localDb);

    expect(() => repo.search('cattle'), throwsA(isA<Exception>()));
  });
}
