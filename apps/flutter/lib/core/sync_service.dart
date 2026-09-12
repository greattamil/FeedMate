import 'dart:convert';

import 'api_client.dart';
import 'api_error.dart';
import 'local_db.dart';

class SyncResult {
  final int synced;
  final int failed;
  final int remaining;

  SyncResult({required this.synced, required this.failed, required this.remaining});
}

/// Drains the offline sale-intent outbox against the real backend.
///
/// An offline sale is queued as an *intent* (line items, location, tender
/// method, optional customer) rather than a priced invoice, because the
/// server is the sole authority on pricing/tax (PRD A28) and its finalize
/// endpoint requires the tender amount to exactly match its own computed
/// grand total (see pos.ErrTenderMismatch) — a total estimated offline from
/// cached prices could never satisfy that, especially once tax is involved.
/// So syncing re-quotes each intent for real once a connection exists, then
/// finalizes with that authoritative total. The invoice a customer receives
/// is therefore always priced at whatever the server says *at sync time*,
/// which is the same guarantee an online sale already gets.
class SyncService {
  final ApiClient client;
  final LocalDatabase localDb;

  SyncService({required this.client, required this.localDb});

  Future<SyncResult> syncPendingInvoices() async {
    final pending = await localDb.pendingInvoices();
    var synced = 0;
    var failed = 0;

    for (final row in pending) {
      final clientTransactionId = row['client_transaction_id'] as String;
      final intent = jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
      try {
        final quoteResponse = await client.postAuthed('/api/v1/pos/quote', {'lines': intent['lines']});
        final grandTotal = quoteResponse['grand_total'] as String;

        final finalizePayload = {
          'client_transaction_id': clientTransactionId,
          'location_id': intent['location_id'],
          'lines': intent['lines'],
          'tenders': [
            {'method': intent['tender_method'], 'amount': grandTotal},
          ],
          if (intent['customer_id'] != null) 'customer_id': intent['customer_id'],
        };
        final response = await client.postAuthed('/api/v1/pos/invoices', finalizePayload);
        await localDb.markInvoiceSynced(
          clientTransactionId,
          serverInvoiceNumber: response['invoice_number'] as String?,
        );
        synced++;
      } on ApiError catch (e) {
        if (e.code == 'NETWORK_ERROR' || e.retryable) {
          // Still offline, or a transient server error — leave PENDING and
          // stop for now rather than burning through the rest of the queue
          // against a server that isn't responding.
          break;
        }
        // A non-retryable rejection (e.g. a product deactivated since the
        // sale was queued, or — for a credit intent — the balance moved
        // past the limit in the meantime) can't be fixed by resending as-is
        // — park it as FAILED so it surfaces for manual review instead of
        // silently retrying forever.
        await localDb.markInvoiceFailed(clientTransactionId, '${e.code}: ${e.message}');
        failed++;
      }
    }

    final remaining = await localDb.pendingInvoiceCount();
    return SyncResult(synced: synced, failed: failed, remaining: remaining);
  }
}
