package docseries

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var ErrNotFound = errors.New("not found")

type FinancialYear struct {
	ID        uuid.UUID
	Label     string
	StartDate time.Time
	EndDate   time.Time
	Status    string // OPEN or CLOSED
	ClosedAt  *time.Time
}

func ListFinancialYears(ctx context.Context, tx pgx.Tx) ([]FinancialYear, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, label, start_date, end_date, status, closed_at
		FROM financial_years ORDER BY start_date DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []FinancialYear
	for rows.Next() {
		var f FinancialYear
		if err := rows.Scan(&f.ID, &f.Label, &f.StartDate, &f.EndDate, &f.Status, &f.ClosedAt); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// CloseAllOpenFinancialYears closes every currently-OPEN year — called just
// before opening a new one, since accounting.GetActiveFinancialYear resolves
// "the" active year by picking the most-recently-started OPEN row, which is
// ambiguous the moment more than one is OPEN at once.
func CloseAllOpenFinancialYears(ctx context.Context, tx pgx.Tx) error {
	_, err := tx.Exec(ctx, `UPDATE financial_years SET status = 'CLOSED', closed_at = now() WHERE status = 'OPEN'`)
	return err
}

func InsertFinancialYear(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, label string, startDate, endDate time.Time) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO financial_years (tenant_id, label, start_date, end_date, status)
		VALUES ($1,$2,$3,$4,'OPEN')
		RETURNING id
	`, tenantID, label, startDate, endDate).Scan(&id)
	return id, err
}

func CloseFinancialYear(ctx context.Context, tx pgx.Tx, id uuid.UUID) error {
	tag, err := tx.Exec(ctx, `UPDATE financial_years SET status = 'CLOSED', closed_at = now() WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

type DocumentSeries struct {
	ID              uuid.UUID
	FinancialYearID uuid.UUID
	DocumentType    string
	Prefix          string
	NextNumber      int64
	Padding         int
	Active          bool
}

func ListDocumentSeries(ctx context.Context, tx pgx.Tx, financialYearID uuid.UUID) ([]DocumentSeries, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, financial_year_id, document_type, prefix, next_number, padding, active
		FROM document_series WHERE financial_year_id = $1
		ORDER BY document_type, prefix
	`, financialYearID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []DocumentSeries
	for rows.Next() {
		var d DocumentSeries
		if err := rows.Scan(&d.ID, &d.FinancialYearID, &d.DocumentType, &d.Prefix, &d.NextNumber, &d.Padding, &d.Active); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// DeactivateSeriesForType deactivates every currently-active series of one
// document type within a financial year — called just before activating a
// new one, since every AllocateXNumber function (see e.g.
// pos.AllocateInvoiceNumber) looks up "the" active series with a plain
// `WHERE ... AND active` and takes whatever QueryRow happens to return
// first if more than one row matches, which must never be ambiguous.
func DeactivateSeriesForType(ctx context.Context, tx pgx.Tx, financialYearID uuid.UUID, documentType string) error {
	_, err := tx.Exec(ctx, `
		UPDATE document_series SET active = false, updated_at = now()
		WHERE financial_year_id = $1 AND document_type = $2 AND active
	`, financialYearID, documentType)
	return err
}

func InsertDocumentSeries(ctx context.Context, tx pgx.Tx, tenantID, financialYearID uuid.UUID, documentType, prefix string, nextNumber int64, padding int) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO document_series (tenant_id, financial_year_id, document_type, prefix, next_number, padding, active)
		VALUES ($1,$2,$3,$4,$5,$6,true)
		RETURNING id
	`, tenantID, financialYearID, documentType, prefix, nextNumber, padding).Scan(&id)
	return id, err
}

func SetDocumentSeriesActive(ctx context.Context, tx pgx.Tx, id uuid.UUID, active bool) error {
	tag, err := tx.Exec(ctx, `UPDATE document_series SET active = $2, updated_at = now() WHERE id = $1`, id, active)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
