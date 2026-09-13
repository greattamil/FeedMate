import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../pos/pos_api.dart';
import '../supplier/supplier_api.dart';
import 'grn_line_form_screen.dart';
import 'procurement_api.dart';
import 'product_picker_screen.dart';
import 'supplier_picker_screen.dart';

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
      appBar: AppBar(title: const Text('Receive Stock (GRN)')),
      body: _loadingLocations
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null) ...[
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 12),
                ],
                ListTile(
                  key: const Key('grn_supplier_tile'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(_supplier == null ? 'Select supplier' : _supplier!.name),
                  subtitle: _supplier == null ? null : Text(_supplier!.supplierCode),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _pickSupplier,
                ),
                DropdownButtonFormField<String>(
                  key: const Key('grn_location_dropdown'),
                  initialValue: _selectedLocationId,
                  decoration: const InputDecoration(labelText: 'Receiving location'),
                  items: _locations.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name))).toList(),
                  onChanged: (v) => setState(() => _selectedLocationId = v),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('grn_supplier_doc_field'),
                  controller: _supplierDocController,
                  decoration: const InputDecoration(labelText: 'Supplier document / invoice no. (optional)'),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('grn_vehicle_no_field'),
                  controller: _vehicleNoController,
                  decoration: const InputDecoration(labelText: 'Vehicle no. (optional)'),
                ),
                const Divider(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Lines', style: TextStyle(fontWeight: FontWeight.bold)),
                    TextButton.icon(
                      key: const Key('grn_add_line_button'),
                      onPressed: _addLine,
                      icon: const Icon(Icons.add),
                      label: const Text('Add Line'),
                    ),
                  ],
                ),
                if (_lines.isEmpty) const Text('No lines added yet.'),
                ...List.generate(_lines.length, (index) {
                  final line = _lines[index];
                  return Card(
                    key: Key('grn_line_card_$index'),
                    child: ListTile(
                      title: Text(line.product.name),
                      subtitle: Text(
                          'Batch ${line.batchCode} · Qty ${line.receivedQty.toStringAsFixed(2)} · ₹${line.unitCost.toStringAsFixed(2)}/unit'),
                      onTap: () => _editLine(index),
                      trailing: IconButton(
                        key: Key('grn_line_delete_$index'),
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() => _lines.removeAt(index)),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('grn_post_button'),
                  onPressed: _canPost ? _post : null,
                  child: _posting ? const CircularProgressIndicator() : const Text('Post GRN'),
                ),
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
      title: const Text('Tare Exceeds Threshold'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.serverMessage, style: const TextStyle(color: Colors.orange)),
          const SizedBox(height: 12),
          TextField(
            key: const Key('grn_tare_override_reason_field'),
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Reason for override'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('grn_tare_override_submit'),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Override & Post'),
        ),
      ],
    );
  }
}
