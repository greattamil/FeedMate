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
	ProductID       uuid.UUID
	SKU             string
	ProductName     string
	TotalAvailable  decimal.Decimal
	BatchCount      int64
	NearestExpiry   *time.Time
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
	Status        string // OUT_OF_STOCK | LOW_STOCK | OK
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
		       p.reorder_level, p.reorder_target
		FROM products p
		JOIN uoms u ON u.id = p.default_sale_uom_id
		LEFT JOIN batches b ON b.product_id = p.id AND b.status = 'ACTIVE'
		         AND ($1::uuid IS NULL OR b.location_id = $1)
		WHERE p.active
		GROUP BY p.id, p.sku, p.name, u.code, p.reorder_level, p.reorder_target
		ORDER BY p.name
	`, locationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []StockSummaryLine
	for rows.Next() {
		var l StockSummaryLine
		if err := rows.Scan(&l.ProductID, &l.SKU, &l.ProductName, &l.UOMCode, &l.OnHandQty, &l.ReorderLevel, &l.ReorderTarget); err != nil {
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
	CustomerID uuid.UUID
	Name       string
	Balance    decimal.Decimal
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
