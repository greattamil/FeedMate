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

// DashboardOverview bundles every metric the detailed analytics dashboard
// needs into one read transaction — sales trend, best sellers, payment
// mix, stock health, receivables/payables with their top few
// debtors/creditors, recent activity, and a today-vs-yesterday comparison
// — so the screen makes one API round trip instead of eight. Every number
// still traces back to the same authoritative tables the rest of this
// package reads (see the package doc comment); this is composition, not a
// new aggregate source of truth.
type DashboardOverview struct {
	Today          *SalesSummary
	Yesterday      *SalesSummary
	Last30Days     *SalesSummary // for the payment-mix breakdown
	SalesTrend     []DailySales
	TopProducts    []TopProduct
	StockHealth    *StockHealth
	Receivables    []CustomerBalance // full list, highest-first; caller may take top N
	Payables       []SupplierBalance // full list, highest-first; caller may take top N
	RecentInvoices []RecentInvoice
}

func (s *Service) DashboardOverview(ctx context.Context, tenantID uuid.UUID) (*DashboardOverview, error) {
	var out DashboardOverview
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		now := time.Now().UTC()
		today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
		yesterday := today.AddDate(0, 0, -1)

		var err error
		if out.Today, err = GetSalesSummary(ctx, tx, today, today); err != nil {
			return err
		}
		if out.Yesterday, err = GetSalesSummary(ctx, tx, yesterday, yesterday); err != nil {
			return err
		}
		if out.Last30Days, err = GetSalesSummary(ctx, tx, today.AddDate(0, 0, -29), today); err != nil {
			return err
		}
		if out.SalesTrend, err = GetSalesTrend(ctx, tx, 14); err != nil {
			return err
		}
		if out.TopProducts, err = GetTopProducts(ctx, tx, 30, 8); err != nil {
			return err
		}
		if out.StockHealth, err = GetStockHealth(ctx, tx); err != nil {
			return err
		}
		if out.Receivables, err = GetCustomerBalances(ctx, tx); err != nil {
			return err
		}
		if out.Payables, err = GetSupplierPayables(ctx, tx); err != nil {
			return err
		}
		if out.RecentInvoices, err = GetRecentInvoices(ctx, tx, 8); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &out, nil
}
