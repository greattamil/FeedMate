import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/number_format.dart';
import 'create_tenant_screen.dart';
import 'platform_api.dart';
import 'platform_api_client.dart';
import 'tenant_detail_screen.dart';

/// Every tenant on this deployment — the platform admin's home screen.
/// Never a per-tenant view: this is the one place "all clients" is a valid
/// thing to see at once.
class TenantListScreen extends StatefulWidget {
  const TenantListScreen({super.key});

  @override
  State<TenantListScreen> createState() => _TenantListScreenState();
}

class _TenantListScreenState extends State<TenantListScreen> {
  List<TenantSummary> _tenants = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      final tenants = await api.listTenants();
      if (!mounted) return;
      setState(() {
        _tenants = tenants;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _openCreate() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateTenantScreen()),
    );
    if (created == true) await _load();
  }

  Future<void> _openDetail(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TenantDetailScreen(tenantId: id)),
    );
    await _load();
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'ACTIVE':
        return const Color(0xFF10B981);
      case 'SUSPENDED':
        return const Color(0xFFF59E0B);
      default:
        return const Color(0xFFEF4444);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_tenant_fab'),
        onPressed: _openCreate,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New Tenant'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                    itemCount: _tenants.length,
                    itemBuilder: (context, index) {
                      final t = _tenants[index];
                      return Container(
                        key: Key('tenant_item_${t.id}'),
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(14)),
                        child: ListTile(
                          onTap: () => _openDetail(t.id),
                          title: Text(t.legalName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          subtitle: Text(
                            '${t.city} · ${t.planCode} · ${intGrouped(t.userCount)} user${t.userCount == 1 ? '' : 's'}',
                            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                          ),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: _statusColor(t.status).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(20)),
                            child: Text(t.status, style: TextStyle(color: _statusColor(t.status), fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
