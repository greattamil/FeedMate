package customer

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
)

var ErrValidation = fmt.Errorf("validation error")

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

// validCustomerTypes mirrors the customers_customer_type_check constraint in
// db/migrations/0004_customer_supplier.up.sql exactly — WALK_IN is
// deliberately excluded from what a caller may explicitly request, since
// it's the reserved type for the one auto-created Walking Customer row
// (see GetOrCreateWalkIn) and the column's own default for anything
// uncategorized, never something a real, named customer should be
// knowingly assigned.
var validCustomerTypes = map[string]bool{
	"FARMER":              true,
	"WHOLESALE_DEALER":    true,
	"AAVIN_SUBCONTRACTOR": true,
	"OTHER":               true,
}

type CreateInput struct {
	CustomerCode  string
	Name          string
	LocalName     string
	Phone         string
	WhatsAppPhone string
	Email         string
	GSTIN         string
	CustomerType  string
	CreditLimit   *decimal.Decimal // nil = no credit extended (walk-in/cash-only)
}

func (s *Service) Create(ctx context.Context, tenantID uuid.UUID, in CreateInput) (*Customer, error) {
	if in.Name == "" {
		return nil, fmt.Errorf("%w: name is required", ErrValidation)
	}
	if in.CustomerCode == "" {
		return nil, fmt.Errorf("%w: customer_code is required", ErrValidation)
	}
	if in.CustomerType == "" {
		in.CustomerType = "OTHER"
	} else if !validCustomerTypes[in.CustomerType] {
		return nil, fmt.Errorf("%w: customer_type must be one of FARMER, WHOLESALE_DEALER, AAVIN_SUBCONTRACTOR, OTHER", ErrValidation)
	}
	if in.CreditLimit != nil && in.CreditLimit.LessThan(decimal.Zero) {
		return nil, fmt.Errorf("%w: credit_limit cannot be negative", ErrValidation)
	}

	c := &Customer{CustomerCode: in.CustomerCode, Name: in.Name, CustomerType: in.CustomerType}
	if in.LocalName != "" {
		c.LocalName = &in.LocalName
	}
	if in.Phone != "" {
		c.Phone = &in.Phone
	}
	if in.WhatsAppPhone != "" {
		c.WhatsAppPhone = &in.WhatsAppPhone
	}
	if in.Email != "" {
		c.Email = &in.Email
	}
	if in.GSTIN != "" {
		c.GSTIN = &in.GSTIN
	}

	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		return Create(ctx, tx, tenantID, c, in.CreditLimit)
	})
	if err != nil {
		return nil, err
	}
	return c, nil
}

type UpdateInput struct {
	Name          string
	LocalName     string
	Phone         string
	WhatsAppPhone string
	Email         string
	GSTIN         string
	CustomerType  string
}

// Update revises a customer's editable fields (never customer_code — see
// repository.Update's doc comment).
func (s *Service) Update(ctx context.Context, tenantID, customerID uuid.UUID, in UpdateInput) (*Customer, error) {
	if in.Name == "" {
		return nil, fmt.Errorf("%w: name is required", ErrValidation)
	}
	if in.CustomerType != "" && !validCustomerTypes[in.CustomerType] {
		return nil, fmt.Errorf("%w: customer_type must be one of FARMER, WHOLESALE_DEALER, AAVIN_SUBCONTRACTOR, OTHER", ErrValidation)
	}

	var updated *Customer
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		existing, err := GetByID(ctx, tx, customerID)
		if err != nil {
			return err
		}
		existing.Name = in.Name
		if in.CustomerType != "" {
			existing.CustomerType = in.CustomerType
		}
		existing.LocalName = nil
		if in.LocalName != "" {
			existing.LocalName = &in.LocalName
		}
		existing.Phone = nil
		if in.Phone != "" {
			existing.Phone = &in.Phone
		}
		existing.WhatsAppPhone = nil
		if in.WhatsAppPhone != "" {
			existing.WhatsAppPhone = &in.WhatsAppPhone
		}
		existing.Email = nil
		if in.Email != "" {
			existing.Email = &in.Email
		}
		existing.GSTIN = nil
		if in.GSTIN != "" {
			existing.GSTIN = &in.GSTIN
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

// SetActive activates or deactivates a customer — never a hard delete, since
// historical invoice/ledger rows reference it (mirrors supplier.SetActive).
func (s *Service) SetActive(ctx context.Context, tenantID, customerID uuid.UUID, active bool) (*Customer, error) {
	var updated *Customer
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if err := SetActive(ctx, tx, customerID, active); err != nil {
			return err
		}
		var err error
		updated, err = GetByID(ctx, tx, customerID)
		return err
	})
	if err != nil {
		return nil, err
	}
	return updated, nil
}

func (s *Service) GetByID(ctx context.Context, tenantID, customerID uuid.UUID) (*Customer, *CreditProfile, decimal.Decimal, error) {
	var (
		c       *Customer
		profile *CreditProfile
		balance decimal.Decimal
	)
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		c, err = GetByID(ctx, tx, customerID)
		if err != nil {
			return err
		}
		profile, err = GetCreditProfile(ctx, tx, customerID)
		if err != nil {
			return err
		}
		balance, err = OutstandingBalance(ctx, tx, customerID)
		return err
	})
	if err != nil {
		return nil, nil, decimal.Zero, err
	}
	return c, profile, balance, nil
}

func (s *Service) List(ctx context.Context, tenantID uuid.UUID, query string, limit int) ([]Customer, error) {
	var result []Customer
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		result, err = List(ctx, tx, query, limit)
		return err
	})
	return result, err
}

// ListLedger returns a customer's Khata statement (itemized ledger entries).
// The customer's existence is checked first purely to give a clean
// ErrNotFound rather than an empty list for a bad/foreign customer id.
func (s *Service) ListLedger(ctx context.Context, tenantID, customerID uuid.UUID, limit int) ([]LedgerEntryRecord, error) {
	var result []LedgerEntryRecord
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		if _, err := GetByID(ctx, tx, customerID); err != nil {
			return err
		}
		var err error
		result, err = ListLedger(ctx, tx, customerID, limit)
		return err
	})
	return result, err
}

// SetCreditLimit is gated by the caller on credit.configure — this service
// method performs no permission check itself, matching every other module's
// convention of enforcing RBAC at the HTTP layer.
func (s *Service) SetCreditLimit(ctx context.Context, tenantID, customerID, updatedByUserID uuid.UUID, creditLimit decimal.Decimal) error {
	if creditLimit.LessThan(decimal.Zero) {
		return fmt.Errorf("%w: credit_limit cannot be negative", ErrValidation)
	}
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if _, err := GetByID(ctx, tx, customerID); err != nil {
			return err
		}
		if err := SetCreditLimit(ctx, tx, tenantID, customerID, creditLimit, updatedByUserID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, entity_id, after_json)
			VALUES ($1, $2, 'CREDIT_LIMIT_CHANGED', 'customer', $3, $4)
		`, tenantID, updatedByUserID, customerID, map[string]interface{}{"new_credit_limit": creditLimit.String()})
		return err
	})
}
