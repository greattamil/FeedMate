import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/device_api.dart';

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
      appBar: AppBar(title: const Text('Pair a New Device')),
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
                  'On the new device, open the app and tap "Register this device with a pairing code", then enter the code below.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (_code != null) ...[
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: _code!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Code copied'), duration: Duration(seconds: 1)),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      decoration: BoxDecoration(
                        border: Border.all(color: expired ? Colors.red : Colors.green),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _code!,
                        key: const Key('pairing_code_display'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 4,
                          color: expired ? Colors.red : null,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    expired
                        ? 'Expired — generate a new code'
                        : 'Expires in ${_remaining.inMinutes}:${(_remaining.inSeconds % 60).toString().padLeft(2, '0')}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: expired ? Colors.red : Colors.grey),
                  ),
                  const SizedBox(height: 24),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                  ),
                FilledButton(
                  key: const Key('generate_code_button'),
                  onPressed: _generating ? null : _generate,
                  child: _generating
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_code == null ? 'Generate Pairing Code' : 'Generate New Code'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
