import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../pos/customer_api.dart';
import '../pos/customer_picker_screen.dart';
import '../pos/pos_api.dart';
import '../procurement/product_picker_screen.dart';
import 'contra_api.dart';
import 'contra_line_form_screen.dart';

/// Contra / buy-back (PRD 8): the shop takes stock back from a farmer and
/// credits it against what they owe, instead of paying cash. Pick the
/// customer and the location the stock is returning into, add one or more
/// product lines, and post. The server is authoritative for the receivable
/// reduction, inventory entry, and accounting journal — this screen only
/// collects what a human physically observed.
class ContraScreen extends StatefulWidget {
  const ContraScreen({super.key});

  @override
  State<ContraScreen> createState() => _ContraScreenState();
}

class _ContraScreenState extends State<ContraScreen> {
  final _sourceReferenceController = TextEditingController();

  CustomerSummary? _customer;
  List<LocationInfo> _locations = [];
  String? _selectedLocationId;
  final List<ContraLineDraft> _lines = [];
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
    _sourceReferenceController.dispose();
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

  Future<void> _pickCustomer() async {
    final customer = await Navigator.of(context).push<CustomerSummary>(
      MaterialPageRoute(builder: (_) => const CustomerPickerScreen()),
    );
    if (customer == null) return;
    setState(() => _customer = customer);
  }

  Future<void> _addLine() async {
    final product = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ProductPickerScreen()),
    );
    if (product == null || !mounted) return;
    final line = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ContraLineFormScreen(product: product)),
    );
    if (line == null) return;
    setState(() => _lines.add(line));
  }

  Future<void> _editLine(int index) async {
    final line = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ContraLineFormScreen(product: _lines[index].product, existing: _lines[index])),
    );
    if (line == null) return;
    setState(() => _lines[index] = line);
  }

  bool get _canPost => _customer != null && _selectedLocationId != null && _lines.isNotEmpty && !_posting;

  Future<void> _post() async {
    if (!_canPost) return;
    setState(() {
      _posting = true;
      _error = null;
    });
    try {
      final api = ContraApi(context.read<ApiClient>());
      final result = await api.postContra(
        customerId: _customer!.id,
        locationId: _selectedLocationId!,
        sourceReference: _sourceReferenceController.text.trim(),
        lines: _lines,
      );
      if (!mounted) return;
      setState(() => _posting = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Contra Posted'),
          content: Text(
            'Contra ${result.contraNumber} was posted, crediting ₹${result.totalValue.toStringAsFixed(2)} against ${_customer!.name}\'s balance.',
          ),
          actions: [
            TextButton(
              key: const Key('contra_posted_ok_button'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      setState(() {
        _lines.clear();
        _customer = null;
        _sourceReferenceController.clear();
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _posting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('Contra / Buy-Back', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ),
      body: _loadingLocations
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF0F766E)))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFE4E6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(_error!, style: const TextStyle(color: Color(0xFFE11D48), fontSize: 13)),
                  ),
                ],
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: const [BoxShadow(color: Color(0x060F172A), blurRadius: 10, offset: Offset(0, 2))],
                  ),
                  child: ListTile(
                    key: const Key('contra_customer_tile'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEDE9FE),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Center(
                        child: Icon(Icons.person_rounded, color: Color(0xFF7C3AED), size: 20),
                      ),
                    ),
                    title: Text(
                      _customer == null ? 'Select customer' : _customer!.name,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    subtitle: Text(
                      _customer == null ? 'Required — whose balance is credited' : _customer!.customerCode,
                      style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF64748B)),
                    onTap: _pickCustomer,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DropdownButtonFormField<String>(
                        key: const Key('contra_location_dropdown'),
                        initialValue: _selectedLocationId,
                        decoration: const InputDecoration(
                          labelText: 'Receiving warehouse / location',
                          prefixIcon: Icon(Icons.warehouse_rounded, size: 18),
                        ),
                        items: _locations.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name))).toList(),
                        onChanged: (v) => setState(() => _selectedLocationId = v),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('contra_source_reference_field'),
                        controller: _sourceReferenceController,
                        decoration: const InputDecoration(
                          labelText: 'Reference / note (optional)',
                          prefixIcon: Icon(Icons.receipt_long_rounded, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Returned Items (${_lines.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    FilledButton.icon(
                      key: const Key('contra_add_line_button'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF0F766E),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _addLine,
                      icon: const Icon(Icons.add_rounded, size: 16),
                      label: const Text('Add Product Line', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (_lines.isEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Center(
                      child: Column(
                        children: const [
                          Icon(Icons.undo_rounded, size: 42, color: Color(0xFF94A3B8)),
                          SizedBox(height: 8),
                          Text('No lines added yet.', style: TextStyle(color: Color(0xFF64748B), fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ...List.generate(_lines.length, (index) {
                  final line = _lines[index];
                  return Container(
                    key: Key('contra_line_card_$index'),
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                      boxShadow: const [BoxShadow(color: Color(0x060F172A), blurRadius: 6, offset: Offset(0, 1))],
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEDE9FE),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.undo_rounded, color: Color(0xFF7C3AED), size: 20),
                      ),
                      title: Text(line.product.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      subtitle: Text(
                        'Batch ${line.batchCode} · Qty ${line.quantity.toString()} · ₹${line.valuationUnitPrice.toStringAsFixed(2)}/unit',
                        style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                      ),
                      onTap: () => _editLine(index),
                      trailing: IconButton(
                        key: Key('contra_line_delete_$index'),
                        icon: const Icon(Icons.delete_outline, size: 20, color: Color(0xFFE11D48)),
                        onPressed: () => setState(() => _lines.removeAt(index)),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('contra_post_button'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0F766E),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _canPost ? _post : null,
                  child: _posting
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Post Contra', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 20),
              ],
            ),
    );
  }
}
