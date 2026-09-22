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
import '../../core/number_format.dart';

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

  List<Color> _avatarGradient(String key) {
    const palettes = [
      [Color(0xFFD97706), Color(0xFFF59E0B)], // Amber
      [Color(0xFFEA580C), Color(0xFFF97316)], // Orange
      [Color(0xFF0D9488), Color(0xFF14B8A6)], // Teal
      [Color(0xFF4F46E5), Color(0xFF6366F1)], // Indigo
      [Color(0xFF059669), Color(0xFF10B981)], // Emerald
      [Color(0xFF0284C7), Color(0xFF0EA5E9)], // Cyan
    ];
    final hash = key.codeUnits.fold<int>(0, (prev, elem) => prev + elem);
    return palettes[hash % palettes.length];
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
          ? Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: AppDecorations.amberGlow,
              ),
              child: FloatingActionButton.extended(
                heroTag: null,
                key: const Key('add_supplier_fab'),
                onPressed: _addSupplier,
                icon: const Icon(Icons.add_business_rounded),
                label: const Text('Add Supplier', style: TextStyle(fontWeight: FontWeight.w700)),
                backgroundColor: AppColors.warning,
                foregroundColor: Colors.white,
              ),
            )
          : null,
      body: Column(
        children: [
          // Amber Hero Banner
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              gradient: AppColors.gradientAmber,
              borderRadius: AppDecorations.borderRadiusLg,
              boxShadow: [
                BoxShadow(
                  color: AppColors.warning.withOpacity(0.25),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withOpacity(0.3)),
                  ),
                  child: const Icon(Icons.local_shipping_rounded, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Supplier Directory',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Vendors, feed mills & procurement payables',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.9),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.2)),
                  ),
                  child: Text(
                    '${_results.length} active',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Search Field
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              key: const Key('supplier_search_field'),
              controller: _controller,
              decoration: InputDecoration(
                filled: true,
                fillColor: AppColors.surface,
                labelText: 'Search supplier by name, code, mobile, or GSTIN',
                labelStyle: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                prefixIcon: const Icon(Icons.search_rounded, color: AppColors.warning),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _controller.clear();
                          _onQueryChanged('');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: AppDecorations.borderRadiusMd,
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: AppDecorations.borderRadiusMd,
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: AppDecorations.borderRadiusMd,
                  borderSide: const BorderSide(color: AppColors.warning, width: 1.5),
                ),
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          if (_loading) const LinearProgressIndicator(color: AppColors.warning, minHeight: 2),
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
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final s = _results[index];
                      final gradientColors = _avatarGradient(s.supplierCode + s.name);
                      final initials = s.name.trim().isNotEmpty
                          ? s.name.trim().split(RegExp(r'\s+')).take(2).map((w) => w.isNotEmpty ? w[0].toUpperCase() : '').join()
                          : 'S';

                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: AppDecorations.borderRadiusMd,
                          border: Border.all(color: AppColors.border),
                          boxShadow: AppDecorations.cardShadow,
                        ),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: AppDecorations.borderRadiusMd,
                          child: InkWell(
                            key: Key('supplier_${s.id}'),
                            borderRadius: AppDecorations.borderRadiusMd,
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => SupplierDetailScreen(supplierId: s.id)),
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              child: Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: gradientColors,
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                          color: gradientColors.first.withOpacity(0.3),
                                          blurRadius: 8,
                                          offset: const Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: Center(
                                      child: Text(
                                        initials,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          s.name,
                                          style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: AppColors.surfaceSecondary,
                                                borderRadius: BorderRadius.circular(4),
                                                border: Border.all(color: AppColors.border),
                                              ),
                                              child: Text(s.supplierCode, style: AppTypography.caption.copyWith(fontWeight: FontWeight.w600)),
                                            ),
                                            if (s.phone != null) ...[
                                              const SizedBox(width: 8),
                                              const Icon(Icons.phone_rounded, size: 12, color: AppColors.textSecondary),
                                              const SizedBox(width: 3),
                                              Flexible(
                                                child: Text(
                                                  s.phone!,
                                                  style: AppTypography.caption,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  _payableBadge(s.payable),
                                  const SizedBox(width: 6),
                                  const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.textSecondary),
                                ],
                              ),
                            ),
                          ),
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
  /// pill when we owe them, a neutral "Settled" pill otherwise.
  Widget _payableBadge(Decimal payable) {
    final isOwed = payable > Decimal.zero;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: isOwed ? AppColors.warningContainer : AppColors.successContainer,
        borderRadius: BorderRadius.circular(AppDecorations.radiusFull),
        border: Border.all(
          color: isOwed ? AppColors.warning.withOpacity(0.3) : AppColors.success.withOpacity(0.3),
        ),
      ),
      child: Text(
        isOwed ? '${money(payable)} Payable' : 'Settled',
        style: AppTypography.caption.copyWith(
          fontWeight: FontWeight.w700,
          color: isOwed ? AppColors.onWarningContainer : AppColors.onSuccessContainer,
        ),
      ),
    );
  }
}
