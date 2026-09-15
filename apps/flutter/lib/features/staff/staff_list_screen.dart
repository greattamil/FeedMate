import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'staff_api.dart';
import 'staff_detail_screen.dart';
import 'staff_form_dialog.dart';

/// Staff/user management: browse accounts, create a new one, and drill
/// into a detail screen for status and role changes. A staff account is
/// never hard-deleted (see identity.Service.SetUserStatus's doc comment) —
/// only ever deactivated, since historical invoices/GRNs/audit entries
/// reference it as the acting user.
class StaffListScreen extends StatefulWidget {
  const StaffListScreen({super.key});

  @override
  State<StaffListScreen> createState() => _StaffListScreenState();
}

class _StaffListScreenState extends State<StaffListScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<StaffSummary> _results = [];
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
      final api = StaffApi(context.read<ApiClient>());
      final results = await api.list(query: query);
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

  Future<void> _addStaff() async {
    final draft = await showDialog<StaffFormResult>(
      context: context,
      builder: (context) => const StaffFormDialog(),
    );
    if (draft == null) return;

    try {
      final api = StaffApi(context.read<ApiClient>());
      await api.create(
        username: draft.username,
        password: draft.password!,
        displayName: draft.displayName,
        phone: draft.phone,
        email: draft.email,
        roleIds: draft.roleIds,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${draft.displayName} added to staff')),
      );
      await _search(_controller.text);
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Staff', style: AppTypography.headline),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_staff_fab'),
        onPressed: _addStaff,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Add Staff'),
        backgroundColor: AppColors.primary,
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: AppColors.surface,
            child: TextField(
              key: const Key('staff_search_field'),
              controller: _controller,
              decoration: InputDecoration(
                labelText: 'Search by username or name',
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
                        Icon(Icons.badge_outlined, size: 56, color: Color(0xFF94A3B8)),
                        SizedBox(height: 12),
                        Text('No staff found', style: AppTypography.bodySecondary),
                      ],
                    ),
                  )
                : ListView.builder(
                    key: const Key('staff_results_list'),
                    // Extra bottom padding reserves room for the extended
                    // "Add Staff" FAB, which otherwise floats over the
                    // last row in the list.
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final u = _results[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: AppDecorations.borderRadiusMd,
                          border: Border.all(color: AppColors.border),
                          boxShadow: AppDecorations.cardShadow,
                        ),
                        child: ListTile(
                          key: Key('staff_item_${u.id}'),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              gradient: AppColors.gradientIndigo,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Center(
                              child: Text(
                                u.displayName.isNotEmpty ? u.displayName.substring(0, 1).toUpperCase() : '?',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                              ),
                            ),
                          ),
                          title: Text(u.displayName, style: AppTypography.title),
                          subtitle: Text(
                            '${u.username} · ${u.status}',
                            style: AppTypography.caption.copyWith(
                              color: u.status == 'ACTIVE' ? AppColors.textSecondary : AppColors.danger,
                            ),
                          ),
                          trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textSecondary),
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => StaffDetailScreen(userId: u.id)),
                            );
                            await _search(_controller.text);
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
}
