import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import 'invoice_history_api.dart';

/// Read-only reprint view of one finalized invoice: line items and how it
/// was actually paid for (single or split tenders). A finalized invoice is
/// never editable from here — this screen only displays what the server
/// already recorded. There is no physical printer/receipt-hardware
/// integration in this app yet (see docs/IMPLEMENTATION_STATUS.md), so this
/// is the on-screen equivalent of a reprinted receipt.
class InvoiceDetailScreen extends StatefulWidget {
  final String invoiceId;
  const InvoiceDetailScreen({super.key, required this.invoiceId});

  @override
  State<InvoiceDetailScreen> createState() => _InvoiceDetailScreenState();
}

class _InvoiceDetailScreenState extends State<InvoiceDetailScreen> {
  InvoiceDetail? _detail;
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
      final api = InvoiceHistoryApi(context.read<ApiClient>());
      final detail = await api.getDetail(widget.invoiceId);
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
      appBar: AppBar(title: Text(detail?.invoiceNumber ?? 'Invoice')),
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
                              Text(detail.invoiceNumber, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                              if (detail.finalizedAt != null)
                                Text(_dateFormat.format(detail.finalizedAt!.toLocal()), style: const TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                              if (detail.customerName != null) ...[
                                const SizedBox(height: 4),
                                Text('Customer: ${detail.customerName}', style: const TextStyle(fontSize: 13)),
                              ],
                              const SizedBox(height: 4),
                              Text('Payment status: ${detail.paymentStatus}', style: const TextStyle(fontSize: 13)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text('Items', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        const SizedBox(height: 8),
                        ...detail.lines.map((l) => Container(
                              key: Key('invoice_detail_line_${l.sku}'),
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
                                          '${l.quantity.toString()} ${l.uomCode} × ₹${l.unitPrice.toStringAsFixed(2)}',
                                          style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text('₹${l.lineTotal.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                ],
                              ),
                            )),
                        const SizedBox(height: 16),
                        const Text('Payment', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        const SizedBox(height: 8),
                        ...detail.tenders.map((t) => Padding(
                              key: Key('invoice_detail_tender_${t.method}'),
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(t.method, style: const TextStyle(fontSize: 13)),
                                  Text('₹${t.amount.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            )),
                        const Divider(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Taxable Total', style: TextStyle(fontSize: 13)),
                            Text('₹${detail.taxableTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13)),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Tax', style: TextStyle(fontSize: 13)),
                              Text('₹${detail.taxTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13)),
                            ],
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Grand Total', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            Text(
                              '₹${detail.grandTotal.toStringAsFixed(2)}',
                              key: const Key('invoice_detail_grand_total'),
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF0F766E)),
                            ),
                          ],
                        ),
                      ],
                    ),
    );
  }
}
