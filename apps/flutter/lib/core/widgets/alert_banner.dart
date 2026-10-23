import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_decorations.dart';

/// A dismissable-looking inline warning/critical banner, extracted from the
/// pattern repeated in home_dashboard_screen.dart's urgent-alerts card so
/// other screens (the platform admin cloud-usage dashboard) don't have to
/// re-hand-roll the same Container/Row/Icon shape.
class AlertBanner extends StatelessWidget {
  final String message;
  final bool critical;
  final String? actionLabel;
  final VoidCallback? onAction;

  const AlertBanner({
    super.key,
    required this.message,
    this.critical = false,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final color = critical ? AppColors.danger : AppColors.warning;
    final container = critical ? AppColors.dangerContainer : AppColors.warningContainer;
    final onContainer = critical ? AppColors.onDangerContainer : AppColors.onWarningContainer;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: container,
        borderRadius: AppDecorations.borderRadiusSm,
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(critical ? Icons.error_outline : Icons.warning_amber_rounded, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: onContainer)),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}
