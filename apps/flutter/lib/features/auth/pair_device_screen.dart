import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/device_api.dart';
import '../../core/secure_storage.dart';

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
      Navigator.of(context).pop(true); // signal success so the login screen can inform the user
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
      appBar: AppBar(title: const Text('Register This Device')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Ask your shop owner or manager to generate a pairing code from their device, then enter it below.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                TextField(
                  key: const Key('pairing_code_field'),
                  controller: _codeController,
                  decoration: const InputDecoration(labelText: 'Pairing Code', border: OutlineInputBorder()),
                  textCapitalization: TextCapitalization.characters,
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('device_name_field'),
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Name for this device', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 20),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                  ),
                FilledButton(
                  key: const Key('register_device_button'),
                  onPressed: _submitting ? null : _register,
                  child: _submitting
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Register Device'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
