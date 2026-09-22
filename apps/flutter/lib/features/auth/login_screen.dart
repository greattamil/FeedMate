import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../shell/app_shell.dart';
import 'pair_device_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;

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
        MaterialPageRoute(builder: (_) => const AppShell()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSession>();
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Brand Header Badge
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: AppColors.gradientEmerald,
                    shape: BoxShape.circle,
                    boxShadow: AppDecorations.cardShadow,
                  ),
                  child: const Icon(Icons.storefront_rounded, size: 44, color: Colors.white),
                ),
                const SizedBox(height: 20),
                const Text(
                  'FeedMate POS',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: AppColors.textPrimary, letterSpacing: -0.5),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Andipatti Animal Feed System · Store Login',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),

                // Main Form Card
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: AppDecorations.card(color: AppColors.surface),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Shop Login',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                        textAlign: TextAlign.start,
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _usernameController,
                        key: const Key('username_field'),
                        decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.person_outline_rounded, size: 20),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _passwordController,
                        key: const Key('password_field'),
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(Icons.lock_outline_rounded, size: 20),
                        ),
                        onSubmitted: (_) => _submitting ? null : _submit(),
                      ),
                      const SizedBox(height: 20),
                      if (session.lastError != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: AppColors.dangerContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            session.lastError!,
                            style: const TextStyle(color: AppColors.danger, fontSize: 13, fontWeight: FontWeight.w600),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      FilledButton(
                        key: const Key('login_button'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Log In', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),
                TextButton.icon(
                  key: const Key('register_device_link'),
                  icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                  label: const Text('Register this device with a pairing code', style: TextStyle(fontWeight: FontWeight.w600)),
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
            ),
          ),
        ),
      ),
    );
  }
}

