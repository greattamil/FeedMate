import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import 'grn_history_api.dart';

/// Read-only detail view of one posted GRN: what was received, from whom,
/// and at what cost per line. A posted GRN is never editable from here —
/// see procurement.Service.PostGRN's own doc comments on why receipts are
/// append-only.
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
      appBar: AppBar(title: Text(detail?.grnNumber ?? 'GRN')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: Colors.red))))
              : detail == null
                  ? const SizedBox.shrink()
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(detail.grnNumber, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                              if (detail.postedAt != null)
                                Text(_dateFormat.format(detail.postedAt!.toLocal()), style: const TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                              const SizedBox(height: 4),
                              Text('Supplier: ${detail.supplierName}', style: const TextStyle(fontSize: 13)),
                              if (detail.supplierDocumentNo != null)
                                Text('Supplier doc: ${detail.supplierDocumentNo}', style: const TextStyle(fontSize: 13)),
                              if (detail.vehicleNo != null)
                                Text('Vehicle: ${detail.vehicleNo}', style: const TextStyle(fontSize: 13)),
                              if (detail.netWeightKg != null)
                                Text('Net weight: ${detail.netWeightKg!.toStringAsFixed(2)} kg', style: const TextStyle(fontSize: 13)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text('Items Received', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        const SizedBox(height: 8),
                        ...detail.lines.map((l) => Container(
                              key: Key('grn_detail_line_${l.batchCode}'),
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFE2E8F0)),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(l.productName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                        Text(
                                          'Batch ${l.batchCode} · ${l.receivedQty.toString()} ${l.uomCode} × ₹${l.unitCost.toStringAsFixed(2)} · ${l.qualityStatus}',
                                          style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    '₹${(l.receivedQty * l.unitCost).toStringAsFixed(2)}',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                  ),
                                ],
                              ),
                            )),
                      ],
                    ),
    );
  }
}
