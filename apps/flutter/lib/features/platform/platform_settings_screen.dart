import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/branding_provider.dart';
import '../../core/responsive.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
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
    for (final c in [_appNameController, _taglineController, _colorController]) {
      c.addListener(() => setState(() {}));
    }
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

  Color? get _previewColor {
    final hex = _colorController.text.trim().replaceFirst('#', '');
    final value = int.tryParse(hex, radix: 16);
    if (value == null || hex.length != 6) return null;
    return Color(0xFF000000 | value);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));

    final form = _buildFormCard();
    final preview = _buildPreviewCard();

    return SingleChildScrollView(
      padding: EdgeInsets.all(context.responsive(mobile: 16.0, desktop: 24.0)),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ResponsiveBreakpoints.maxContentWidth),
          child: context.isDesktop
              ? IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 3, child: form),
                      const SizedBox(width: 20),
                      Expanded(flex: 2, child: preview),
                    ],
                  ),
                )
              : Column(children: [form, const SizedBox(height: 20), preview]),
        ),
      ),
    );
  }

  Widget _buildFormCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: AppDecorations.card(),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: AppColors.accentContainer, borderRadius: AppDecorations.borderRadiusSm),
                  child: const Icon(Icons.palette_outlined, color: AppColors.accent, size: 20),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Platform Default Branding', style: AppTypography.title),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Shown wherever a tenant has not set their own whitelabel override — including the login screen, which by definition has no tenant context yet.',
              style: AppTypography.caption,
            ),
            const SizedBox(height: 20),
            TextFormField(
              key: const Key('platform_settings_app_name_field'),
              controller: _appNameController,
              decoration: const InputDecoration(labelText: 'App Name'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('platform_settings_tagline_field'),
              controller: _taglineController,
              decoration: const InputDecoration(labelText: 'Tagline'),
            ),
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('platform_settings_logo_field'),
              controller: _logoController,
              decoration: const InputDecoration(labelText: 'Logo URL (optional)'),
            ),
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('platform_settings_color_field'),
              controller: _colorController,
              decoration: const InputDecoration(labelText: 'Primary Color (#RRGGBB, optional)'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.dangerContainer, borderRadius: AppDecorations.borderRadiusMd),
                child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer, fontSize: 13)),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('platform_settings_save_button'),
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary, padding: const EdgeInsets.symmetric(vertical: 14)),
              child: Text(_saving ? 'Saving…' : 'Save Changes', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewCard() {
    final color = _previewColor ?? AppColors.primary;
    final appName = _appNameController.text.trim().isEmpty ? 'FeedMate' : _appNameController.text.trim();
    final tagline = _taglineController.text.trim();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: AppDecorations.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Live Preview', style: AppTypography.title),
          const SizedBox(height: 4),
          const Text('How the login screen looks with these values.', style: AppTypography.caption),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
            decoration: BoxDecoration(color: AppColors.background, borderRadius: AppDecorations.borderRadiusMd, border: Border.all(color: AppColors.border)),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  child: const Icon(Icons.storefront_rounded, size: 28, color: Colors.white),
                ),
                const SizedBox(height: 14),
                Text(appName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: AppColors.textPrimary), textAlign: TextAlign.center),
                if (tagline.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(tagline, style: AppTypography.caption, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 18),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(color: color, borderRadius: AppDecorations.borderRadiusSm),
                  child: const Text('Log In', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
