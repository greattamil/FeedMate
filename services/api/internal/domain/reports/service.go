package reports

import (
	"context"
	"time"

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

func (s *Service) SalesSummary(ctx context.Context, tenantID uuid.UUID, dateFrom, dateTo time.Time) (*SalesSummary, error) {
	var result *SalesSummary
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		result, err = GetSalesSummary(ctx, tx, dateFrom, dateTo)
		return err
	})
	return result, err
}

func (s *Service) StockOnHand(ctx context.Context, tenantID uuid.UUID, locationID *uuid.UUID) ([]StockOnHandLine, error) {
	var result []StockOnHandLine
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		result, err = GetStockOnHand(ctx, tx, locationID)
		return err
	})
	return result, err
}

func (s *Service) StockSummary(ctx context.Context, tenantID uuid.UUID, locationID *uuid.UUID) ([]StockSummaryLine, error) {
	var result []StockSummaryLine
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		result, err = GetStockSummary(ctx, tx, locationID)
		return err
	})
	return result, err
}

func (s *Service) CustomerBalances(ctx context.Context, tenantID uuid.UUID) ([]CustomerBalance, error) {
	var result []CustomerBalance
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		result, err = GetCustomerBalances(ctx, tx)
		return err
	})
	return result, err
}

func (s *Service) EODHistory(ctx context.Context, tenantID uuid.UUID, dateFrom, dateTo time.Time) ([]EODHistoryEntry, error) {
	var result []EODHistoryEntry
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		result, err = GetEODHistory(ctx, tx, dateFrom, dateTo)
		return err
	})
	return result, err
}
