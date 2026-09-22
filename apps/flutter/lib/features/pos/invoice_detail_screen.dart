import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'invoice_history_api.dart';
import 'invoice_pdf.dart';
import 'invoice_pdf_preview_screen.dart';
import '../../core/number_format.dart';

/// Read-only reprint view of one finalized invoice: shop details, line
/// items (with HSN and CGST/SGST/IGST breakdown), and how it was actually
/// paid for (single or split tenders).
class InvoiceDetailScreen extends StatefulWidget {
  final String invoiceId;
  const InvoiceDetailScreen({super.key, required this.invoiceId});

  @override
  State<InvoiceDetailScreen> createState() => _InvoiceDetailScreenState();
}

class _InvoiceDetailScreenState extends State<InvoiceDetailScreen> {
  InvoiceDetail? _detail;
  bool _loading = true;
  bool _sharing = false;
  bool _downloading = false;
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

  Future<void> _sharePdf() async {
    final detail = _detail;
    if (detail == null || _sharing) return;
    setState(() => _sharing = true);
    try {
      await shareInvoicePdf(detail);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share invoice: $e')));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _downloadPdf() async {
    final detail = _detail;
    if (detail == null || _downloading) return;
    setState(() => _downloading = true);
    try {
      final result = await downloadInvoicePdf(detail);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.sharedInstead ? 'Choose "Save" in the share sheet to download the PDF' : 'Saved to ${result.savedPath}'),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not download invoice: $e')));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  void _previewPdf() {
    final detail = _detail;
    if (detail == null) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => InvoicePdfPreviewScreen(invoice: detail)));
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(detail?.invoiceNumber ?? 'Invoice Details', style: AppTypography.headline),
        actions: [
          if (detail != null) ...[
            IconButton(
              key: const Key('invoice_detail_preview_button'),
              icon: const Icon(Icons.visibility_rounded),
              tooltip: 'Preview invoice PDF',
              onPressed: _previewPdf,
            ),
            IconButton(
              key: const Key('invoice_detail_download_button'),
              icon: _downloading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.download_rounded),
              tooltip: 'Download invoice PDF',
              onPressed: _downloading ? null : _downloadPdf,
            ),
            IconButton(
              key: const Key('invoice_detail_share_button'),
              icon: _sharing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.share_rounded),
              tooltip: 'Share invoice PDF',
              onPressed: _sharing ? null : _sharePdf,
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _error != null
              ? Center(
                  child: Container(
                    margin: const EdgeInsets.all(24),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.dangerContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
                  ),
                )
              : detail == null
                  ? const SizedBox.shrink()
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _shopHeaderCard(detail.store),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: AppColors.border),
                            boxShadow: AppDecorations.cardShadow,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(detail.invoiceNumber, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: AppColors.successContainer,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      detail.paymentStatus,
                                      style: const TextStyle(color: AppColors.success, fontWeight: FontWeight.bold, fontSize: 11),
                                    ),
                                  ),
                                ],
                              ),
                              if (detail.finalizedAt != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(_dateFormat.format(detail.finalizedAt!.toLocal()), style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                                ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  const Icon(Icons.person_rounded, size: 16, color: AppColors.primary),
                                  const SizedBox(width: 6),
                                  Text('Customer: ${detail.customerName ?? 'Walking Customer'}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text('Payment status: ${detail.paymentStatus}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Icon(Icons.inventory_2_rounded, size: 18, color: AppColors.primary),
                            const SizedBox(width: 8),
                            const Text('Items', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.textPrimary)),
                            const Spacer(),
                            Text('${detail.lines.length} item(s)', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ...detail.lines.map((l) => Container(
                              key: Key('invoice_detail_line_${l.sku}'),
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppColors.border),
                                boxShadow: AppDecorations.cardShadow,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(l.productName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.textPrimary)),
                                            const SizedBox(height: 2),
                                            Text(
                                              '${l.quantity.toString()} ${l.uomCode} × ${money(l.unitPrice)}'
                                              '${l.hsn != null ? '  ·  HSN ${l.hsn}' : ''}',
                                              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Text(money(l.lineTotal), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.textPrimary)),
                                    ],
                                  ),
                                  if (l.taxBreakdown.isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      children: l.taxBreakdown
                                          .map((t) => Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: AppColors.surfaceSecondary,
                                                  borderRadius: BorderRadius.circular(20),
                                                  border: Border.all(color: AppColors.border),
                                                ),
                                                child: Text(
                                                  '${t.taxType} ${t.rate.toStringAsFixed(2)}%: ${money(t.amount)}',
                                                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w500),
                                                ),
                                              ))
                                          .toList(),
                                    ),
                                  ],
                                ],
                              ),
                            )),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Icon(Icons.payment_rounded, size: 18, color: AppColors.primary),
                            const SizedBox(width: 8),
                            const Text('Payment', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.textPrimary)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.border),
                            boxShadow: AppDecorations.cardShadow,
                          ),
                          child: Column(
                            children: [
                              ...detail.tenders.map((t) => Padding(
                                    key: Key('invoice_detail_tender_${t.method}'),
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              t.method == 'CASH'
                                                  ? Icons.payments_outlined
                                                  : t.method == 'UPI'
                                                      ? Icons.qr_code_2_rounded
                                                      : Icons.account_balance_wallet_outlined,
                                              size: 16,
                                              color: AppColors.primary,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(t.method, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                                          ],
                                        ),
                                        Text(money(t.amount), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                                      ],
                                    ),
                                  )),
                              const Divider(height: 20),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Taxable Total', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                                  Text(money(detail.taxableTotal), style: const TextStyle(fontSize: 13)),
                                ],
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text('Tax', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                                    Text(money(detail.taxTotal), style: const TextStyle(fontSize: 13)),
                                  ],
                                ),
                              ),
                              const Divider(height: 16),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Grand Total', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                  Text(
                                    money(detail.grandTotal),
                                    key: const Key('invoice_detail_grand_total'),
                                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: Color(0xFF0F766E)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            key: const Key('invoice_detail_preview_pdf_bottom_button'),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: _previewPdf,
                            icon: const Icon(Icons.visibility_rounded, size: 18),
                            label: const Text('Preview Invoice PDF', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                key: const Key('invoice_detail_download_pdf_bottom_button'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                onPressed: _downloading ? null : _downloadPdf,
                                icon: const Icon(Icons.download_rounded, size: 18),
                                label: Text(_downloading ? 'Saving…' : 'Download PDF', style: const TextStyle(fontWeight: FontWeight.w600)),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                key: const Key('invoice_detail_share_pdf_bottom_button'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                onPressed: _sharing ? null : _sharePdf,
                                icon: const Icon(Icons.share_rounded, size: 18),
                                label: Text(_sharing ? 'Preparing…' : 'Share PDF', style: const TextStyle(fontWeight: FontWeight.w600)),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
    );
  }

  Widget _shopHeaderCard(InvoiceStoreDetail store) {
    return Container(
      key: const Key('invoice_detail_shop_header'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0F766E), Color(0xFF115E59)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppDecorations.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(40),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.storefront_rounded, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  store.tradeName?.isNotEmpty == true ? store.tradeName! : store.legalName,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(store.fullAddress, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          if (store.phone != null && store.phone!.isNotEmpty)
            Text('Ph: ${store.phone}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          if (store.gstin != null && store.gstin!.isNotEmpty)
            Text('GSTIN: ${store.gstin}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          if (store.fssaiLicenseNo != null && store.fssaiLicenseNo!.isNotEmpty)
            Text('FSSAI: ${store.fssaiLicenseNo}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}
