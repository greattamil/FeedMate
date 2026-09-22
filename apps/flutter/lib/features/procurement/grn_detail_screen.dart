import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'grn_history_api.dart';
import '../../core/number_format.dart';

/// Read-only detail view of one posted GRN: what was received, from whom,
/// and at what cost per line. A posted GRN is never editable from here.
class GrnDetailScreen extends StatefulWidget {
  final String grnId;
  const GrnDetailScreen({super.key, required this.grnId});

  @override
  State<GrnDetailScreen> createState() => _GrnDetailScreenState();
}

class _GrnDetailScreenState extends State<GrnDetailScreen> {
  GRNDetail? _detail;
  bool _loading = true;
  String? _error;

  static final _dateFormat = DateFormat('dd MMM yyyy, h:mm a');

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
      final api = GRNHistoryApi(context.read<ApiClient>());
      final detail = await api.getDetail(widget.grnId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
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

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(detail?.grnNumber ?? 'GRN', style: AppTypography.headline)),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: Colors.red))))
              : detail == null
                  ? const SizedBox.shrink()
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        // Hero Summary Card
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: AppDecorations.borderRadiusLg,
                            border: Border.all(color: AppColors.border),
                            boxShadow: AppDecorations.cardShadow,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      gradient: AppColors.gradientTealCyan,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Icon(Icons.receipt_long_rounded, color: Colors.white, size: 22),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          detail.grnNumber,
                                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                                        ),
                                        if (detail.postedAt != null)
                                          Text(
                                            _dateFormat.format(detail.postedAt!.toLocal()),
                                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              const Divider(height: 1),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  const Icon(Icons.business_rounded, size: 16, color: AppColors.warning),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Supplier: ${detail.supplierName}',
                                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ],
                              ),
                              if (detail.supplierDocumentNo != null) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    const Icon(Icons.description_outlined, size: 16, color: AppColors.textSecondary),
                                    const SizedBox(width: 8),
                                    Text('Supplier doc: ${detail.supplierDocumentNo}', style: const TextStyle(fontSize: 13)),
                                  ],
                                ),
                              ],
                              if (detail.vehicleNo != null) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    const Icon(Icons.local_shipping_outlined, size: 16, color: AppColors.textSecondary),
                                    const SizedBox(width: 8),
                                    Text('Vehicle: ${detail.vehicleNo}', style: const TextStyle(fontSize: 13)),
                                  ],
                                ),
                              ],
                              if (detail.netWeightKg != null) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    const Icon(Icons.scale_rounded, size: 16, color: AppColors.primary),
                                    const SizedBox(width: 8),
                                    Text('Net weight: ${detail.netWeightKg!.toStringAsFixed(2)} kg', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.inventory_2_rounded, size: 18, color: AppColors.primary),
                              const SizedBox(width: 8),
                              Text(
                                'Items Received (${detail.lines.length})',
                                style: AppTypography.headline.copyWith(fontSize: 15, fontWeight: FontWeight.w800),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        ...detail.lines.map((l) => Container(
                              key: Key('grn_detail_line_${l.batchCode}'),
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: AppDecorations.borderRadiusMd,
                                border: Border.all(color: AppColors.border),
                                boxShadow: AppDecorations.cardShadow,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(l.productName, style: AppTypography.title.copyWith(fontSize: 14, fontWeight: FontWeight.w700)),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Batch ${l.batchCode} · ${l.receivedQty.toString()} ${l.uomCode} × ${money(l.unitCost)} · ${l.qualityStatus}',
                                          style: AppTypography.caption,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    money((l.receivedQty * l.unitCost)),
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.success),
                                  ),
                                ],
                              ),
                            )),
                      ],
                    ),
    );
  }
}
