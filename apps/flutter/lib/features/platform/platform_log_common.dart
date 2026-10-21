import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';

/// Small building blocks shared by [PlatformErrorLogScreen] and
/// [PlatformAuditLogScreen]'s detail views: pretty-printed JSON blocks,
/// copy-to-clipboard rows, and a couple of color-coding helpers — factored
/// out so both screens' detail dialogs look and behave identically.
abstract final class PlatformLogCommon {
  static final _jsonEncoder = JsonEncoder.withIndent('  ');

  /// Pretty-prints a raw JSON object for display. Falls back to the plain
  /// map if, for whatever reason, it can't be re-encoded.
  static String prettyJson(Map<String, dynamic> json) {
    try {
      return _jsonEncoder.convert(json);
    } catch (_) {
      return json.toString();
    }
  }

  /// A labelled, scrollable, selectable monospace block — used for
  /// pretty-printed JSON and stack traces. [onCopy] adds a copy button in
  /// the header when non-null.
  static Widget monoBlock({
    required Key key,
    required String label,
    required String text,
    VoidCallback? onCopy,
    Key? copyButtonKey,
    int maxLines = 20,
  }) {
    return Container(
      key: key,
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: AppDecorations.borderRadiusSm,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: AppTypography.caption.copyWith(fontWeight: FontWeight.bold)),
                if (onCopy != null)
                  IconButton(
                    key: copyButtonKey,
                    icon: const Icon(Icons.copy_rounded, size: 16, color: AppColors.textTertiary),
                    tooltip: 'Copy',
                    onPressed: onCopy,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxLines * 18.0 + 24),
            child: Scrollbar(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: SelectableText(
                  text,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: AppColors.textPrimary, height: 1.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Copies [value] to the clipboard and shows a short confirmation snack
  /// bar — mirrors the pairing-code/request-id copy pattern used elsewhere
  /// in the platform admin area (e.g. tenant_devices_tab.dart).
  static void copyToClipboard(BuildContext context, String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied'), duration: const Duration(seconds: 1)));
  }

  /// A simple label/value row for detail views.
  static Widget kv(String label, String value, {Key? key}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 130, child: Text(label, style: AppTypography.caption)),
          Expanded(child: SelectableText(value, style: AppTypography.body)),
        ],
      ),
    );
  }

  /// A label/value row with a trailing copy button, for IDs worth
  /// correlating with server-side logs (request_id, entity_id, etc).
  static Widget kvCopyable(BuildContext context, String label, String value, {required Key key}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 130, child: Text(label, style: AppTypography.caption)),
          Expanded(child: SelectableText(value, style: AppTypography.body)),
          IconButton(
            key: key,
            icon: const Icon(Icons.copy_rounded, size: 14, color: AppColors.textTertiary),
            tooltip: 'Copy',
            visualDensity: VisualDensity.compact,
            onPressed: () => copyToClipboard(context, value, label),
          ),
        ],
      ),
    );
  }

  /// 2xx → success, 4xx → warning/amber, 5xx → danger, else neutral.
  static Color statusColor(int statusCode) {
    if (statusCode >= 500) return AppColors.danger;
    if (statusCode >= 400) return AppColors.warning;
    if (statusCode >= 200 && statusCode < 300) return AppColors.success;
    return AppColors.textSecondary;
  }

  static Color onStatusContainer(int statusCode) {
    if (statusCode >= 500) return AppColors.onDangerContainer;
    if (statusCode >= 400) return AppColors.onWarningContainer;
    if (statusCode >= 200 && statusCode < 300) return AppColors.onSuccessContainer;
    return AppColors.textSecondary;
  }

  static Color statusContainerColor(int statusCode) {
    if (statusCode >= 500) return AppColors.dangerContainer;
    if (statusCode >= 400) return AppColors.warningContainer;
    if (statusCode >= 200 && statusCode < 300) return AppColors.successContainer;
    return AppColors.surfaceSecondary;
  }

  /// Color-codes an audit action by its verb suffix: destructive/closing
  /// actions in danger, creation actions in success, everything else
  /// neutral — same palette tenant_devices_tab.dart uses for device status.
  static Color actionColor(String actionCode) {
    final code = actionCode.toUpperCase();
    if (code.endsWith('_REVOKED') || code.endsWith('_SUSPENDED') || code.endsWith('_CLOSED') || code.endsWith('_DELETED') || code.endsWith('_DISABLED')) {
      return AppColors.danger;
    }
    if (code.endsWith('_CREATED') || code.endsWith('_REGISTERED') || code.endsWith('_OPENED') || code.endsWith('_ACTIVATED')) {
      return AppColors.success;
    }
    return AppColors.secondary;
  }

  /// "INVOICE_FINALIZED" -> "Invoice Finalized" for readable display while
  /// the raw action_code remains available (e.g. for the search filter).
  static String formatActionCode(String actionCode) {
    return actionCode
        .split('_')
        .where((w) => w.isNotEmpty)
        .map((w) => '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
        .join(' ');
  }
}
