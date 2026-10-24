import 'package:flutter/material.dart';

import '../app_update_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_decorations.dart';
import '../theme/app_typography.dart';

/// Shown when AppUpdateService.checkForUpdate finds a newer release —
/// version/changelog plus "Update Now" (downloads with a progress bar,
/// then hands off to Android's installer) or "Later" (remembers this
/// version was dismissed, via AppUpdateService.dismiss).
class UpdatePromptDialog extends StatefulWidget {
  final UpdateInfo info;
  final AppUpdateService service;

  const UpdatePromptDialog({super.key, required this.info, required this.service});

  @override
  State<UpdatePromptDialog> createState() => _UpdatePromptDialogState();
}

class _UpdatePromptDialogState extends State<UpdatePromptDialog> {
  bool _downloading = false;
  double _progress = 0;
  String? _error;

  Future<void> _updateNow() async {
    setState(() {
      _downloading = true;
      _error = null;
    });
    try {
      await widget.service.downloadAndInstall(widget.info, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      // Android's own installer screen takes over from here — this dialog
      // can safely close once that hand-off succeeds.
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = 'Could not install the update. Please try again.';
      });
    }
  }

  Future<void> _later() async {
    await widget.service.dismiss(widget.info);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.system_update_rounded, color: AppColors.primary, size: 32),
      title: Text('Update available: v${widget.info.latestVersionName}', style: AppTypography.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.info.releaseNotes.isNotEmpty) Text(widget.info.releaseNotes, style: AppTypography.bodySecondary),
          if (_downloading) ...[
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: AppDecorations.borderRadiusFull,
              child: LinearProgressIndicator(value: _progress > 0 ? _progress : null, minHeight: 8, backgroundColor: AppColors.surfaceTertiary),
            ),
            const SizedBox(height: 6),
            Text('${(_progress * 100).toStringAsFixed(0)}%', style: AppTypography.caption.copyWith(color: AppColors.textTertiary)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
          ],
        ],
      ),
      actions: _downloading
          ? null
          : [
              TextButton(key: const Key('update_later_button'), onPressed: _later, child: const Text('Later')),
              FilledButton(key: const Key('update_now_button'), onPressed: _updateNow, child: const Text('Update Now')),
            ],
    );
  }
}
