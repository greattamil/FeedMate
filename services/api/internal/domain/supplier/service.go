package supplier

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/entitycode"
)

var ErrValidation = fmt.Errorf("validation error")

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

type CreateInput struct {
	Name             string
	TradeName        string
	GSTIN            string
	Phone            string
	Email            string
	PaymentTermsDays int
}

func (s *Service) Create(ctx context.Context, tenantID uuid.UUID, in CreateInput) (*Supplier, error) {
	if in.Name == "" {
		return nil, fmt.Errorf("%w: name is required", ErrValidation)
	}
	if in.PaymentTermsDays < 0 {
		return nil, fmt.Errorf("%w: payment_terms_days cannot be negative", ErrValidation)
	}

	sup := &Supplier{Name: in.Name, PaymentTermsDays: in.PaymentTermsDays}
	if in.TradeName != "" {
		sup.TradeName = &in.TradeName
	}
	if in.GSTIN != "" {
		sup.GSTIN = &in.GSTIN
	}
	if in.Phone != "" {
		sup.Phone = &in.Phone
	}
	if in.Email != "" {
		sup.Email = &in.Email
	}

	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		code, err := entitycode.Generate(ctx, tx, tenantID, "supplier", "SUPP", 4)
		if err != nil {
			return err
		}
		sup.SupplierCode = code
		return Create(ctx, tx, tenantID, sup)
	})
	if err != nil {
		return nil, err
	}
	return sup, nil
}

type UpdateInput struct {
	Name             string
	TradeName        string
	GSTIN            string
	Phone            string
	Email            string
	PaymentTermsDays int
}

// Update revises a supplier's editable fields (never supplier_code — see
// repository.Update's doc comment).
func (s *Service) Update(ctx context.Context, tenantID, supplierID uuid.UUID, in UpdateInput) (*Supplier, error) {
	if in.Name == "" {
		return nil, fmt.Errorf("%w: name is required", ErrValidation)
	}
	if in.PaymentTermsDays < 0 {
		return nil, fmt.Errorf("%w: payment_terms_days cannot be negative", ErrValidation)
	}

	var updated *Supplier
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		existing, err := GetByID(ctx, tx, supplierID)
		if err != nil {
			return err
		}
		existing.Name = in.Name
		existing.PaymentTermsDays = in.PaymentTermsDays
		existing.TradeName = nil
		if in.TradeName != "" {
			existing.TradeName = &in.TradeName
		}
		existing.GSTIN = nil
		if in.GSTIN != "" {
			existing.GSTIN = &in.GSTIN
		}
		existing.Phone = nil
		if in.Phone != "" {
			existing.Phone = &in.Phone
		}
		existing.Email = nil
		if in.Email != "" {
			existing.Email = &in.Email
		}
		if err := Update(ctx, tx, existing); err != nil {
			return err
		}
		updated = existing
		return nil
	})
	if err != nil {
		return nil, err
	}
	return updated, nil
}

// SetActive activates or deactivates a supplier — never a hard delete, since
// historical GRN/payment rows reference it (mirrors product.SetActive).
func (s *Service) SetActive(ctx context.Context, tenantID, supplierID uuid.UUID, active bool) (*Supplier, error) {
	var updated *Supplier
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if err := SetActive(ctx, tx, supplierID, active); err != nil {
			return err
		}
		fresh, err := GetByID(ctx, tx, supplierID)
		if err != nil {
			return err
		}
		updated = fresh
		return nil
	})
	if err != nil {
		return nil, err
	}
	return updated, nil
}

func (s *Service) List(ctx context.Context, tenantID uuid.UUID, query string, limit int) ([]Supplier, error) {
	var result []Supplier
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		result, err = List(ctx, tx, query, limit)
		return err
	})
	return result, err
}

func (s *Service) GetByID(ctx context.Context, tenantID, supplierID uuid.UUID) (*Supplier, decimal.Decimal, error) {
	var (
		sup     *Supplier
		balance decimal.Decimal
	)
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		sup, err = GetByID(ctx, tx, supplierID)
		if err != nil {
			return err
		}
		balance, err = OutstandingPayable(ctx, tx, supplierID)
		return err
	})
	if err != nil {
		return nil, decimal.Zero, err
	}
	return sup, balance, nil
}

// ListLedger returns a supplier's payable statement (itemized ledger
// entries). The supplier's existence is checked first purely to give a
// clean ErrNotFound rather than an empty list for a bad/foreign supplier id.
func (s *Service) ListLedger(ctx context.Context, tenantID, supplierID uuid.UUID, limit int) ([]LedgerEntryRecord, error) {
	var result []LedgerEntryRecord
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		if _, err := GetByID(ctx, tx, supplierID); err != nil {
			return err
		}
		var err error
		result, err = ListLedger(ctx, tx, supplierID, limit)
		return err
	})
	return result, err
}
