import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'doc_series_api.dart';

/// Manage financial years and their document-numbering series (INVOICE,
/// GRN, RETURN, CONTRA, RECEIPT, etc.). Opening a new financial year here
/// automatically closes whatever year was previously OPEN — there is only
/// ever one "current" year the rest of the app resolves postings against
/// (see accounting.GetActiveFinancialYear server-side). The "Seed Default
/// Series" action is the one-click fix for the exact failure this screen
/// exists to prevent: a missing series row that would otherwise only
/// surface as an opaque error the moment a cashier tries to finalize a
/// sale on April 1st.
class DocSeriesScreen extends StatefulWidget {
  const DocSeriesScreen({super.key});

  @override
  State<DocSeriesScreen> createState() => _DocSeriesScreenState();
}

class _DocSeriesScreenState extends State<DocSeriesScreen> {
  List<FinancialYear> _years = [];
  String? _selectedYearId;
  List<DocumentSeries> _series = [];
  bool _loadingYears = true;
  bool _loadingSeries = false;
  String? _error;

  static final _dateFormat = DateFormat('dd MMM yyyy');

  @override
  void initState() {
    super.initState();
    _loadYears();
  }

  Future<void> _loadYears() async {
    setState(() {
      _loadingYears = true;
      _error = null;
    });
    try {
      final api = DocSeriesApi(context.read<ApiClient>());
      final years = await api.listFinancialYears();
      if (!mounted) return;
      setState(() {
        _years = years;
        _loadingYears = false;
        _selectedYearId ??= years.isNotEmpty ? years.first.id : null;
      });
      if (_selectedYearId != null) await _loadSeries(_selectedYearId!);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loadingYears = false;
      });
    }
  }

  Future<void> _loadSeries(String financialYearId) async {
    setState(() => _loadingSeries = true);
    try {
      final api = DocSeriesApi(context.read<ApiClient>());
      final series = await api.listDocumentSeries(financialYearId);
      if (!mounted) return;
      setState(() {
        _series = series;
        _loadingSeries = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loadingSeries = false;
      });
    }
  }

  Future<void> _createFinancialYear() async {
    final draft = await showDialog<_NewYearResult>(
      context: context,
      builder: (context) => const _NewFinancialYearDialog(),
    );
    if (draft == null) return;

    try {
      final api = DocSeriesApi(context.read<ApiClient>());
      final id = await api.createFinancialYear(label: draft.label, startDate: draft.startDate, endDate: draft.endDate);
      if (!mounted) return;
      setState(() => _selectedYearId = id);
      await _loadYears();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Financial year ${draft.label} opened. Any prior open year was closed.')),
      );
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _closeFinancialYear() async {
    final yearId = _selectedYearId;
    if (yearId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close Financial Year?'),
        content: const Text('No further documents can be posted against a closed year.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('close_financial_year_confirm'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final api = DocSeriesApi(context.read<ApiClient>());
      await api.closeFinancialYear(yearId);
      await _loadYears();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _seedDefaults() async {
    final yearId = _selectedYearId;
    if (yearId == null) return;
    final year = _years.firstWhere((y) => y.id == yearId);
    try {
      final api = DocSeriesApi(context.read<ApiClient>());
      final created = await api.seedDefaultSeries(yearId, labelPrefix: year.label);
      if (!mounted) return;
      await _loadSeries(yearId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(created.isEmpty ? 'All core document types already have an active series' : 'Created ${created.length} default series')),
      );
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _addSeries() async {
    final yearId = _selectedYearId;
    if (yearId == null) return;
    final draft = await showDialog<_NewSeriesResult>(
      context: context,
      builder: (context) => const _NewSeriesDialog(),
    );
    if (draft == null) return;

    try {
      final api = DocSeriesApi(context.read<ApiClient>());
      await api.createDocumentSeries(
        financialYearId: yearId,
        documentType: draft.documentType,
        prefix: draft.prefix,
        startingNumber: draft.startingNumber,
        padding: draft.padding,
      );
      await _loadSeries(yearId);
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _toggleSeriesActive(DocumentSeries series) async {
    try {
      final api = DocSeriesApi(context.read<ApiClient>());
      await api.setDocumentSeriesActive(series.id, !series.active);
      await _loadSeries(series.financialYearId);
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedYear = _years.where((y) => y.id == _selectedYearId).cast<FinancialYear?>().firstOrNull;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Financial Years & Document Series', style: AppTypography.headline),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('new_financial_year_fab'),
        onPressed: _createFinancialYear,
        icon: const Icon(Icons.calendar_month_rounded),
        label: const Text('New Year'),
        backgroundColor: AppColors.primary,
      ),
      body: _loadingYears
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: Colors.red))))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    DropdownButtonFormField<String>(
                      key: const Key('financial_year_dropdown'),
                      initialValue: _selectedYearId,
                      decoration: const InputDecoration(labelText: 'Financial Year'),
                      items: _years
                          .map((y) => DropdownMenuItem(
                                value: y.id,
                                child: Text('${y.label} (${y.status})'),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _selectedYearId = v);
                        _loadSeries(v);
                      },
                    ),
                    if (selectedYear != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: AppDecorations.card(color: AppColors.surface),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_dateFormat.format(selectedYear.startDate)} – ${_dateFormat.format(selectedYear.endDate)}',
                              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Status: ${selectedYear.status}',
                              key: const Key('financial_year_status_text'),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: selectedYear.status == 'OPEN' ? AppColors.success : AppColors.danger,
                              ),
                            ),
                            if (selectedYear.status == 'OPEN') ...[
                              const SizedBox(height: 10),
                              OutlinedButton(
                                key: const Key('close_financial_year_button'),
                                onPressed: _closeFinancialYear,
                                child: const Text('Close This Year'),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Document Series', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          Row(
                            children: [
                              TextButton.icon(
                                key: const Key('seed_default_series_button'),
                                onPressed: _seedDefaults,
                                icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
                                label: const Text('Seed Defaults'),
                              ),
                              IconButton(
                                key: const Key('add_series_button'),
                                onPressed: _addSeries,
                                icon: const Icon(Icons.add_circle_outline, color: AppColors.primary),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (_loadingSeries)
                        const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
                      else if (_series.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: Text('No document series configured for this year', style: AppTypography.bodySecondary)),
                        )
                      else
                        ..._series.map((s) => Container(
                              key: Key('series_item_${s.id}'),
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: AppDecorations.borderRadiusMd,
                                border: Border.all(color: AppColors.border),
                              ),
                              child: ListTile(
                                title: Text('${s.documentType} · ${s.prefix}'),
                                subtitle: Text('Next: ${s.nextNumber.toString().padLeft(s.padding, '0')} · Padding ${s.padding}'),
                                trailing: Switch(
                                  key: Key('series_active_switch_${s.id}'),
                                  value: s.active,
                                  onChanged: (_) => _toggleSeriesActive(s),
                                ),
                              ),
                            )),
                    ],
                  ],
                ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class _NewYearResult {
  final String label;
  final DateTime startDate;
  final DateTime endDate;

  _NewYearResult({required this.label, required this.startDate, required this.endDate});
}

class _NewFinancialYearDialog extends StatefulWidget {
  const _NewFinancialYearDialog();

  @override
  State<_NewFinancialYearDialog> createState() => _NewFinancialYearDialogState();
}

class _NewFinancialYearDialogState extends State<_NewFinancialYearDialog> {
  final _labelController = TextEditingController();
  DateTime? _startDate;
  DateTime? _endDate;
  String? _error;

  static final _dateFormat = DateFormat('dd MMM yyyy');

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool isEnd}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (isEnd ? _endDate : _startDate) ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(() {
      if (isEnd) {
        _endDate = picked;
      } else {
        _startDate = picked;
      }
    });
  }

  void _submit() {
    if (_labelController.text.trim().isEmpty) {
      setState(() => _error = 'Label is required');
      return;
    }
    if (_startDate == null || _endDate == null) {
      setState(() => _error = 'Pick both a start and end date');
      return;
    }
    if (!_endDate!.isAfter(_startDate!)) {
      setState(() => _error = 'End date must be after start date');
      return;
    }
    Navigator.of(context).pop(_NewYearResult(label: _labelController.text.trim(), startDate: _startDate!, endDate: _endDate!));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Open New Financial Year'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('financial_year_label_field'),
            controller: _labelController,
            decoration: const InputDecoration(labelText: 'Label (e.g. FY2627)'),
          ),
          const SizedBox(height: 12),
          ListTile(
            key: const Key('financial_year_start_date_tile'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Start date'),
            subtitle: Text(_startDate == null ? 'Not set' : _dateFormat.format(_startDate!)),
            trailing: const Icon(Icons.calendar_today_outlined, size: 18),
            onTap: () => _pickDate(isEnd: false),
          ),
          ListTile(
            key: const Key('financial_year_end_date_tile'),
            contentPadding: EdgeInsets.zero,
            title: const Text('End date'),
            subtitle: Text(_endDate == null ? 'Not set' : _dateFormat.format(_endDate!)),
            trailing: const Icon(Icons.calendar_today_outlined, size: 18),
            onTap: () => _pickDate(isEnd: true),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('financial_year_submit_button'),
          onPressed: _submit,
          child: const Text('Open Year'),
        ),
      ],
    );
  }
}

class _NewSeriesResult {
  final String documentType;
  final String prefix;
  final int startingNumber;
  final int padding;

  _NewSeriesResult({required this.documentType, required this.prefix, required this.startingNumber, required this.padding});
}

class _NewSeriesDialog extends StatefulWidget {
  const _NewSeriesDialog();

  @override
  State<_NewSeriesDialog> createState() => _NewSeriesDialogState();
}

class _NewSeriesDialogState extends State<_NewSeriesDialog> {
  final _prefixController = TextEditingController(text: '');
  final _startingNumberController = TextEditingController(text: '1');
  final _paddingController = TextEditingController(text: '5');
  String _documentType = 'INVOICE';
  String? _error;

  static const _documentTypes = ['INVOICE', 'CREDIT_NOTE', 'DEBIT_NOTE', 'PO', 'GRN', 'RECEIPT', 'RETURN', 'CONTRA'];

  @override
  void dispose() {
    _prefixController.dispose();
    _startingNumberController.dispose();
    _paddingController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_prefixController.text.trim().isEmpty) {
      setState(() => _error = 'Prefix is required');
      return;
    }
    final startingNumber = int.tryParse(_startingNumberController.text.trim());
    if (startingNumber == null || startingNumber < 1) {
      setState(() => _error = 'Starting number must be at least 1');
      return;
    }
    final padding = int.tryParse(_paddingController.text.trim());
    if (padding == null || padding < 1 || padding > 10) {
      setState(() => _error = 'Padding must be between 1 and 10');
      return;
    }
    Navigator.of(context).pop(_NewSeriesResult(
      documentType: _documentType,
      prefix: _prefixController.text.trim(),
      startingNumber: startingNumber,
      padding: padding,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Document Series'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            key: const Key('new_series_document_type_dropdown'),
            initialValue: _documentType,
            decoration: const InputDecoration(labelText: 'Document Type'),
            items: _documentTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
            onChanged: (v) => setState(() => _documentType = v ?? 'INVOICE'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('new_series_prefix_field'),
            controller: _prefixController,
            decoration: const InputDecoration(labelText: 'Prefix (e.g. INV-2627-)'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('new_series_starting_number_field'),
            controller: _startingNumberController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Starting number'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('new_series_padding_field'),
            controller: _paddingController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Padding (digits, e.g. 5 → 00001)'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('new_series_submit_button'),
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
