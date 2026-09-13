package auditlog

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
)

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

type Page struct {
	Entries []Entry
	Total   int
}

// List returns audit log entries for the caller's tenant, newest-first.
func (s *Service) List(ctx context.Context, tenantID uuid.UUID, query string, entityID *uuid.UUID, limit, offset int) (*Page, error) {
	var page Page
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		entries, total, err := List(ctx, tx, query, entityID, limit, offset)
		if err != nil {
			return err
		}
		page.Entries = entries
		page.Total = total
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &page, nil
}
