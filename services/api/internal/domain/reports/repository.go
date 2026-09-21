// Package reports implements read-only aggregation queries. Every report
// here derives its numbers from the same authoritative source tables every
// other module writes to (sales_invoices, stock_movements/batches,
// customer_ledger_entries, eod_sessions) — there is no separate,
// independently-maintained reporting table that could silently diverge from
// the real transactional data (PRD 50: "never create fake aggregate tables
// that can diverge without reconciliation").
package reports

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

type SalesSummary struct {
	InvoiceCount  int64
	GrossSales    decimal.Decimal // subtotal before discount
	DiscountTotal decimal.Decimal
	TaxTotal      decimal.Decimal
	NetSales      decimal.Decimal // grand_total
	ByTender      []TenderTotal
}

type TenderTotal struct {
	Method string
	Total  decimal.Decimal
}

// GetSalesSummary aggregates FINALIZED invoices in [dateFrom, dateTo]
// (inclusive) directly from sales_invoices/invoice_tenders — the exact rows
// every finalized sale writes to, so this total is always traceable back to
// individual invoices (PRD 22/50).
func GetSalesSummary(ctx context.Context, tx pgx.Tx, dateFrom, dateTo time.Time) (*SalesSummary, error) {
	var s SalesSummary
	row := tx.QueryRow(ctx, `
		SELECT
			COUNT(*),
			COALESCE(SUM(subtotal), 0),
			COALESCE(SUM(discount_total), 0),
			COALESCE(SUM(tax_total), 0),
			COALESCE(SUM(grand_total), 0)
		FROM sales_invoices
		WHERE status = 'FINALIZED' AND invoice_date::date BETWEEN $1 AND $2
	`, dateFrom, dateTo)
	if err := row.Scan(&s.InvoiceCount, &s.GrossSales, &s.DiscountTotal, &s.TaxTotal, &s.NetSales); err != nil {
		return nil, err
	}

	rows, err := tx.Query(ctx, `
		SELECT it.tender_method, COALESCE(SUM(it.amount), 0)
		FROM invoice_tenders it
		JOIN sales_invoices si ON si.id = it.invoice_id
		WHERE si.status = 'FINALIZED' AND si.invoice_date::date BETWEEN $1 AND $2
		GROUP BY it.tender_method
		ORDER BY it.tender_method
	`, dateFrom, dateTo)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var t TenderTotal
		if err := rows.Scan(&t.Method, &t.Total); err != nil {
			return nil, err
		}
		s.ByTender = append(s.ByTender, t)
	}
	return &s, rows.Err()
}

type StockOnHandLine struct {
	ProductID            uuid.UUID
	SKU                  string
	ProductName          string
	TotalAvailable       decimal.Decimal
	BatchCount           int64
	NearestExpiry        *time.Time
	ExpiringWithin30Days bool
}

// GetStockOnHand aggregates directly from batches.available_qty (itself kept
// correct exclusively by inventory.PostStockMovement) grouped by product —
// this is the same number POS/GRN/returns all read and write, not a
// separately maintained snapshot.
func GetStockOnHand(ctx context.Context, tx pgx.Tx, locationID *uuid.UUID) ([]StockOnHandLine, error) {
	rows, err := tx.Query(ctx, `
		SELECT p.id, p.sku, p.name,
		       COALESCE(SUM(b.available_qty), 0) AS total_available,
		       COUNT(*) FILTER (WHERE b.available_qty > 0) AS batch_count,
		       MIN(b.expiry_date) FILTER (WHERE b.available_qty > 0) AS nearest_expiry
		FROM products p
		JOIN batches b ON b.product_id = p.id AND b.status = 'ACTIVE'
		WHERE p.active AND ($1::uuid IS NULL OR b.location_id = $1)
		GROUP BY p.id, p.sku, p.name
		HAVING COALESCE(SUM(b.available_qty), 0) > 0
		ORDER BY p.name
	`, locationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []StockOnHandLine
	for rows.Next() {
		var l StockOnHandLine
		if err := rows.Scan(&l.ProductID, &l.SKU, &l.ProductName, &l.TotalAvailable, &l.BatchCount, &l.NearestExpiry); err != nil {
			return nil, err
		}
		if l.NearestExpiry != nil {
			l.ExpiringWithin30Days = l.NearestExpiry.Before(time.Now().AddDate(0, 0, 30))
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// StockSummaryLine is one product's live stock status for the Stock
// Management screen: its real-time on-hand quantity next to its own
// reorder threshold, so "running low" is derived on read, not cached or
// hand-maintained anywhere.
type StockSummaryLine struct {
	ProductID     uuid.UUID
	SKU           string
	ProductName   string
	UOMCode       string
	OnHandQty     decimal.Decimal
	ReorderLevel  *decimal.Decimal
	ReorderTarget *decimal.Decimal
	Status        string // OUT_OF_STOCK | LOW_STOCK | OK — always factual,
	// computed from real on-hand qty regardless of AlertsEnabled below.
	// AlertsEnabled never changes what Status says; it only tells the
	// caller whether this line should count toward the aggregate
	// low/out-of-stock totals a dashboard banner shows (see
	// product.Product.StockAlertEnabled's doc comment for why this exists —
	// a shop owner can turn off alerting for one product, e.g. a
	// made-to-order item, without it ever lying about that product's real
	// stock level here or anywhere else that reads this line).
	AlertsEnabled bool
}

// GetStockSummary lists every active product with its on-hand quantity
// aggregated from batches.available_qty — the same column POS allocation,
// GRN receiving, sales returns, and stock-count adjustments all read and
// write via inventory.PostStockMovement (see that function's doc comment;
// there is no separate stock cache anywhere in this schema). Unlike
// GetStockOnHand above, this LEFT JOINs batches and has no HAVING filter,
// so a product with zero stock — or one that has never been received via
// GRN and so has no batch rows at all — still appears with on_hand_qty of
// zero, rather than silently disappearing from the list a shopkeeper needs
// to see everything on.
func GetStockSummary(ctx context.Context, tx pgx.Tx, locationID *uuid.UUID) ([]StockSummaryLine, error) {
	rows, err := tx.Query(ctx, `
		SELECT p.id, p.sku, p.name, u.code,
		       COALESCE(SUM(b.available_qty), 0) AS on_hand,
		       p.reorder_level, p.reorder_target, p.stock_alert_enabled
		FROM products p
		JOIN uoms u ON u.id = p.default_sale_uom_id
		LEFT JOIN batches b ON b.product_id = p.id AND b.status = 'ACTIVE'
		         AND ($1::uuid IS NULL OR b.location_id = $1)
		WHERE p.active
		GROUP BY p.id, p.sku, p.name, u.code, p.reorder_level, p.reorder_target, p.stock_alert_enabled
		ORDER BY p.name
	`, locationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []StockSummaryLine
	for rows.Next() {
		var l StockSummaryLine
		if err := rows.Scan(&l.ProductID, &l.SKU, &l.ProductName, &l.UOMCode, &l.OnHandQty, &l.ReorderLevel, &l.ReorderTarget, &l.AlertsEnabled); err != nil {
			return nil, err
		}
		switch {
		case l.OnHandQty.LessThanOrEqual(decimal.Zero):
			l.Status = "OUT_OF_STOCK"
		case l.ReorderLevel != nil && l.OnHandQty.LessThanOrEqual(*l.ReorderLevel):
			l.Status = "LOW_STOCK"
		default:
			l.Status = "OK"
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

type CustomerBalance struct {
	CustomerID  uuid.UUID
	Name        string
	Balance     decimal.Decimal
	CreditLimit decimal.Decimal
}

// GetCustomerBalances derives every customer's outstanding balance from
// customer_ledger_entries (SUM(debit)-SUM(credit)) — the same append-only
// ledger POS/returns/payments/contra all post to — and returns only
// customers with a non-zero balance, ordered highest-first so the highest
// collection priority customers sort to the top.
//
// This intentionally reports total outstanding rather than full age-bucketed
// (30/60/90-day) aging: correctly attributing partial payments/returns back
// to specific original invoices (to bucket by invoice age) needs an
// allocation-matching algorithm that was not implemented in this pass rather
// than risk shipping an aging calculation that quietly misattributes partial
// settlements — see docs/IMPLEMENTATION_STATUS.md for this scope note.
func GetCustomerBalances(ctx context.Context, tx pgx.Tx) ([]CustomerBalance, error) {
	rows, err := tx.Query(ctx, `
		SELECT c.id, c.name, bal.balance, COALESCE(ccp.credit_limit, 0)
		FROM customers c
		JOIN (
			SELECT customer_id, SUM(debit) - SUM(credit) AS balance
			FROM customer_ledger_entries
			GROUP BY customer_id
		) bal ON bal.customer_id = c.id
		LEFT JOIN customer_credit_profiles ccp ON ccp.customer_id = c.id
		WHERE bal.balance <> 0
		ORDER BY bal.balance DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []CustomerBalance
	for rows.Next() {
		var b CustomerBalance
		if err := rows.Scan(&b.CustomerID, &b.Name, &b.Balance, &b.CreditLimit); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

type EODHistoryEntry struct {
	BusinessDate time.Time
	OpeningCash  decimal.Decimal
	CashSales    decimal.Decimal
	CashRefunds  decimal.Decimal
	ExpectedCash decimal.Decimal
	ActualCash   *decimal.Decimal
	Variance     *decimal.Decimal
	Status       string
}

func GetEODHistory(ctx context.Context, tx pgx.Tx, dateFrom, dateTo time.Time) ([]EODHistoryEntry, error) {
	rows, err := tx.Query(ctx, `
		SELECT business_date, opening_cash, cash_sales, cash_refunds, expected_cash, actual_cash, variance, status
		FROM eod_sessions
		WHERE business_date BETWEEN $1 AND $2
		ORDER BY business_date DESC
	`, dateFrom, dateTo)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []EODHistoryEntry
	for rows.Next() {
		var e EODHistoryEntry
		if err := rows.Scan(&e.BusinessDate, &e.OpeningCash, &e.CashSales, &e.CashRefunds, &e.ExpectedCash, &e.ActualCash, &e.Variance, &e.Status); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// DailySales is one day's totals for the dashboard's sales trend chart.
type DailySales struct {
	Date         time.Time
	InvoiceCount int64
	NetSales     decimal.Decimal
}

// GetSalesTrend returns exactly [days] consecutive days ending today
// (inclusive), oldest first — every day present even with zero sales, via
// generate_series LEFT JOINed to the real invoice totals, so a trend chart
// never has to guess whether a missing day means "no data yet" or "no
// sales that day" (they're the same thing here: zero). Sourced from the
// same sales_invoices GetSalesSummary reads, never a separate rollup.
func GetSalesTrend(ctx context.Context, tx pgx.Tx, days int) ([]DailySales, error) {
	if days <= 0 || days > 90 {
		days = 14
	}
	rows, err := tx.Query(ctx, `
		SELECT d.day::date,
		       COALESCE(COUNT(si.id), 0),
		       COALESCE(SUM(si.grand_total), 0)
		FROM generate_series(CURRENT_DATE - ($1::int - 1), CURRENT_DATE, interval '1 day') AS d(day)
		LEFT JOIN sales_invoices si
		       ON si.invoice_date::date = d.day AND si.status = 'FINALIZED'
		GROUP BY d.day
		ORDER BY d.day
	`, days)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []DailySales
	for rows.Next() {
		var d DailySales
		if err := rows.Scan(&d.Date, &d.InvoiceCount, &d.NetSales); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// TopProduct is one product's contribution to revenue in a trailing window,
// for the dashboard's best-sellers list.
type TopProduct struct {
	ProductID   uuid.UUID
	SKU         string
	ProductName string
	QtySold     decimal.Decimal
	Revenue     decimal.Decimal
}

// GetTopProducts ranks products by revenue over the trailing [days] days,
// summed directly from sales_invoice_lines (its product_name_snapshot/
// sku_snapshot are used rather than joining products, since a sale's
// history should read back exactly what was actually sold even if the
// product was later renamed — the same snapshot convention invoices
// already use everywhere else).
func GetTopProducts(ctx context.Context, tx pgx.Tx, days, limit int) ([]TopProduct, error) {
	if days <= 0 || days > 365 {
		days = 30
	}
	if limit <= 0 || limit > 50 {
		limit = 8
	}
	rows, err := tx.Query(ctx, `
		SELECT sil.product_id, sil.sku_snapshot, sil.product_name_snapshot,
		       SUM(sil.quantity), SUM(sil.line_total)
		FROM sales_invoice_lines sil
		JOIN sales_invoices si ON si.id = sil.invoice_id
		WHERE si.status = 'FINALIZED'
		  AND si.invoice_date >= CURRENT_DATE - ($1::int - 1)
		GROUP BY sil.product_id, sil.sku_snapshot, sil.product_name_snapshot
		ORDER BY SUM(sil.line_total) DESC
		LIMIT $2
	`, days, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []TopProduct
	for rows.Next() {
		var p TopProduct
		if err := rows.Scan(&p.ProductID, &p.SKU, &p.ProductName, &p.QtySold, &p.Revenue); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// StockHealth is the tenant-wide stock snapshot for the dashboard: how many
// products are fine vs. need attention, and what the whole catalog's
// on-hand quantity is worth at selling price. Purpose-built for this one
// summary rather than reusing GetStockSummary's per-line result, so that
// function's existing contract/tests are never disturbed by a dashboard
// concern (total stock value) that has nothing to do with the per-product
// Stock Management screen it serves.
type StockHealth struct {
	TotalProducts   int64
	InStock         int64
	LowStock        int64
	OutOfStock      int64
	TotalStockValue decimal.Decimal
}

func GetStockHealth(ctx context.Context, tx pgx.Tx) (*StockHealth, error) {
	rows, err := tx.Query(ctx, `
		SELECT p.reorder_level, p.selling_price, COALESCE(SUM(b.available_qty), 0) AS on_hand
		FROM products p
		LEFT JOIN batches b ON b.product_id = p.id AND b.status = 'ACTIVE'
		WHERE p.active
		GROUP BY p.id, p.reorder_level, p.selling_price
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var health StockHealth
	for rows.Next() {
		var reorderLevel, sellingPrice *decimal.Decimal
		var onHand decimal.Decimal
		if err := rows.Scan(&reorderLevel, &sellingPrice, &onHand); err != nil {
			return nil, err
		}
		health.TotalProducts++
		switch {
		case onHand.LessThanOrEqual(decimal.Zero):
			health.OutOfStock++
		case reorderLevel != nil && onHand.LessThanOrEqual(*reorderLevel):
			health.LowStock++
		default:
			health.InStock++
		}
		if sellingPrice != nil {
			health.TotalStockValue = health.TotalStockValue.Add(onHand.Mul(*sellingPrice))
		}
	}
	return &health, rows.Err()
}

// SupplierBalance mirrors CustomerBalance on the payable side, for the
// dashboard's top-creditors list.
type SupplierBalance struct {
	SupplierID uuid.UUID
	Name       string
	Payable    decimal.Decimal
}

// GetSupplierPayables derives every supplier's outstanding payable from
// supplier_ledger_entries (SUM(credit)-SUM(debit) — the opposite convention
// from a customer ledger, since a GRN credits what the shop owes) and
// returns only suppliers with a non-zero payable, highest first.
func GetSupplierPayables(ctx context.Context, tx pgx.Tx) ([]SupplierBalance, error) {
	rows, err := tx.Query(ctx, `
		SELECT s.id, s.legal_name, bal.payable
		FROM suppliers s
		JOIN (
			SELECT supplier_id, SUM(credit) - SUM(debit) AS payable
			FROM supplier_ledger_entries
			GROUP BY supplier_id
		) bal ON bal.supplier_id = s.id
		WHERE bal.payable <> 0
		ORDER BY bal.payable DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []SupplierBalance
	for rows.Next() {
		var b SupplierBalance
		if err := rows.Scan(&b.SupplierID, &b.Name, &b.Payable); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// RecentInvoice is one finalized sale for the dashboard's activity feed.
type RecentInvoice struct {
	InvoiceNumber string
	CustomerName  *string
	GrandTotal    decimal.Decimal
	PaymentStatus string
	FinalizedAt   *time.Time
}

func GetRecentInvoices(ctx context.Context, tx pgx.Tx, limit int) ([]RecentInvoice, error) {
	if limit <= 0 || limit > 50 {
		limit = 8
	}
	rows, err := tx.Query(ctx, `
		SELECT invoice_number, customer_name_snapshot, grand_total, payment_status, finalized_at
		FROM sales_invoices
		WHERE status = 'FINALIZED'
		ORDER BY finalized_at DESC NULLS LAST
		LIMIT $1
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []RecentInvoice
	for rows.Next() {
		var r RecentInvoice
		if err := rows.Scan(&r.InvoiceNumber, &r.CustomerName, &r.GrandTotal, &r.PaymentStatus, &r.FinalizedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
