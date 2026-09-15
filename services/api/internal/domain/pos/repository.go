package pos

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNotFound = errors.New("invoice not found")

// AllocateInvoiceNumber atomically reserves the next number in the tenant's
// INVOICE document series for the given financial year, locking the series
// row so concurrent finalizations on different connections cannot receive
// the same number (PRD A13/9.5 — invoice numbering must be collision-safe).
func AllocateInvoiceNumber(ctx context.Context, tx pgx.Tx, tenantID, financialYearID uuid.UUID) (string, error) {
	var seriesID uuid.UUID
	var prefix string
	var nextNumber int64
	var padding int
	row := tx.QueryRow(ctx, `
		SELECT id, prefix, next_number, padding
		FROM document_series
		WHERE tenant_id = $1 AND financial_year_id = $2 AND document_type = 'INVOICE' AND active
		FOR UPDATE
	`, tenantID, financialYearID)
	if err := row.Scan(&seriesID, &prefix, &nextNumber, &padding); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", fmt.Errorf("no active INVOICE document series configured for this financial year")
		}
		return "", err
	}

	if _, err := tx.Exec(ctx, `UPDATE document_series SET next_number = next_number + 1, updated_at = now() WHERE id = $1`, seriesID); err != nil {
		return "", err
	}

	return fmt.Sprintf("%s%0*d", prefix, padding, nextNumber), nil
}

type InvoiceHeader struct {
	ID                  uuid.UUID
	FinancialYearID     uuid.UUID
	InvoiceNumber       string
	CustomerID          *uuid.UUID
	CustomerNameSnap    *string
	Subtotal            decimal.Decimal
	DiscountTotal       decimal.Decimal
	TaxableTotal        decimal.Decimal
	TaxTotal            decimal.Decimal
	RoundingAmount      decimal.Decimal
	GrandTotal          decimal.Decimal
	PaymentStatus       string
	Status              string
	Source              string
	ClientTransactionID *uuid.UUID
	DeviceID            *uuid.UUID
	CashierUserID       *uuid.UUID
	FinalizedAt         *time.Time
}

// FindByClientTransactionID implements upload idempotency: a retried
// finalize request from the same device with the same client_transaction_id
// must return the original result, never create a second invoice (PRD A11).
func FindByClientTransactionID(ctx context.Context, tx pgx.Tx, deviceID, clientTransactionID uuid.UUID) (*InvoiceHeader, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, financial_year_id, invoice_number, customer_id, customer_name_snapshot,
		       subtotal, discount_total, taxable_total, tax_total, rounding_amount, grand_total,
		       payment_status, status, source, client_transaction_id, device_id, cashier_user_id, finalized_at
		FROM sales_invoices WHERE device_id = $1 AND client_transaction_id = $2
	`, deviceID, clientTransactionID)
	return scanInvoiceHeader(row)
}

func GetInvoiceByID(ctx context.Context, tx pgx.Tx, id uuid.UUID) (*InvoiceHeader, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, financial_year_id, invoice_number, customer_id, customer_name_snapshot,
		       subtotal, discount_total, taxable_total, tax_total, rounding_amount, grand_total,
		       payment_status, status, source, client_transaction_id, device_id, cashier_user_id, finalized_at
		FROM sales_invoices WHERE id = $1
	`, id)
	return scanInvoiceHeader(row)
}

// GetByInvoiceNumber looks an invoice up by its human-facing number (what a
// cashier actually has on the printed receipt) rather than its internal id,
// so a return can be initiated without the client ever having stored the id.
func GetByInvoiceNumber(ctx context.Context, tx pgx.Tx, invoiceNumber string) (*InvoiceHeader, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, financial_year_id, invoice_number, customer_id, customer_name_snapshot,
		       subtotal, discount_total, taxable_total, tax_total, rounding_amount, grand_total,
		       payment_status, status, source, client_transaction_id, device_id, cashier_user_id, finalized_at
		FROM sales_invoices WHERE invoice_number = $1
	`, invoiceNumber)
	return scanInvoiceHeader(row)
}

// InvoiceLineSummary describes one line of a finalized invoice for the
// purpose of picking what to return: what was sold, and what of it is still
// eligible (never more than quantity minus what's already been returned via
// a POSTED return — PRD 9.7).
type InvoiceLineSummary struct {
	ID              uuid.UUID
	ProductID       uuid.UUID
	ProductName     string
	SKU             string
	HSN             *string
	UOMCode         string
	Quantity        decimal.Decimal
	UnitPrice       decimal.Decimal
	DiscountAmount  decimal.Decimal
	TaxableValue    decimal.Decimal
	TaxTotal        decimal.Decimal
	LineTotal       decimal.Decimal
	AlreadyReturned decimal.Decimal
	TaxLines        []TaxLineDetail
}

// TaxLineDetail is one tax component (CGST/SGST/IGST/CESS) applied to a
// single invoice line, for the printed invoice's tax breakdown.
type TaxLineDetail struct {
	TaxType string
	Rate    decimal.Decimal
	Amount  decimal.Decimal
}

func ListInvoiceLines(ctx context.Context, tx pgx.Tx, invoiceID uuid.UUID) ([]InvoiceLineSummary, error) {
	rows, err := tx.Query(ctx, `
		SELECT l.id, l.product_id, l.product_name_snapshot, l.sku_snapshot, l.hsn_snapshot, l.uom_code_snapshot,
		       l.quantity, l.unit_price, l.discount_amount, l.taxable_value, l.tax_total, l.line_total,
		       COALESCE((
		           SELECT SUM(srl.quantity) FROM sales_return_lines srl
		           JOIN sales_returns sr ON sr.id = srl.sales_return_id
		           WHERE srl.original_line_id = l.id AND sr.status = 'POSTED'
		       ), 0)
		FROM sales_invoice_lines l
		WHERE l.invoice_id = $1
		ORDER BY l.line_no
	`, invoiceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []InvoiceLineSummary
	for rows.Next() {
		var l InvoiceLineSummary
		if err := rows.Scan(&l.ID, &l.ProductID, &l.ProductName, &l.SKU, &l.HSN, &l.UOMCode,
			&l.Quantity, &l.UnitPrice, &l.DiscountAmount, &l.TaxableValue, &l.TaxTotal, &l.LineTotal, &l.AlreadyReturned); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	taxByLine, err := ListTaxLinesByInvoice(ctx, tx, invoiceID)
	if err != nil {
		return nil, err
	}
	for i := range out {
		out[i].TaxLines = taxByLine[out[i].ID]
	}
	return out, nil
}

// ListTaxLinesByInvoice returns every tax component posted for an invoice,
// grouped by invoice_line_id, for the printed invoice's per-line CGST/SGST/
// IGST breakdown (PRD GST-compliance requirement).
func ListTaxLinesByInvoice(ctx context.Context, tx pgx.Tx, invoiceID uuid.UUID) (map[uuid.UUID][]TaxLineDetail, error) {
	rows, err := tx.Query(ctx, `
		SELECT invoice_line_id, tax_type, rate, tax_amount
		FROM invoice_tax_lines
		WHERE invoice_id = $1
		ORDER BY tax_type
	`, invoiceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := map[uuid.UUID][]TaxLineDetail{}
	for rows.Next() {
		var lineID uuid.UUID
		var t TaxLineDetail
		if err := rows.Scan(&lineID, &t.TaxType, &t.Rate, &t.Amount); err != nil {
			return nil, err
		}
		out[lineID] = append(out[lineID], t)
	}
	return out, rows.Err()
}

func scanInvoiceHeader(row pgx.Row) (*InvoiceHeader, error) {
	var h InvoiceHeader
	err := row.Scan(&h.ID, &h.FinancialYearID, &h.InvoiceNumber, &h.CustomerID, &h.CustomerNameSnap,
		&h.Subtotal, &h.DiscountTotal, &h.TaxableTotal, &h.TaxTotal, &h.RoundingAmount, &h.GrandTotal,
		&h.PaymentStatus, &h.Status, &h.Source, &h.ClientTransactionID, &h.DeviceID, &h.CashierUserID, &h.FinalizedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &h, nil
}

func InsertInvoiceHeader(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, h *InvoiceHeader) error {
	row := tx.QueryRow(ctx, `
		INSERT INTO sales_invoices (
			tenant_id, financial_year_id, invoice_number, customer_id, customer_name_snapshot,
			subtotal, discount_total, taxable_total, tax_total, rounding_amount, grand_total,
			payment_status, status, source, client_transaction_id, device_id, cashier_user_id, finalized_at
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,'FINALIZED',$13,$14,$15,$16, now())
		RETURNING id, finalized_at
	`, tenantID, h.FinancialYearID, h.InvoiceNumber, h.CustomerID, h.CustomerNameSnap,
		h.Subtotal, h.DiscountTotal, h.TaxableTotal, h.TaxTotal, h.RoundingAmount, h.GrandTotal,
		h.PaymentStatus, h.Source, h.ClientTransactionID, h.DeviceID, h.CashierUserID)
	return row.Scan(&h.ID, &h.FinalizedAt)
}

type InvoiceLineInput struct {
	LineNo             int
	ProductID          uuid.UUID
	ProductNameSnap    string
	SKUSnap            string
	HSNSnap            *string
	UOMID              uuid.UUID
	UOMCodeSnap        string
	Quantity           decimal.Decimal
	UnitPrice          decimal.Decimal
	DiscountAmount     decimal.Decimal
	TaxableValue       decimal.Decimal
	TaxProfileSnapshot []byte // JSONB
	TaxTotal           decimal.Decimal
	LineTotal          decimal.Decimal
}

func InsertInvoiceLine(ctx context.Context, tx pgx.Tx, tenantID, invoiceID uuid.UUID, l *InvoiceLineInput) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO sales_invoice_lines (
			tenant_id, invoice_id, line_no, product_id, product_name_snapshot, sku_snapshot, hsn_snapshot,
			uom_id, uom_code_snapshot, quantity, unit_price, discount_amount, taxable_value,
			tax_profile_snapshot, tax_total, line_total
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)
		RETURNING id
	`, tenantID, invoiceID, l.LineNo, l.ProductID, l.ProductNameSnap, l.SKUSnap, l.HSNSnap,
		l.UOMID, l.UOMCodeSnap, l.Quantity, l.UnitPrice, l.DiscountAmount, l.TaxableValue,
		l.TaxProfileSnapshot, l.TaxTotal, l.LineTotal).Scan(&id)
	return id, err
}

type TaxLineInput struct {
	InvoiceLineID uuid.UUID
	TaxType       string
	Rate          decimal.Decimal
	TaxableValue  decimal.Decimal
	TaxAmount     decimal.Decimal
}

func InsertTaxLine(ctx context.Context, tx pgx.Tx, tenantID, invoiceID uuid.UUID, t TaxLineInput) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO invoice_tax_lines (tenant_id, invoice_id, invoice_line_id, tax_type, rate, taxable_value, tax_amount)
		VALUES ($1,$2,$3,$4,$5,$6,$7)
	`, tenantID, invoiceID, t.InvoiceLineID, t.TaxType, t.Rate, t.TaxableValue, t.TaxAmount)
	return err
}

func InsertBatchAllocation(ctx context.Context, tx pgx.Tx, tenantID, invoiceLineID, batchID, uomID uuid.UUID, qty, unitCost decimal.Decimal) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO invoice_batch_allocations (tenant_id, invoice_line_id, batch_id, quantity, uom_id, unit_cost, cost_value)
		VALUES ($1,$2,$3,$4,$5,$6,$7)
	`, tenantID, invoiceLineID, batchID, qty, uomID, unitCost, qty.Mul(unitCost))
	return err
}

func InsertTender(ctx context.Context, tx pgx.Tx, tenantID, invoiceID uuid.UUID, method string, amount decimal.Decimal, paymentID *uuid.UUID, reference *string) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO invoice_tenders (tenant_id, invoice_id, tender_method, amount, payment_id, reference)
		VALUES ($1,$2,$3,$4,$5,$6)
	`, tenantID, invoiceID, method, amount, paymentID, reference)
	return err
}

// ListInvoices returns finalized invoices newest-first, for the invoice
// history/reprint screen. query optionally filters by a case-insensitive
// substring match on invoice_number or the customer's name snapshot.
func ListInvoices(ctx context.Context, tx pgx.Tx, query string, limit, offset int) ([]InvoiceHeader, int, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	var total int
	if err := tx.QueryRow(ctx, `
		SELECT COUNT(*) FROM sales_invoices
		WHERE status = 'FINALIZED'
		  AND ($1 = '' OR invoice_number ILIKE '%' || $1 || '%' OR customer_name_snapshot ILIKE '%' || $1 || '%')
	`, query).Scan(&total); err != nil {
		return nil, 0, err
	}

	rows, err := tx.Query(ctx, `
		SELECT id, financial_year_id, invoice_number, customer_id, customer_name_snapshot,
		       subtotal, discount_total, taxable_total, tax_total, rounding_amount, grand_total,
		       payment_status, status, source, client_transaction_id, device_id, cashier_user_id, finalized_at
		FROM sales_invoices
		WHERE status = 'FINALIZED'
		  AND ($1 = '' OR invoice_number ILIKE '%' || $1 || '%' OR customer_name_snapshot ILIKE '%' || $1 || '%')
		ORDER BY finalized_at DESC
		LIMIT $2 OFFSET $3
	`, query, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var out []InvoiceHeader
	for rows.Next() {
		h, err := scanInvoiceHeader(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, *h)
	}
	return out, total, rows.Err()
}

// InvoiceTenderRecord is the read-side shape of one tender line on a
// finalized invoice, for the reprint/detail view.
type InvoiceTenderRecord struct {
	Method    string
	Amount    decimal.Decimal
	Reference *string
}

func ListTenders(ctx context.Context, tx pgx.Tx, invoiceID uuid.UUID) ([]InvoiceTenderRecord, error) {
	rows, err := tx.Query(ctx, `
		SELECT tender_method, amount, reference FROM invoice_tenders WHERE invoice_id = $1
	`, invoiceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []InvoiceTenderRecord
	for rows.Next() {
		var t InvoiceTenderRecord
		if err := rows.Scan(&t.Method, &t.Amount, &t.Reference); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func GetUOMCode(ctx context.Context, tx pgx.Tx, uomID uuid.UUID) (string, error) {
	var code string
	err := tx.QueryRow(ctx, `SELECT code FROM uoms WHERE id = $1`, uomID).Scan(&code)
	return code, err
}
