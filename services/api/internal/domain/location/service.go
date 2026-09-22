package location

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
)

var ErrValidation = fmt.Errorf("validation error")

// validLocationTypes mirrors the inventory_locations.location_type CHECK
// constraint in db/migrations/0005_locations_procurement.up.sql exactly.
var validLocationTypes = map[string]bool{
	"SHOP":       true,
	"GODOWN":     true,
	"TRANSIT":    true,
	"QUARANTINE": true,
	"RETURN":     true,
}

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

func (s *Service) ListActive(ctx context.Context, tenantID uuid.UUID) ([]Location, error) {
	var result []Location
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		result, err = ListActive(ctx, tx)
		return err
	})
	return result, err
}

// ListAll includes inactive locations — the dedicated management screen,
// where a shop owner needs to see (and potentially reactivate) every
// location ever created, not just what's currently assignable to a GRN.
func (s *Service) ListAll(ctx context.Context, tenantID uuid.UUID) ([]Location, error) {
	var result []Location
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		result, err = ListAll(ctx, tx)
		return err
	})
	return result, err
}

func validate(code, name, locationType string) error {
	if code == "" {
		return fmt.Errorf("%w: code is required", ErrValidation)
	}
	if name == "" {
		return fmt.Errorf("%w: name is required", ErrValidation)
	}
	if !validLocationTypes[locationType] {
		return fmt.Errorf("%w: location_type must be one of SHOP, GODOWN, TRANSIT, QUARANTINE, RETURN", ErrValidation)
	}
	return nil
}

// Create adds a new inventory location (shop counter, godown/warehouse,
// transit, quarantine, or returns area) — previously there was no way to
// add one beyond a developer inserting a row directly, which is exactly
// why a brand-new tenant with zero locations had no way to receive stock
// at all.
func (s *Service) Create(ctx context.Context, tenantID uuid.UUID, code, name, locationType string) (*Location, error) {
	if err := validate(code, name, locationType); err != nil {
		return nil, err
	}
	var l *Location
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		l, err = Create(ctx, tx, tenantID, code, name, locationType)
		return err
	})
	if err != nil {
		return nil, err
	}
	return l, nil
}

// Update renames a location and/or changes its type in place (never its
// code, matching this project's convention of keeping an assigned
// identifier immutable once stock movements/batches may already
// reference it by location_id).
func (s *Service) Update(ctx context.Context, tenantID, id uuid.UUID, name, locationType string) error {
	if name == "" {
		return fmt.Errorf("%w: name is required", ErrValidation)
	}
	if !validLocationTypes[locationType] {
		return fmt.Errorf("%w: location_type must be one of SHOP, GODOWN, TRANSIT, QUARANTINE, RETURN", ErrValidation)
	}
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		return Update(ctx, tx, id, name, locationType)
	})
}

// SetActive activates or deactivates a location — never a hard delete,
// since historical batches/stock movements may reference it by id.
func (s *Service) SetActive(ctx context.Context, tenantID, id uuid.UUID, active bool) error {
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		return SetActive(ctx, tx, id, active)
	})
}
