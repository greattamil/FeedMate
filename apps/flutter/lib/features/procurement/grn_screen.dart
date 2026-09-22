import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../pos/pos_api.dart';
import '../supplier/supplier_api.dart';
import 'grn_line_form_screen.dart';
import 'procurement_api.dart';
import 'product_picker_screen.dart';
import 'supplier_picker_screen.dart';
import '../../core/number_format.dart';
import '../products/location_screen.dart';

/// Receive physical stock from a supplier (PRD 7.4): pick the supplier and
/// receiving location, add one or more lines (product, batch, quantity,
/// cost, optional weight/tare), and post. The server is authoritative for
/// every computed number (net weight, tax, payable, accounting journal) —
/// this screen only collects what a human physically observed.
class GrnScreen extends StatefulWidget {
  const GrnScreen({super.key});

  @override
  State<GrnScreen> createState() => _GrnScreenState();
}

class _GrnScreenState extends State<GrnScreen> {
  final _supplierDocController = TextEditingController();
  final _vehicleNoController = TextEditingController();

  SupplierSummary? _supplier;
  List<LocationInfo> _locations = [];
  String? _selectedLocationId;
  final List<GRNLineDraft> _lines = [];
  bool _loadingLocations = true;
  bool _posting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLocations();
  }

  @override
  void dispose() {
    _supplierDocController.dispose();
    _vehicleNoController.dispose();
    super.dispose();
  }

  Future<void> _loadLocations() async {
    try {
      final api = PosApi(context.read<ApiClient>());
      final locations = await api.listLocations();
      if (!mounted) return;
      setState(() {
        _locations = locations;
        if (locations.length == 1) _selectedLocationId = locations.first.id;
        _loadingLocations = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load locations: ${e.message}';
        _loadingLocations = false;
      });
    }
  }

  Future<void> _manageLocations() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LocationScreen()),
    );
    if (!mounted) return;
    setState(() => _loadingLocations = true);
    await _loadLocations();
  }

  Future<void> _pickSupplier() async {
    final supplier = await Navigator.of(context).push<SupplierSummary>(
      MaterialPageRoute(builder: (_) => const SupplierPickerScreen()),
    );
    if (supplier == null) return;
    setState(() => _supplier = supplier);
  }

  Future<void> _addLine() async {
    final product = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ProductPickerScreen()),
    );
    if (product == null || !mounted) return;
    final line = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GrnLineFormScreen(product: product)),
    );
    if (line == null) return;
    setState(() => _lines.add(line));
  }

  Future<void> _editLine(int index) async {
    final line = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GrnLineFormScreen(product: _lines[index].product, existing: _lines[index])),
    );
    if (line == null) return;
    setState(() => _lines[index] = line);
  }

  bool get _canPost => _supplier != null && _selectedLocationId != null && _lines.isNotEmpty && !_posting;

  Future<void> _post() async {
    await _submitPost();
  }

  Future<void> _submitPost({bool overrideTare = false, String? overrideReason}) async {
    if (!_canPost && !overrideTare) return;
    setState(() {
      _posting = true;
      _error = null;
    });
    try {
      final api = ProcurementApi(context.read<ApiClient>());
      final result = await api.postGRN(
        supplierId: _supplier!.id,
        locationId: _selectedLocationId!,
        supplierDocumentNo: _supplierDocController.text.trim(),
        vehicleNo: _vehicleNoController.text.trim(),
        lines: _lines,
        overrideTare: overrideTare,
        overrideTareReason: overrideReason,
      );
      if (!mounted) return;
      setState(() => _posting = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('GRN Posted'),
          content: Text('GRN ${result.grnNumber} was posted successfully.'),
          actions: [
            TextButton(
              key: const Key('grn_posted_ok_button'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      setState(() {
        _lines.clear();
        _supplier = null;
        _supplierDocController.clear();
        _vehicleNoController.clear();
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _posting = false);
      if (e.code == 'CONFLICT' && e.message.contains('tare weight exceeds')) {
        final reason = await showDialog<String>(
          context: context,
          builder: (context) => _TareOverrideDialog(serverMessage: e.message),
        );
        if (reason != null && reason.isNotEmpty) {
          await _submitPost(overrideTare: true, overrideReason: reason);
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Receive Stock (GRN)', style: AppTypography.headline),
      ),
      body: _loadingLocations
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                // Compact Teal Hero Bar
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    gradient: AppColors.gradientTealCyan,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primary.withOpacity(0.2),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.input_rounded, color: Colors.white, size: 20),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Goods Received Note (GRN)',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_lines.length} lines',
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
                if (_error != null) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.dangerContainer,
                      borderRadius: AppDecorations.borderRadiusSm,
                    ),
                    child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer, fontSize: 12)),
                  ),
                ],
                // Supplier Selection Card
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                    boxShadow: AppDecorations.cardShadow,
                  ),
                  child: ListTile(
                    key: const Key('grn_supplier_tile'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                    leading: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        gradient: AppColors.gradientAmber,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Center(
                        child: Icon(Icons.local_shipping_rounded, color: Colors.white, size: 18),
                      ),
                    ),
                    title: Text(
                      _supplier == null ? 'Select supplier' : _supplier!.name,
                      style: AppTypography.title.copyWith(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      _supplier == null ? 'Required to create intake note' : _supplier!.supplierCode,
                      style: AppTypography.caption,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
                    onTap: _pickSupplier,
                  ),
                ),
                const SizedBox(height: 10),
                // Shipment Details Card
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                    boxShadow: AppDecorations.cardShadow,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!_loadingLocations && _locations.isEmpty)
                        Container(
                          key: const Key('grn_no_locations_prompt'),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.dangerContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.warehouse_rounded, color: AppColors.onDangerContainer),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'No receiving warehouse/location set up yet.',
                                  style: TextStyle(color: AppColors.onDangerContainer, fontSize: 13),
                                ),
                              ),
                              TextButton(
                                key: const Key('grn_add_location_button'),
                                onPressed: _manageLocations,
                                child: const Text('Add one'),
                              ),
                            ],
                          ),
                        )
                      else
                        DropdownButtonFormField<String>(
                          key: const Key('grn_location_dropdown'),
                          initialValue: _selectedLocationId,
                          decoration: InputDecoration(
                            labelText: 'Receiving warehouse / location',
                            prefixIcon: const Icon(Icons.warehouse_rounded, size: 18, color: AppColors.primary),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            suffixIcon: IconButton(
                              key: const Key('grn_manage_locations_button'),
                              icon: const Icon(Icons.settings_outlined, size: 18, color: AppColors.textSecondary),
                              tooltip: 'Manage locations',
                              onPressed: _manageLocations,
                            ),
                          ),
                          items: _locations.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name))).toList(),
                          onChanged: (v) => setState(() => _selectedLocationId = v),
                        ),
                      const SizedBox(height: 10),
                      TextField(
                        key: const Key('grn_supplier_doc_field'),
                        controller: _supplierDocController,
                        decoration: InputDecoration(
                          labelText: 'Supplier document / invoice no. (optional)',
                          prefixIcon: const Icon(Icons.receipt_long_rounded, size: 18, color: AppColors.textSecondary),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        key: const Key('grn_vehicle_no_field'),
                        controller: _vehicleNoController,
                        decoration: InputDecoration(
                          labelText: 'Delivery vehicle no. (optional)',
                          prefixIcon: const Icon(Icons.local_shipping_rounded, size: 18, color: AppColors.textSecondary),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Received Feed Items Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Received Items (${_lines.length})',
                      style: AppTypography.headline.copyWith(fontSize: 15, fontWeight: FontWeight.w800),
                    ),
                    FilledButton.icon(
                      key: const Key('grn_add_line_button'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: _addLine,
                      icon: const Icon(Icons.add_rounded, size: 16),
                      label: const Text('Add Product Line', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_lines.isEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Center(
                      child: Column(
                        children: const [
                          Icon(Icons.move_to_inbox_outlined, size: 36, color: Color(0xFF94A3B8)),
                          SizedBox(height: 6),
                          Text('No lines added yet.', style: AppTypography.bodySecondary),
                        ],
                      ),
                    ),
                  ),
                ...List.generate(_lines.length, (index) {
                  final line = _lines[index];
                  return Container(
                    key: Key('grn_line_card_$index'),
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                      boxShadow: AppDecorations.cardShadow,
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      leading: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          gradient: AppColors.gradientEmerald,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.inventory_2_rounded, color: Colors.white, size: 18),
                      ),
                      title: Text(line.product.name, style: AppTypography.title.copyWith(fontSize: 14, fontWeight: FontWeight.w700)),
                      subtitle: Text(
                        'Batch ${line.batchCode} · Qty ${line.receivedQty.toStringAsFixed(2)} · ${money(line.unitCost)}/unit',
                        style: AppTypography.caption,
                      ),
                      onTap: () => _editLine(index),
                      trailing: IconButton(
                        key: Key('grn_line_delete_$index'),
                        icon: const Icon(Icons.delete_outline_rounded, size: 20, color: AppColors.danger),
                        onPressed: () => setState(() => _lines.removeAt(index)),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 24),
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: _canPost ? AppDecorations.emeraldGlow : null,
                  ),
                  child: FilledButton(
                    key: const Key('grn_post_button'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: AppColors.border,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: _canPost ? _post : null,
                    child: _posting
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Post Inward GRN', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
    );
  }
}

class _TareOverrideDialog extends StatefulWidget {
  final String serverMessage;

  const _TareOverrideDialog({required this.serverMessage});

  @override
  State<_TareOverrideDialog> createState() => _TareOverrideDialogState();
}

class _TareOverrideDialogState extends State<_TareOverrideDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: AppColors.gradientAmber,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Text('Tare Exceeds Threshold', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.warningContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(widget.serverMessage, style: const TextStyle(color: AppColors.onWarningContainer, fontSize: 13)),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('grn_tare_override_reason_field'),
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Reason for override',
              border: OutlineInputBorder(borderRadius: AppDecorations.borderRadiusMd),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('grn_tare_override_submit'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.warning,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Override & Post', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
