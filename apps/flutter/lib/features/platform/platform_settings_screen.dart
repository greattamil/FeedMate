import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/branding_provider.dart';
import 'platform_api.dart';
import 'platform_api_client.dart';

/// Edits the one global row every tenant's own branding falls back to when
/// they haven't set their own override — the platform-wide default app
/// name/tagline/logo/color that used to be hardcoded directly into the
/// Flutter source (login screen, dashboard header, app shell) as literal
/// strings like "FeedMate" / "Andipatti Animal Feed System". This screen is
/// now the single place that value is ever changed.
class PlatformSettingsScreen extends StatefulWidget {
  const PlatformSettingsScreen({super.key});

  @override
  State<PlatformSettingsScreen> createState() => _PlatformSettingsScreenState();
}

class _PlatformSettingsScreenState extends State<PlatformSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _appNameController = TextEditingController();
  final _taglineController = TextEditingController();
  final _logoController = TextEditingController();
  final _colorController = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _appNameController.dispose();
    _taglineController.dispose();
    _logoController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      final settings = await api.getPlatformSettings();
      if (!mounted) return;
      setState(() {
        _appNameController.text = settings.appName;
        _taglineController.text = settings.appTagline;
        _logoController.text = settings.logoUrl ?? '';
        _colorController.text = settings.primaryColor ?? '';
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

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      await api.updatePlatformSettings(
        appName: _appNameController.text.trim(),
        appTagline: _taglineController.text.trim(),
        logoUrl: _logoController.text.trim(),
        primaryColor: _colorController.text.trim(),
      );
      if (!mounted) return;
      // Every screen watching BrandingProvider (login, dashboard, shell)
      // picks up the new default immediately — no app restart needed for
      // whoever isn't currently overridden by their own tenant branding.
      await context.read<BrandingProvider>().refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Platform default branding updated')),
      );
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _dec(String label) => InputDecoration(labelText: label, labelStyle: const TextStyle(color: Color(0xFF94A3B8)));

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(color: Colors.white);
    if (_loading) return const Center(child: CircularProgressIndicator(color: Colors.white));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Platform Default Branding',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 4),
            const Text(
              'Shown wherever a tenant has not set their own whitelabel override — including the login screen, which by definition has no tenant context yet.',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
            ),
            const SizedBox(height: 20),
            TextFormField(
              key: const Key('platform_settings_app_name_field'),
              controller: _appNameController,
              style: textStyle,
              decoration: _dec('App Name'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('platform_settings_tagline_field'),
              controller: _taglineController,
              style: textStyle,
              decoration: _dec('Tagline'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('platform_settings_logo_field'),
              controller: _logoController,
              style: textStyle,
              decoration: _dec('Logo URL (optional)'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('platform_settings_color_field'),
              controller: _colorController,
              style: textStyle,
              decoration: _dec('Primary Color (#RRGGBB, optional)'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: const Color(0xFF7F1D1D), borderRadius: BorderRadius.circular(10)),
                child: Text(_error!, style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('platform_settings_save_button'),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
