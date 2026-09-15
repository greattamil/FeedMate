import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/auth_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'supplier_api.dart';
import 'supplier_detail_screen.dart';
import 'supplier_form_dialog.dart';

/// Modernized Supplier Directory for FeedMate.
class SupplierListScreen extends StatefulWidget {
  const SupplierListScreen({super.key});

  @override
  State<SupplierListScreen> createState() => _SupplierListScreenState();
}

class _SupplierListScreenState extends State<SupplierListScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<SupplierSummary> _results = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(query));
  }

  Future<void> _search(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = SupplierApi(context.read<ApiClient>());
      final results = await api.search(query);
      if (!mounted) return;
      setState(() {
        _results = results;
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

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _addSupplier() async {
    final result = await showDialog<SupplierFormResult>(
      context: context,
      builder: (context) => const SupplierFormDialog(),
    );
    if (result == null) return;

    try {
      final api = SupplierApi(context.read<ApiClient>());
      await api.create(
        supplierCode: result.supplierCode!,
        name: result.name,
        tradeName: result.tradeName,
        gstin: result.gstin,
        phone: result.phone,
        email: result.email,
        paymentTermsDays: result.paymentTermsDays,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${result.name} added to supplier directory')),
      );
      await _search(_controller.text);
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSession>();
    final canManage = session.hasPermission('supplier.manage');
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Feed Suppliers & Mills', style: AppTypography.headline),
      ),
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              heroTag: null,
              key: const Key('add_supplier_fab'),
              onPressed: _addSupplier,
              icon: const Icon(Icons.add_business_rounded),
              label: const Text('Add Supplier'),
              backgroundColor: AppColors.primary,
            )
          : null,
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: AppColors.surface,
            child: TextField(
              key: const Key('supplier_search_field'),
              controller: _controller,
              decoration: InputDecoration(
                labelText: 'Search supplier by name, code, mobile, or GSTIN',
                prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _controller.clear();
                          _onQueryChanged('');
                        },
                      )
                    : null,
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          if (_loading) const LinearProgressIndicator(color: AppColors.primary, minHeight: 2),
          if (_error != null)
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.dangerContainer,
                borderRadius: AppDecorations.borderRadiusSm,
              ),
              child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
            ),
          Expanded(
            child: _results.isEmpty && !_loading
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.local_shipping_outlined, size: 56, color: Color(0xFF94A3B8)),
                        SizedBox(height: 12),
                        Text('No suppliers found', style: AppTypography.bodySecondary),
                      ],
                    ),
                  )
                : ListView.builder(
                    key: const Key('supplier_results_list'),
                    padding: const EdgeInsets.all(12),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final s = _results[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: AppDecorations.borderRadiusMd,
                          border: Border.all(color: AppColors.border),
                          boxShadow: AppDecorations.cardShadow,
                        ),
                        child: ListTile(
                          key: Key('supplier_${s.id}'),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF0284C7), Color(0xFF0EA5E9)],
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Center(
                              child: Icon(Icons.local_shipping_rounded, color: Colors.white, size: 22),
                            ),
                          ),
                          title: Text(s.name, style: AppTypography.title),
                          subtitle: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceSecondary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(s.supplierCode, style: AppTypography.caption),
                              ),
                              if (s.phone != null) ...[
                                const SizedBox(width: 8),
                                const Icon(Icons.phone_outlined, size: 12, color: AppColors.textSecondary),
                                const SizedBox(width: 3),
                                // Flexible + ellipsis rather than a bare Text:
                                // the trailing payable badge (e.g.
                                // "₹171825.00 Payable") can be wide enough
                                // to squeeze this row's available width
                                // below the phone number's natural size,
                                // which would otherwise overflow the tile
                                // on the right.
                                Flexible(
                                  child: Text(s.phone!, style: AppTypography.caption, overflow: TextOverflow.ellipsis),
                                ),
                              ],
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _payableBadge(s.payable),
                              const SizedBox(width: 4),
                              const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textSecondary),
                            ],
                          ),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => SupplierDetailScreen(supplierId: s.id)),
                            );
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// A shopkeeper browsing this directory wants to see who they owe money
  /// to without opening each supplier individually — an amber "Payable"
  /// pill when we owe them, a neutral "Settled" pill otherwise. Mirrors
  /// customer_list_screen.dart's _balanceBadge on the payable side.
  Widget _payableBadge(Decimal payable) {
    final isOwed = payable > Decimal.zero;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isOwed ? AppColors.warningContainer : AppColors.successContainer,
        borderRadius: BorderRadius.circular(AppDecorations.radiusFull),
      ),
      child: Text(
        isOwed ? '₹${payable.toStringAsFixed(2)} Payable' : 'Settled',
        style: AppTypography.caption.copyWith(
          fontWeight: FontWeight.bold,
          color: isOwed ? AppColors.onWarningContainer : AppColors.onSuccessContainer,
        ),
      ),
    );
  }
}
