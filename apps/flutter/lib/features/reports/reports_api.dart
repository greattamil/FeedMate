import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';

String _fmtDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

class TenderTotal {
  final String method;
  final Decimal total;

  TenderTotal({required this.method, required this.total});

  factory TenderTotal.fromJson(Map<String, dynamic> json) {
    return TenderTotal(method: json['method'] as String, total: Decimal.parse(json['total'] as String));
  }
}

class SalesSummary {
  final int invoiceCount;
  final Decimal grossSales;
  final Decimal discountTotal;
  final Decimal taxTotal;
  final Decimal netSales;
  final List<TenderTotal> byTender;

  SalesSummary({
    required this.invoiceCount,
    required this.grossSales,
    required this.discountTotal,
    required this.taxTotal,
    required this.netSales,
    required this.byTender,
  });

  factory SalesSummary.fromJson(Map<String, dynamic> json) {
    return SalesSummary(
      invoiceCount: json['invoice_count'] as int,
      grossSales: Decimal.parse(json['gross_sales'] as String),
      discountTotal: Decimal.parse(json['discount_total'] as String),
      taxTotal: Decimal.parse(json['tax_total'] as String),
      netSales: Decimal.parse(json['net_sales'] as String),
      byTender: (json['by_tender'] as List<dynamic>)
          .map((t) => TenderTotal.fromJson(t as Map<String, dynamic>))
          .toList(),
    );
  }
}

class StockOnHandLine {
  final String productId;
  final String sku;
  final String name;
  final Decimal totalAvailable;
  final int batchCount;
  final bool expiringWithin30Days;
  final DateTime? nearestExpiry;

  StockOnHandLine({
    required this.productId,
    required this.sku,
    required this.name,
    required this.totalAvailable,
    required this.batchCount,
    required this.expiringWithin30Days,
    required this.nearestExpiry,
  });

  factory StockOnHandLine.fromJson(Map<String, dynamic> json) {
    return StockOnHandLine(
      productId: json['product_id'] as String,
      sku: json['sku'] as String,
      name: json['name'] as String,
      totalAvailable: Decimal.parse(json['total_available'] as String),
      batchCount: json['batch_count'] as int,
      expiringWithin30Days: json['expiring_within_30_days'] as bool? ?? false,
      nearestExpiry: json['nearest_expiry'] != null ? DateTime.parse(json['nearest_expiry'] as String) : null,
    );
  }
}

/// One product's live stock status — mirrors the server's StockSummaryLine
/// (services/api/internal/domain/reports/repository.go). `status` is
/// computed server-side from the real on-hand quantity against the
/// product's own reorder level, never derived or guessed client-side.
class StockSummaryLine {
  final String productId;
  final String sku;
  final String name;
  final String uomCode;
  final Decimal onHandQty;
  final Decimal? reorderLevel;
  final Decimal? reorderTarget;
  final String status;
  // Whether this product counts toward the dashboard's low/out-of-stock
  // banner and the Stock Management screen's aggregate counts — a shop
  // owner's per-product opt-out (see product.Product.StockAlertEnabled
  // server-side). [status] above is always the real, factual stock state
  // regardless of this flag; it never gets faked as "OK" just because
  // alerts are off for this one product.
  final bool alertsEnabled;

  StockSummaryLine({
    required this.productId,
    required this.sku,
    required this.name,
    required this.uomCode,
    required this.onHandQty,
    required this.reorderLevel,
    required this.reorderTarget,
    required this.status,
    required this.alertsEnabled,
  });

  bool get isOutOfStock => status == 'OUT_OF_STOCK';
  bool get isLowStock => status == 'LOW_STOCK';

  factory StockSummaryLine.fromJson(Map<String, dynamic> json) {
    return StockSummaryLine(
      productId: json['product_id'] as String,
      sku: json['sku'] as String,
      name: json['name'] as String,
      uomCode: json['uom_code'] as String,
      onHandQty: Decimal.parse(json['on_hand_qty'] as String),
      reorderLevel: json['reorder_level'] != null ? Decimal.parse(json['reorder_level'] as String) : null,
      reorderTarget: json['reorder_target'] != null ? Decimal.parse(json['reorder_target'] as String) : null,
      status: json['status'] as String,
      alertsEnabled: json['stock_alert_enabled'] as bool? ?? true,
    );
  }
}

class StockSummary {
  final List<StockSummaryLine> lines;
  final int lowStockCount;
  final int outOfStockCount;

  StockSummary({required this.lines, required this.lowStockCount, required this.outOfStockCount});

  factory StockSummary.fromJson(Map<String, dynamic> json) {
    return StockSummary(
      lines: (json['products'] as List<dynamic>).map((p) => StockSummaryLine.fromJson(p as Map<String, dynamic>)).toList(),
      lowStockCount: json['low_stock_count'] as int,
      outOfStockCount: json['out_of_stock_count'] as int,
    );
  }
}

class CustomerBalance {
  final String customerId;
  final String name;
  final Decimal balance;
  final Decimal creditLimit;

  CustomerBalance({required this.customerId, required this.name, required this.balance, required this.creditLimit});

  factory CustomerBalance.fromJson(Map<String, dynamic> json) {
    return CustomerBalance(
      customerId: json['customer_id'] as String,
      name: json['name'] as String,
      balance: Decimal.parse(json['balance'] as String),
      creditLimit: Decimal.parse(json['credit_limit'] as String),
    );
  }
}

class EodHistoryEntry {
  final DateTime businessDate;
  final Decimal openingCash;
  final Decimal cashSales;
  final Decimal cashRefunds;
  final Decimal expectedCash;
  final Decimal? actualCash;
  final Decimal? variance;
  final String status;

  EodHistoryEntry({
    required this.businessDate,
    required this.openingCash,
    required this.cashSales,
    required this.cashRefunds,
    required this.expectedCash,
    required this.actualCash,
    required this.variance,
    required this.status,
  });

  factory EodHistoryEntry.fromJson(Map<String, dynamic> json) {
    return EodHistoryEntry(
      businessDate: DateTime.parse(json['business_date'] as String),
      openingCash: Decimal.parse(json['opening_cash'] as String),
      cashSales: Decimal.parse(json['cash_sales'] as String),
      cashRefunds: Decimal.parse(json['cash_refunds'] as String),
      expectedCash: Decimal.parse(json['expected_cash'] as String),
      actualCash: json['actual_cash'] != null ? Decimal.parse(json['actual_cash'] as String) : null,
      variance: json['variance'] != null ? Decimal.parse(json['variance'] as String) : null,
      status: json['status'] as String,
    );
  }
}

/// Wraps the four reporting endpoints — see
/// services/api/internal/httpapi/reports_handlers.go. All computation
/// (totals, balances, expiry windows) happens server-side; this class only
/// shapes requests/responses, matching every other API wrapper in the app.
class ReportsApi {
  final ApiClient client;

  ReportsApi(this.client);

  Future<SalesSummary> salesSummary({required DateTime dateFrom, required DateTime dateTo}) async {
    final response = await client.getAuthed(
      '/api/v1/reports/sales-summary?date_from=${_fmtDate(dateFrom)}&date_to=${_fmtDate(dateTo)}',
    );
    return SalesSummary.fromJson(response);
  }

  Future<List<StockOnHandLine>> stockOnHand() async {
    final response = await client.getAuthed('/api/v1/reports/stock-on-hand');
    return (response['products'] as List<dynamic>)
        .map((p) => StockOnHandLine.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  Future<StockSummary> stockSummary() async {
    final response = await client.getAuthed('/api/v1/reports/stock-summary');
    return StockSummary.fromJson(response);
  }

  Future<List<CustomerBalance>> customerBalances() async {
    final response = await client.getAuthed('/api/v1/reports/customer-balances');
    return (response['customers'] as List<dynamic>)
        .map((c) => CustomerBalance.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<List<EodHistoryEntry>> eodHistory({DateTime? dateFrom, DateTime? dateTo}) async {
    final params = <String>[];
    if (dateFrom != null) params.add('date_from=${_fmtDate(dateFrom)}');
    if (dateTo != null) params.add('date_to=${_fmtDate(dateTo)}');
    final query = params.isEmpty ? '' : '?${params.join('&')}';
    final response = await client.getAuthed('/api/v1/reports/eod-history$query');
    return (response['sessions'] as List<dynamic>)
        .map((e) => EodHistoryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
