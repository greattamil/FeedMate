import 'package:decimal/decimal.dart';

import '../../core/api_client.dart';

/// One tender method's total within a period — mirrors reports.TenderTotal.
class TenderTotal {
  final String method;
  final Decimal total;

  TenderTotal({required this.method, required this.total});

  factory TenderTotal.fromJson(Map<String, dynamic> json) {
    return TenderTotal(method: json['method'] as String, total: Decimal.parse(json['total'] as String));
  }
}

/// One period's sales totals — mirrors reports.SalesSummary. Used for
/// Today/Yesterday/Last-30-Days inside a DashboardOverview.
class PeriodSales {
  final int invoiceCount;
  final Decimal grossSales;
  final Decimal discountTotal;
  final Decimal taxTotal;
  final Decimal netSales;
  final List<TenderTotal> byTender;

  PeriodSales({
    required this.invoiceCount,
    required this.grossSales,
    required this.discountTotal,
    required this.taxTotal,
    required this.netSales,
    required this.byTender,
  });

  factory PeriodSales.fromJson(Map<String, dynamic> json) {
    return PeriodSales(
      invoiceCount: json['invoice_count'] as int,
      grossSales: Decimal.parse(json['gross_sales'] as String),
      discountTotal: Decimal.parse(json['discount_total'] as String),
      taxTotal: Decimal.parse(json['tax_total'] as String),
      netSales: Decimal.parse(json['net_sales'] as String),
      byTender: (json['by_tender'] as List<dynamic>).map((t) => TenderTotal.fromJson(t as Map<String, dynamic>)).toList(),
    );
  }
}

/// One day's sales, for the trend chart. Always present for every day in
/// the window even with zero sales (see reports.GetSalesTrend's doc
/// comment) — a chart never has to guess whether a gap means "no data" or
/// "genuinely zero".
class DailySalesPoint {
  final DateTime date;
  final int invoiceCount;
  final Decimal netSales;

  DailySalesPoint({required this.date, required this.invoiceCount, required this.netSales});

  factory DailySalesPoint.fromJson(Map<String, dynamic> json) {
    return DailySalesPoint(
      date: DateTime.parse(json['date'] as String),
      invoiceCount: json['invoice_count'] as int,
      netSales: Decimal.parse(json['net_sales'] as String),
    );
  }
}

/// One product's contribution to revenue in the trailing window, for the
/// best-sellers list.
class TopProductLine {
  final String productId;
  final String sku;
  final String name;
  final Decimal qtySold;
  final Decimal revenue;

  TopProductLine({required this.productId, required this.sku, required this.name, required this.qtySold, required this.revenue});

  factory TopProductLine.fromJson(Map<String, dynamic> json) {
    return TopProductLine(
      productId: json['product_id'] as String,
      sku: json['sku'] as String,
      name: json['name'] as String,
      qtySold: Decimal.parse(json['qty_sold'] as String),
      revenue: Decimal.parse(json['revenue'] as String),
    );
  }
}

/// The tenant-wide stock snapshot — how many products are fine vs. need
/// attention, and what the whole catalog is worth at selling price.
class DashboardStockHealth {
  final int totalProducts;
  final int inStock;
  final int lowStock;
  final int outOfStock;
  final Decimal totalStockValue;

  DashboardStockHealth({
    required this.totalProducts,
    required this.inStock,
    required this.lowStock,
    required this.outOfStock,
    required this.totalStockValue,
  });

  factory DashboardStockHealth.fromJson(Map<String, dynamic> json) {
    return DashboardStockHealth(
      totalProducts: json['total_products'] as int,
      inStock: json['in_stock'] as int,
      lowStock: json['low_stock'] as int,
      outOfStock: json['out_of_stock'] as int,
      totalStockValue: Decimal.parse(json['total_stock_value'] as String),
    );
  }
}

/// One customer's outstanding balance, for the top-debtors list.
class ReceivableLine {
  final String customerId;
  final String name;
  final Decimal balance;
  final Decimal creditLimit;

  ReceivableLine({required this.customerId, required this.name, required this.balance, required this.creditLimit});

  factory ReceivableLine.fromJson(Map<String, dynamic> json) {
    return ReceivableLine(
      customerId: json['customer_id'] as String,
      name: json['name'] as String,
      balance: Decimal.parse(json['balance'] as String),
      creditLimit: Decimal.parse(json['credit_limit'] as String),
    );
  }
}

/// One supplier's outstanding payable, for the top-creditors list.
class PayableLine {
  final String supplierId;
  final String name;
  final Decimal payable;

  PayableLine({required this.supplierId, required this.name, required this.payable});

  factory PayableLine.fromJson(Map<String, dynamic> json) {
    return PayableLine(
      supplierId: json['supplier_id'] as String,
      name: json['name'] as String,
      payable: Decimal.parse(json['payable'] as String),
    );
  }
}

/// One finalized sale, for the recent-activity feed.
class RecentInvoiceLine {
  final String invoiceNumber;
  final String? customerName;
  final Decimal grandTotal;
  final String paymentStatus;
  final DateTime? finalizedAt;

  RecentInvoiceLine({
    required this.invoiceNumber,
    required this.customerName,
    required this.grandTotal,
    required this.paymentStatus,
    required this.finalizedAt,
  });

  factory RecentInvoiceLine.fromJson(Map<String, dynamic> json) {
    return RecentInvoiceLine(
      invoiceNumber: json['invoice_number'] as String,
      customerName: json['customer_name'] as String?,
      grandTotal: Decimal.parse(json['grand_total'] as String),
      paymentStatus: json['payment_status'] as String,
      finalizedAt: json['finalized_at'] == null ? null : DateTime.parse(json['finalized_at'] as String),
    );
  }
}

/// The full bundle behind the detailed Analytics Dashboard screen — one
/// API call for everything (see services/api/internal/httpapi/
/// reports_handlers.go's DashboardOverview). Every number is traceable to
/// the exact same source tables the rest of the app's reports read; this
/// is a read-side bundle, never a separately maintained aggregate.
class DashboardOverview {
  final PeriodSales today;
  final PeriodSales yesterday;
  final PeriodSales last30Days;
  final List<DailySalesPoint> salesTrend;
  final List<TopProductLine> topProducts;
  final DashboardStockHealth stockHealth;
  final List<ReceivableLine> receivables;
  final Decimal totalReceivables;
  final List<PayableLine> payables;
  final Decimal totalPayables;
  final List<RecentInvoiceLine> recentInvoices;

  DashboardOverview({
    required this.today,
    required this.yesterday,
    required this.last30Days,
    required this.salesTrend,
    required this.topProducts,
    required this.stockHealth,
    required this.receivables,
    required this.totalReceivables,
    required this.payables,
    required this.totalPayables,
    required this.recentInvoices,
  });

  /// Today vs yesterday, as a signed percentage (positive = growth). Null
  /// when yesterday had zero sales — a percentage change from zero is
  /// undefined, not "infinite growth" dressed up as a number.
  double? get netSalesGrowthPct {
    if (yesterday.netSales.toDouble() == 0) return null;
    final change = today.netSales - yesterday.netSales;
    return (change.toDouble() / yesterday.netSales.toDouble()) * 100;
  }

  factory DashboardOverview.fromJson(Map<String, dynamic> json) {
    return DashboardOverview(
      today: PeriodSales.fromJson(json['today'] as Map<String, dynamic>),
      yesterday: PeriodSales.fromJson(json['yesterday'] as Map<String, dynamic>),
      last30Days: PeriodSales.fromJson(json['last_30_days'] as Map<String, dynamic>),
      salesTrend: (json['sales_trend'] as List<dynamic>).map((d) => DailySalesPoint.fromJson(d as Map<String, dynamic>)).toList(),
      topProducts: (json['top_products'] as List<dynamic>).map((p) => TopProductLine.fromJson(p as Map<String, dynamic>)).toList(),
      stockHealth: DashboardStockHealth.fromJson(json['stock_health'] as Map<String, dynamic>),
      receivables: (json['receivables'] as List<dynamic>).map((c) => ReceivableLine.fromJson(c as Map<String, dynamic>)).toList(),
      totalReceivables: Decimal.parse(json['total_receivables'] as String),
      payables: (json['payables'] as List<dynamic>).map((s) => PayableLine.fromJson(s as Map<String, dynamic>)).toList(),
      totalPayables: Decimal.parse(json['total_payables'] as String),
      recentInvoices:
          (json['recent_invoices'] as List<dynamic>).map((i) => RecentInvoiceLine.fromJson(i as Map<String, dynamic>)).toList(),
    );
  }
}

/// Wraps GET /api/v1/reports/dashboard.
class DashboardOverviewApi {
  final ApiClient client;

  DashboardOverviewApi(this.client);

  Future<DashboardOverview> fetch() async {
    final response = await client.getAuthed('/api/v1/reports/dashboard');
    return DashboardOverview.fromJson(response);
  }
}
