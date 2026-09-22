import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'location_admin_api.dart';

/// The dedicated location/warehouse management screen — previously the
/// only way to add a receiving location at all was a developer inserting
/// a row directly into inventory_locations, which is exactly why a
/// brand-new tenant with zero locations had no way to receive stock via
/// GRN. A shop owner creates one location per physical shop counter,
/// godown, transit point, etc. here, then picks from them wherever a
/// location is needed (GRN, POS, stock counts).
class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key});

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  List<LocationDetail> _locations = [];
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
      final api = LocationAdminApi(context.read<ApiClient>());
      final locations = await api.listAll();
      if (!mounted) return;
      setState(() {
        _locations = locations;
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

  Future<void> _openForm({LocationDetail? existing}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LocationForm(existing: existing),
    );
    if (saved == true) await _load();
  }

  Future<void> _toggleActive(LocationDetail location) async {
    try {
      final api = LocationAdminApi(context.read<ApiClient>());
      await api.setActive(location.id, !location.active);
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Locations & Warehouses', style: AppTypography.headline)),
      floatingActionButton: FloatingActionButton(
        heroTag: null,
        key: const Key('location_add_fab'),
        backgroundColor: AppColors.primary,
        onPressed: () => _openForm(),
        child: const Icon(Icons.add_rounded),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: Colors.red))))
              : _locations.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No locations yet.\nAdd at least one — a shop counter or godown — before you can receive stock via GRN.',
                          textAlign: TextAlign.center,
                          style: AppTypography.bodySecondary,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _locations.length,
                      itemBuilder: (context, index) {
                        final l = _locations[index];
                        return Opacity(
                          opacity: l.active ? 1 : 0.55,
                          child: Container(
                            key: Key('location_item_${l.id}'),
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: AppDecorations.borderRadiusMd,
                              border: Border.all(color: AppColors.border),
                              boxShadow: AppDecorations.cardShadow,
                            ),
                            child: ListTile(
                              onTap: () => _openForm(existing: l),
                              leading: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceSecondary,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.warehouse_rounded, color: AppColors.primary, size: 18),
                              ),
                              title: Text('${l.name} (${l.code})', style: AppTypography.title),
                              subtitle: Text('${locationTypeLabel(l.type)}${l.active ? '' : ' · Inactive'}'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    key: Key('location_edit_${l.id}'),
                                    icon: const Icon(Icons.edit_outlined, color: AppColors.textSecondary),
                                    tooltip: 'Edit',
                                    onPressed: () => _openForm(existing: l),
                                  ),
                                  Switch(
                                    key: Key('location_active_switch_${l.id}'),
                                    value: l.active,
                                    onChanged: (_) => _toggleActive(l),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

class _LocationForm extends StatefulWidget {
  final LocationDetail? existing;
  const _LocationForm({this.existing});

  @override
  State<_LocationForm> createState() => _LocationFormState();
}

class _LocationFormState extends State<_LocationForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _codeController;
  late final TextEditingController _nameController;
  late String _type;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _codeController = TextEditingController(text: e?.code ?? '');
    _nameController = TextEditingController(text: e?.name ?? '');
    _type = e?.type ?? 'SHOP';
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = LocationAdminApi(context.read<ApiClient>());
      if (_isEdit) {
        await api.update(widget.existing!.id, name: _nameController.text.trim(), type: _type);
      } else {
        await api.create(code: _codeController.text.trim(), name: _nameController.text.trim(), type: _type);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        expand: false,
        builder: (context, scrollController) {
          return Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Form(
              key: _formKey,
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(20),
                children: [
                  Text(_isEdit ? 'Edit Location' : 'Add Location', style: AppTypography.headline),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('location_code_field'),
                    controller: _codeController,
                    enabled: !_isEdit,
                    decoration: const InputDecoration(labelText: 'Code (e.g. MAIN)'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Code is required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('location_name_field'),
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Name'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Name is required' : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const Key('location_type_field'),
                    initialValue: _type,
                    decoration: const InputDecoration(labelText: 'Type'),
                    items: locationTypes.map((t) => DropdownMenuItem(value: t, child: Text(locationTypeLabel(t)))).toList(),
                    onChanged: (v) => setState(() => _type = v ?? _type),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const Key('location_save_button'),
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? 'Saving…' : (_isEdit ? 'Save Changes' : 'Create Location')),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
