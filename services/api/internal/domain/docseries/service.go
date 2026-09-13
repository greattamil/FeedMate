// Package docseries provides admin control over the two setup rows every
// posting path in this system silently depends on: a financial year (see
// accounting.GetActiveFinancialYear) and, within it, an active document
// series per document type (see e.g. pos.AllocateInvoiceNumber). Before
// this package existed, both had to be seeded by hand with raw SQL — a
// missing row surfaced only as an opaque INTERNAL_ERROR at the moment a
// cashier tried to finalize a sale (see docs/IMPLEMENTATION_STATUS.md's
// Phase 24/25 notes on exactly that failure mode). This package exists so
// that failure class can never happen again from the app.
package docseries

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
)

var (
	ErrValidation = errors.New("validation error")
)

// defaultDocumentTypes mirrors document_series' own CHECK constraint —
// every type a financial year needs a series for to support the app's
// full feature set (INVOICE for sales, GRN for procurement, RETURN for
// sales returns, CONTRA for buy-back, RECEIPT for manual Khata receipts).
var defaultDocumentTypes = []string{"INVOICE", "GRN", "RETURN", "CONTRA", "RECEIPT"}

var validDocumentTypes = map[string]bool{
	"INVOICE": true, "CREDIT_NOTE": true, "DEBIT_NOTE": true, "PO": true,
	"GRN": true, "RECEIPT": true, "RETURN": true, "CONTRA": true,
}

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

func (s *Service) ListFinancialYears(ctx context.Context, tenantID uuid.UUID) ([]FinancialYear, error) {
	var years []FinancialYear
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		years, err = ListFinancialYears(ctx, tx)
		return err
	})
	return years, err
}

// CreateFinancialYear opens a new financial year, closing any other
// currently-OPEN year first (see CloseAllOpenFinancialYears's doc comment
// on why more than one OPEN year at a time is never valid).
func (s *Service) CreateFinancialYear(ctx context.Context, tenantID, userID uuid.UUID, label string, startDate, endDate time.Time) (uuid.UUID, error) {
	if label == "" {
		return uuid.Nil, fmt.Errorf("%w: label is required", ErrValidation)
	}
	if !endDate.After(startDate) {
		return uuid.Nil, fmt.Errorf("%w: end_date must be after start_date", ErrValidation)
	}

	var id uuid.UUID
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if err := CloseAllOpenFinancialYears(ctx, tx); err != nil {
			return fmt.Errorf("close prior open financial years: %w", err)
		}
		newID, err := InsertFinancialYear(ctx, tx, tenantID, label, startDate, endDate)
		if err != nil {
			return fmt.Errorf("insert financial year: %w", err)
		}
		id = newID
		_, err = tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, entity_id, after_json)
			VALUES ($1,$2,'FINANCIAL_YEAR_OPENED','financial_year',$3,$4)
		`, tenantID, userID, id, map[string]interface{}{"label": label, "start_date": startDate.Format("2006-01-02"), "end_date": endDate.Format("2006-01-02")})
		return err
	})
	if err != nil {
		return uuid.Nil, err
	}
	return id, nil
}

func (s *Service) CloseFinancialYear(ctx context.Context, tenantID, userID, financialYearID uuid.UUID) error {
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if err := CloseFinancialYear(ctx, tx, financialYearID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, entity_id)
			VALUES ($1,$2,'FINANCIAL_YEAR_CLOSED','financial_year',$3)
		`, tenantID, userID, financialYearID)
		return err
	})
}

func (s *Service) ListDocumentSeries(ctx context.Context, tenantID, financialYearID uuid.UUID) ([]DocumentSeries, error) {
	var series []DocumentSeries
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		series, err = ListDocumentSeries(ctx, tx, financialYearID)
		return err
	})
	return series, err
}

// CreateDocumentSeries activates a new series for one document type within
// a financial year, deactivating whatever series of that same type was
// previously active (see DeactivateSeriesForType's doc comment on why two
// active series of the same type is never valid).
func (s *Service) CreateDocumentSeries(ctx context.Context, tenantID, userID, financialYearID uuid.UUID, documentType, prefix string, startingNumber int64, padding int) (uuid.UUID, error) {
	if !validDocumentTypes[documentType] {
		return uuid.Nil, fmt.Errorf("%w: invalid document_type %q", ErrValidation, documentType)
	}
	if prefix == "" {
		return uuid.Nil, fmt.Errorf("%w: prefix is required", ErrValidation)
	}
	if startingNumber < 1 {
		return uuid.Nil, fmt.Errorf("%w: starting_number must be at least 1", ErrValidation)
	}
	if padding < 1 || padding > 10 {
		return uuid.Nil, fmt.Errorf("%w: padding must be between 1 and 10", ErrValidation)
	}

	var id uuid.UUID
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if err := DeactivateSeriesForType(ctx, tx, financialYearID, documentType); err != nil {
			return fmt.Errorf("deactivate prior series: %w", err)
		}
		newID, err := InsertDocumentSeries(ctx, tx, tenantID, financialYearID, documentType, prefix, startingNumber, padding)
		if err != nil {
			return fmt.Errorf("insert document series: %w", err)
		}
		id = newID
		_, err = tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, entity_id, after_json)
			VALUES ($1,$2,'DOCUMENT_SERIES_CREATED','document_series',$3,$4)
		`, tenantID, userID, id, map[string]interface{}{"document_type": documentType, "prefix": prefix, "starting_number": startingNumber, "padding": padding})
		return err
	})
	if err != nil {
		return uuid.Nil, err
	}
	return id, nil
}

func (s *Service) SetDocumentSeriesActive(ctx context.Context, tenantID, id uuid.UUID, active bool) error {
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		return SetDocumentSeriesActive(ctx, tx, id, active)
	})
}

// SeedDefaultSeries creates an active series for every core document type
// (defaultDocumentTypes) a fresh financial year needs, all sharing one
// consistent prefix style derived from the year's own label — the
// one-click fix for the exact failure mode this package exists to prevent.
// Document types that already have an active series in this year are left
// untouched rather than silently replaced.
func (s *Service) SeedDefaultSeries(ctx context.Context, tenantID, userID, financialYearID uuid.UUID, labelPrefix string) ([]DocumentSeries, error) {
	var created []DocumentSeries
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		existing, err := ListDocumentSeries(ctx, tx, financialYearID)
		if err != nil {
			return err
		}
		hasActive := make(map[string]bool, len(existing))
		for _, e := range existing {
			if e.Active {
				hasActive[e.DocumentType] = true
			}
		}
		for _, docType := range defaultDocumentTypes {
			if hasActive[docType] {
				continue
			}
			prefix := fmt.Sprintf("%s-%s-", docType, labelPrefix)
			id, err := InsertDocumentSeries(ctx, tx, tenantID, financialYearID, docType, prefix, 1, 5)
			if err != nil {
				return fmt.Errorf("seed default series for %s: %w", docType, err)
			}
			created = append(created, DocumentSeries{
				ID: id, FinancialYearID: financialYearID, DocumentType: docType,
				Prefix: prefix, NextNumber: 1, Padding: 5, Active: true,
			})
		}
		if len(created) > 0 {
			payload := make([]string, 0, len(created))
			for _, c := range created {
				payload = append(payload, c.DocumentType)
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, entity_id, after_json)
				VALUES ($1,$2,'DOCUMENT_SERIES_SEEDED','financial_year',$3,$4)
			`, tenantID, userID, financialYearID, map[string]interface{}{"document_types": payload}); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return created, nil
}
