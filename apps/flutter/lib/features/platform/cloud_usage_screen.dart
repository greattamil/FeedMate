import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../../core/widgets/alert_banner.dart';
import 'platform_api.dart';
import 'platform_api_client.dart';

/// Platform-admin "Cloud Usage" dashboard: live usage vs. free-tier ceiling
/// for every external provider this app runs on (Google Cloud Run,
/// Cloudflare, Aiven Postgres), plus any open threshold-breach alerts.
/// Every number shown here was fetched from the provider's own API at the
/// last scheduled poll (internal/domain/cloudusage) — never hardcoded.
/// Google Cloud's ceilings are the one exception flagged in the UI: Google
/// has no API for its own free-tier limits, so that number is a published
/// constant rather than a live reading (the usage side is still live).
class CloudUsageScreen extends StatefulWidget {
  const CloudUsageScreen({super.key});

  @override
  State<CloudUsageScreen> createState() => _CloudUsageScreenState();
}

class _CloudUsageScreenState extends State<CloudUsageScreen> {
  List<CloudUsageMetric> _metrics = [];
  List<CloudUsageAlert> _alerts = [];
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  static final _timeFormat = DateFormat('d MMM, HH:mm');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      final metrics = await api.getCloudUsage();
      final alerts = await api.getCloudUsageAlerts();
      if (!mounted) return;
      setState(() {
        _metrics = metrics;
        _alerts = alerts;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _refreshNow() async {
    setState(() => _refreshing = true);
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      await api.refreshCloudUsage();
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Refresh failed: ${e.message}')));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, style: const TextStyle(color: AppColors.danger)),
        ),
      );
    }

    final byProvider = <String, List<CloudUsageMetric>>{};
    for (final m in _metrics) {
      byProvider.putIfAbsent(m.provider, () => []).add(m);
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('cloud_usage_list'),
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(child: Text('Cloud Usage', style: AppTypography.headline)),
              FilledButton.icon(
                key: const Key('cloud_usage_refresh_button'),
                onPressed: _refreshing ? null : _refreshNow,
                icon: _refreshing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh_rounded),
                label: Text(_refreshing ? 'Refreshing...' : 'Refresh now'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final alert in _alerts)
            AlertBanner(message: alert.message, critical: alert.severity == 'critical'),
          if (_alerts.isNotEmpty) const SizedBox(height: 8),
          if (_metrics.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  'No usage data yet — it appears after the first poll runs (hourly), or tap "Refresh now".',
                  textAlign: TextAlign.center,
                  style: AppTypography.bodySecondary,
                ),
              ),
            ),
          if (byProvider.containsKey('gcp')) _providerSection('Google Cloud', byProvider['gcp']!, showLiveLimitCaveat: true),
          if (byProvider.containsKey('cloudflare')) _providerSection('Cloudflare', byProvider['cloudflare']!),
          if (byProvider.containsKey('aiven')) _providerSection('Aiven Postgres', byProvider['aiven']!),
        ],
      ),
    );
  }

  Widget _providerSection(String title, List<CloudUsageMetric> metrics, {bool showLiveLimitCaveat = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: AppDecorations.card(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: AppTypography.title),
            if (showLiveLimitCaveat)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Usage is live; the free-tier limit is a published Google constant (no live API for it exists).',
                  style: AppTypography.caption.copyWith(color: AppColors.textTertiary),
                ),
              ),
            const SizedBox(height: 14),
            for (final m in metrics) _metricRow(m),
          ],
        ),
      ),
    );
  }

  Widget _metricRow(CloudUsageMetric m) {
    final pct = m.pctUsed;
    final color = pct == null
        ? AppColors.textSecondary
        : pct >= 90
            ? AppColors.danger
            : pct >= 70
                ? AppColors.warning
                : AppColors.success;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(m.label, style: AppTypography.body.copyWith(fontWeight: FontWeight.bold))),
              Text(
                m.limitValue != null
                    ? '${_formatValue(m.usedValue, m.unit)} / ${_formatValue(m.limitValue!, m.unit)}'
                    : _formatValue(m.usedValue, m.unit),
                style: AppTypography.bodySecondary,
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (pct != null)
            ClipRRect(
              borderRadius: AppDecorations.borderRadiusFull,
              child: LinearProgressIndicator(
                value: (pct / 100).clamp(0, 1).toDouble(),
                minHeight: 8,
                backgroundColor: AppColors.surfaceTertiary,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            pct != null ? '${pct.toStringAsFixed(1)}% used · as of ${_timeFormat.format(m.capturedAt.toLocal())}' : 'as of ${_timeFormat.format(m.capturedAt.toLocal())}',
            style: AppTypography.caption.copyWith(color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }

  String _formatValue(double value, String unit) {
    switch (unit) {
      case 'bytes':
        if (value >= 1024 * 1024 * 1024) return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
        if (value >= 1024 * 1024) return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
        return '${(value / 1024).toStringAsFixed(1)} KB';
      case 'seconds':
        return '${value.toStringAsFixed(0)} sec';
      default:
        return value >= 1000 ? NumberFormat.decimalPattern().format(value) : value.toStringAsFixed(0);
    }
  }
}
