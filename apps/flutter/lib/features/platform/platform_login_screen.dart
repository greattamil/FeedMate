import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/branding_provider.dart';
import '../../core/responsive.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import 'platform_api_client.dart';
import 'platform_shell.dart';

/// The super-admin login — entirely separate from the tenant login screen.
/// A platform admin has no tenant/device at all (see
/// services/api/internal/domain/platformadmin's doc comment), so this
/// posts straight to /api/v1/platform/auth/login with just username and
/// password, never a device_uuid.
class PlatformLoginScreen extends StatefulWidget {
  const PlatformLoginScreen({super.key});

  @override
  State<PlatformLoginScreen> createState() => _PlatformLoginScreenState();
}

class _PlatformLoginScreenState extends State<PlatformLoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final client = context.read<PlatformApiClient>();
      await client.login(_usernameController.text.trim(), _passwordController.text);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const PlatformShell()),
      );
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final branding = context.watch<BrandingProvider>();
    final isDesktop = context.isDesktop;

    final form = _buildForm(branding, embedded: isDesktop);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: isDesktop
          ? Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: const BoxDecoration(gradient: AppColors.gradientHeroMesh),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(48),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15), borderRadius: AppDecorations.borderRadiusLg),
                              child: const Icon(Icons.admin_panel_settings_rounded, size: 40, color: Colors.white),
                            ),
                            const SizedBox(height: 28),
                            const Text('Platform Control Plane', style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -0.8)),
                            const SizedBox(height: 12),
                            Text(
                              'Manage every ${branding.appName} tenant — provisioning, plans, whitelabel branding, feature flags, and audit visibility, all from one place.',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 15, height: 1.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(48), child: form)),
                ),
              ],
            )
          : Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: form)),
    );
  }

  Widget _buildForm(BrandingProvider branding, {required bool embedded}) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!embedded) ...[
          Center(
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(gradient: AppColors.gradientIndigo, shape: BoxShape.circle, boxShadow: AppDecorations.cardShadow),
              child: const Icon(Icons.admin_panel_settings_rounded, size: 40, color: Colors.white),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Platform Admin',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            '${branding.appName} — Super Admin Control Plane',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 28),
        ] else ...[
          const Text('Sign in', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: AppColors.textPrimary)),
          const SizedBox(height: 6),
          const Text('Enter your platform admin credentials', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          const SizedBox(height: 28),
        ],
        TextField(
          key: const Key('platform_username_field'),
          controller: _usernameController,
          decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.person_outline_rounded)),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('platform_password_field'),
          controller: _passwordController,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline_rounded)),
          onSubmitted: (_) => _submitting ? null : _submit(),
        ),
        const SizedBox(height: 20),
        if (_error != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(color: AppColors.dangerContainer, borderRadius: AppDecorations.borderRadiusMd),
            child: Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        FilledButton(
          key: const Key('platform_login_button'),
          style: FilledButton.styleFrom(backgroundColor: AppColors.secondary, padding: const EdgeInsets.symmetric(vertical: 16)),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Log In', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ),
      ],
    );

    if (embedded) {
      return ConstrainedBox(constraints: const BoxConstraints(maxWidth: 380), child: content);
    }
    return Container(
      padding: const EdgeInsets.all(24),
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: AppDecorations.card(),
      child: content,
    );
  }
}
