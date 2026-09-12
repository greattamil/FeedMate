import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/auth_session.dart';
import '../../core/secure_storage.dart';
import '../pos/product_search_screen.dart';
import 'pair_device_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController(text: 'owner');
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _deviceUuid;

  @override
  void initState() {
    super.initState();
    // Support diagnostic (PRD §93: devices must expose their identity for
    // support/troubleshooting). This is also the only way an owner can tell
    // support/an admin which device_uuid to register — there is no
    // self-service device registration flow yet (see
    // docs/IMPLEMENTATION_STATUS.md), so a new install cannot log in until
    // whoever provisions tenants adds this UUID as a device for the tenant.
    context.read<SecureStorage>().getOrCreateDeviceUuid().then((uuid) {
      if (mounted) setState(() => _deviceUuid = uuid);
    });
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    final session = context.read<AuthSession>();
    final success = await session.login(
      username: _usernameController.text.trim(),
      password: _passwordController.text,
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (success) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ProductSearchScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSession>();
    return Scaffold(
      appBar: AppBar(title: const Text('Andipatti Animal Feed System')),
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
                  'Shop Login',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder()),
                  key: const Key('username_field'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                  obscureText: true,
                  key: const Key('password_field'),
                  onSubmitted: (_) => _submitting ? null : _submit(),
                ),
                const SizedBox(height: 20),
                if (session.lastError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      session.lastError!,
                      style: const TextStyle(color: Colors.red),
                      textAlign: TextAlign.center,
                    ),
                  ),
                FilledButton(
                  key: const Key('login_button'),
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          height: 20, width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Log In'),
                ),
                if (_deviceUuid != null) ...[
                  const SizedBox(height: 24),
                  InkWell(
                    key: const Key('device_uuid_row'),
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: _deviceUuid!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Device ID copied'), duration: Duration(seconds: 1)),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.smartphone, size: 14, color: Colors.grey),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Device: $_deviceUuid  (tap to copy)',
                              style: const TextStyle(fontSize: 11, color: Colors.grey),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const Key('register_device_link'),
                    icon: const Icon(Icons.qr_code, size: 16),
                    label: const Text('Register this device with a pairing code'),
                    onPressed: () async {
                      final registered = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(builder: (_) => const PairDeviceScreen()),
                      );
                      if (!mounted) return;
                      final messenger = ScaffoldMessenger.of(context);
                      if (registered == true) {
                        messenger.showSnackBar(
                          const SnackBar(content: Text('Device registered — you can log in now')),
                        );
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
