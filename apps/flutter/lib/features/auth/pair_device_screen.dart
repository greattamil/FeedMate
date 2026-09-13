import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/device_api.dart';
import '../../core/secure_storage.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';

/// Lets a brand-new, unauthenticated device register itself using a
/// short-lived pairing code an owner/manager generated on an already-paired
/// device (see GeneratePairingCodeScreen). This is the self-service
/// counterpart to an administrator manually inserting a devices row.
class PairDeviceScreen extends StatefulWidget {
  const PairDeviceScreen({super.key});

  @override
  State<PairDeviceScreen> createState() => _PairDeviceScreenState();
}

class _PairDeviceScreenState extends State<PairDeviceScreen> {
  final _codeController = TextEditingController();
  final _nameController = TextEditingController(text: 'Counter Tablet');
  bool _submitting = false;
  String? _error;

  Future<void> _register() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    final storage = context.read<SecureStorage>();
    final api = DeviceApi(context.read<ApiClient>());
    try {
      final deviceUuid = await storage.getOrCreateDeviceUuid();
      await api.registerDevice(
        code: _codeController.text.trim(),
        deviceUuid: deviceUuid,
        displayName: _nameController.text.trim().isEmpty ? 'Unnamed Device' : _nameController.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Register This Device')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: AppDecorations.card(color: AppColors.surface),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: const BoxDecoration(
                            color: AppColors.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.phonelink_setup_rounded, color: AppColors.primary, size: 36),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Device Registration',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Ask your shop owner or manager to generate a pairing code from their device, then enter it below.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        key: const Key('pairing_code_field'),
                        controller: _codeController,
                        decoration: const InputDecoration(
                          labelText: 'Pairing Code',
                          hintText: 'e.g. 7K89M',
                          prefixIcon: Icon(Icons.pin_rounded, size: 20),
                        ),
                        textCapitalization: TextCapitalization.characters,
                        autofocus: true,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('device_name_field'),
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Name for this device',
                          prefixIcon: Icon(Icons.tablet_android_rounded, size: 20),
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (_error != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: AppColors.dangerContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: AppColors.danger, fontSize: 13, fontWeight: FontWeight.w600),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      FilledButton(
                        key: const Key('register_device_button'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _submitting ? null : _register,
                        child: _submitting
                            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Text('Register Device', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

