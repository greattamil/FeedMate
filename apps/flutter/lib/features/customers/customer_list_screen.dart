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
import '../pos/customer_api.dart';
import 'customer_form_dialog.dart';
import 'customer_ledger_screen.dart';
import '../../core/number_format.dart';

/// The customer master-data directory: search, add, and jump into a
/// customer's ledger (which itself links to edit/deactivate).
class CustomerListScreen extends StatefulWidget {
  const CustomerListScreen({super.key});

  @override
  State<CustomerListScreen> createState() => _CustomerListScreenState();
}

class _CustomerListScreenState extends State<CustomerListScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<CustomerSummary> _results = [];
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
      final api = CustomerApi(context.read<ApiClient>());
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

  Future<void> _addCustomer() async {
    final draft = await showDialog<CustomerFormResult>(
      context: context,
      builder: (context) => const CustomerFormDialog(),
    );
    if (draft == null) return;

    try {
      final api = CustomerApi(context.read<ApiClient>());
      await api.create(
        name: draft.name,
        localName: draft.localName,
        phone: draft.phone,
        email: draft.email,
        gstin: draft.gstin,
        customerType: draft.customerType,
        creditLimit: draft.creditLimit,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${draft.name} added to customer directory')),
      );
      await _search(_controller.text);
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  LinearGradient _avatarGradient(String name) {
    final colors = [
      AppColors.gradientIndigo,
      AppColors.gradientCyan,
      AppColors.gradientEmerald,
      AppColors.gradientPurple,
      AppColors.gradientAmber,
    ];
    final idx = name.codeUnits.fold(0, (a, b) => a + b) % colors.length;
    return colors[idx];
  }

  String _getInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return 'C';
    if (parts.length == 1) return parts[0].substring(0, parts[0].length >= 2 ? 2 : 1).toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSession>();
    final canManage = session.hasPermission('credit.configure');

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Customer Directory', style: AppTypography.headline),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _search(_controller.text),
          ),
        ],
      ),
      floatingActionButton: canManage
          ? Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: AppDecorations.indigoGlow,
              ),
              child: FloatingActionButton.extended(
                heroTag: null,
                key: const Key('add_customer_fab'),
                onPressed: _addCustomer,
                icon: const Icon(Icons.person_add_alt_1_rounded, color: Colors.white),
                label: const Text('Add Customer', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                backgroundColor: AppColors.secondary,
              ),
            )
          : null,
      body: Column(
        children: [
          // Hero Header Banner
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              gradient: AppColors.gradientIndigo,
              borderRadius: AppDecorations.borderRadiusLg,
              boxShadow: AppDecorations.indigoGlow,
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                  ),
                  child: const Icon(Icons.people_alt_rounded, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Customer Ledgers & Credit',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Manage credit accounts, ledger history & payment receipts',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Search Input
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
                boxShadow: AppDecorations.cardShadow,
              ),
              child: TextField(
                key: const Key('customer_search_field'),
                controller: _controller,
                decoration: InputDecoration(
                  labelText: 'Search customer by name, code, or phone',
                  prefixIcon: const Icon(Icons.search_rounded, color: AppColors.secondary),
                  suffixIcon: _controller.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          onPressed: () {
                            _controller.clear();
                            _onQueryChanged('');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.transparent,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onChanged: _onQueryChanged,
              ),
            ),
          ),

          // Status & Count Pill
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSecondary,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.person_outline_rounded, size: 14, color: AppColors.secondary),
                      const SizedBox(width: 6),
                      Text(
                        '${_results.length} customer${_results.length == 1 ? '' : 's'}',
                        style: AppTypography.bodySecondary.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          if (_loading) const LinearProgressIndicator(color: AppColors.secondary, minHeight: 2),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.dangerContainer,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer))),
                  ],
                ),
              ),
            ),

          Expanded(
            child: _results.isEmpty && !_loading
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.people_outline_rounded, size: 56, color: AppColors.textTertiary),
                        SizedBox(height: 12),
                        Text('No customers found', style: AppTypography.bodySecondary),
                      ],
                    ),
                  )
                : ListView.builder(
                    key: const Key('customer_results_list'),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final c = _results[index];
                      final avatarGrad = _avatarGradient(c.name);
                      final initials = _getInitials(c.name);

                      return Container(
                        key: Key('customer_row_${c.id}'),
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.border),
                          boxShadow: AppDecorations.cardShadow,
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => CustomerLedgerScreen(customerId: c.id)),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              children: [
                                // Chromatic Avatar
                                Container(
                                  width: 46,
                                  height: 46,
                                  decoration: BoxDecoration(
                                    gradient: avatarGrad,
                                    borderRadius: BorderRadius.circular(12),
                                    boxShadow: [
                                      BoxShadow(
                                        color: avatarGrad.colors.first.withValues(alpha: 0.25),
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

                                // Customer Info
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        c.name,
                                        style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: AppColors.surfaceSecondary,
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(color: AppColors.border),
                                            ),
                                            child: Text(
                                              c.customerCode,
                                              style: AppTypography.caption.copyWith(
                                                fontWeight: FontWeight.w600,
                                                color: AppColors.textSecondary,
                                              ),
                                            ),
                                          ),
                                          if (c.phone != null) ...[
                                            const SizedBox(width: 8),
                                            const Icon(Icons.phone_rounded, size: 12, color: AppColors.textSecondary),
                                            const SizedBox(width: 4),
                                            Flexible(
                                              child: Text(
                                                c.phone!,
                                                style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),

                                // Trailing Balance & Arrow
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _balanceBadge(c.balance),
                                    const SizedBox(width: 6),
                                    const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.textTertiary),
                                  ],
                                ),
                              ],
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

  /// Outstanding balance badge: red Due pill if balance > 0, green Clear pill if 0.
  Widget _balanceBadge(Decimal balance) {
    final isDue = balance > Decimal.zero;
    final fg = isDue ? AppColors.onDangerContainer : AppColors.onSuccessContainer;
    final bg = isDue ? AppColors.dangerContainer : AppColors.successContainer;
    final icon = isDue ? Icons.error_outline_rounded : Icons.check_circle_rounded;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppDecorations.radiusFull),
        border: Border.all(color: (isDue ? AppColors.danger : AppColors.success).withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            isDue ? '${money(balance)} Due' : 'Clear',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}
