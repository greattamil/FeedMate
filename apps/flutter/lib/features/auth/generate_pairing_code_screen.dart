import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/device_api.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';

/// Lets an owner/manager (device.manage) generate a short-lived pairing code
/// to hand to whoever is setting up a new counter tablet. The code is a
/// one-time bearer credential for exactly one device registration — shown
/// once, with a live countdown, and never persisted beyond this screen.
class GeneratePairingCodeScreen extends StatefulWidget {
  const GeneratePairingCodeScreen({super.key});

  @override
  State<GeneratePairingCodeScreen> createState() => _GeneratePairingCodeScreenState();
}

class _GeneratePairingCodeScreenState extends State<GeneratePairingCodeScreen> {
  String? _code;
  DateTime? _expiresAt;
  Duration _remaining = Duration.zero;
  Timer? _ticker;
  bool _generating = false;
  String? _error;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final api = DeviceApi(context.read<ApiClient>());
      final result = await api.generatePairingCode();
      if (!mounted) return;
      setState(() {
        _code = result.code;
        _expiresAt = result.expiresAt;
        _generating = false;
      });
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      _tick();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _generating = false;
      });
    }
  }

  void _tick() {
    if (_expiresAt == null) return;
    final remaining = _expiresAt!.difference(DateTime.now());
    if (!mounted) return;
    setState(() => _remaining = remaining.isNegative ? Duration.zero : remaining);
    if (remaining.isNegative) {
      _ticker?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final expired = _expiresAt != null && _remaining == Duration.zero;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Pair a New Device')),
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
                            color: AppColors.secondaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.qr_code_scanner_rounded, color: AppColors.secondary, size: 36),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Generate Pairing Code',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'On the new device, open the app and tap "Register this device with a pairing code", then enter the code below.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
                      ),
                      const SizedBox(height: 24),
                      if (_code != null) ...[
                        InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: _code!));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Code copied to clipboard'), duration: Duration(seconds: 1)),
                            );
                          },
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            decoration: BoxDecoration(
                              color: expired ? AppColors.dangerContainer : AppColors.successContainer,
                              border: Border.all(color: expired ? AppColors.dangerLight : AppColors.success, width: 1.5),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  _code!,
                                  key: const Key('pairing_code_display'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 36,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 6,
                                    color: expired ? AppColors.danger : AppColors.success,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Tap to copy',
                                  style: TextStyle(fontSize: 11, color: (expired ? AppColors.danger : AppColors.success).withAlpha(180)),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: expired ? AppColors.dangerContainer : AppColors.surfaceSecondary,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            expired
                                ? 'Expired — generate a new code'
                                : 'Expires in ${_remaining.inMinutes}:${(_remaining.inSeconds % 60).toString().padLeft(2, '0')}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: expired ? AppColors.danger : AppColors.textSecondary,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
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
                      FilledButton.icon(
                        key: const Key('generate_code_button'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _generating ? null : _generate,
                        icon: _generating
                            ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.refresh_rounded, size: 20),
                        label: Text(
                          _code == null ? 'Generate Pairing Code' : 'Generate New Code',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
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

