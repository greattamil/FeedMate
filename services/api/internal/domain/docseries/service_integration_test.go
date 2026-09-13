//go:build integration

// Integration tests against a real, migrated PostgreSQL database. Run with:
//   go test -tags=integration ./internal/domain/docseries/...
// Requires DATABASE_URL (app_user) and DATABASE_ADMIN_URL (app_admin).
package docseries_test

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/accounting"
	"github.com/andipatti/feedmate/services/api/internal/domain/docseries"
)

func mustEnv(t *testing.T, key string) string {
	t.Helper()
	v := os.Getenv(key)
	if v == "" {
		t.Skipf("%s not set; skipping integration test", key)
	}
	return v
}

func connectTest(t *testing.T) *dbctx.DB {
	t.Helper()
	dsn := mustEnv(t, "DATABASE_URL")
	adminDSN := mustEnv(t, "DATABASE_ADMIN_URL")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	db, err := dbctx.Connect(ctx, dsn, adminDSN)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	return db
}

func seedTenantAndUser(t *testing.T, db *dbctx.DB) (uuid.UUID, uuid.UUID) {
	t.Helper()
	tenantID := uuid.New()
	userID := uuid.New()
	err := db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
		ctx := context.Background()
		if _, err := tx.Exec(ctx, `INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'DocSeries Test Tenant','1 St','Town','TN')`, tenantID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO users (id, tenant_id, username, password_hash, display_name, status) VALUES ($1,$2,'docseriesuser','x','DocSeries Test User','ACTIVE')`, userID, tenantID)
		return err
	})
	if err != nil {
		t.Fatalf("seed tenant/user: %v", err)
	}
	t.Cleanup(func() {
		_ = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			_, err := tx.Exec(context.Background(), `DELETE FROM tenants WHERE id = $1`, tenantID)
			return err
		})
	})
	return tenantID, userID
}

func TestCreateFinancialYear_ClosesAnyPriorOpenYear(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenantAndUser(t, db)
	svc := docseries.NewService(db)

	fy1, err := svc.CreateFinancialYear(context.Background(), tenantID, userID, "FY2526",
		time.Date(2025, 4, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 3, 31, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("create first financial year: %v", err)
	}

	// Confirms the "current" year is resolvable at all before a second one exists.
	err = db.WithTenantReadTx(context.Background(), tenantID, func(tx pgx.Tx) error {
		active, err := accounting.GetActiveFinancialYear(context.Background(), tx, tenantID)
		if err != nil {
			return err
		}
		if active != fy1 {
			t.Fatalf("expected active year to be fy1, got %s", active)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("check active year after first create: %v", err)
	}

	fy2, err := svc.CreateFinancialYear(context.Background(), tenantID, userID, "FY2627",
		time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC), time.Date(2027, 3, 31, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("create second financial year: %v", err)
	}

	years, err := svc.ListFinancialYears(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list financial years: %v", err)
	}
	var fy1Status, fy2Status string
	for _, y := range years {
		if y.ID == fy1 {
			fy1Status = y.Status
		}
		if y.ID == fy2 {
			fy2Status = y.Status
		}
	}
	if fy1Status != "CLOSED" {
		t.Fatalf("expected fy1 to be auto-closed when fy2 opened, got %s", fy1Status)
	}
	if fy2Status != "OPEN" {
		t.Fatalf("expected fy2 to be OPEN, got %s", fy2Status)
	}

	// The active year the rest of the system resolves must now be fy2, not fy1.
	err = db.WithTenantReadTx(context.Background(), tenantID, func(tx pgx.Tx) error {
		active, err := accounting.GetActiveFinancialYear(context.Background(), tx, tenantID)
		if err != nil {
			return err
		}
		if active != fy2 {
			t.Fatalf("expected active year to be fy2 after opening it, got %s", active)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("check active year after second create: %v", err)
	}

	if _, err := svc.CreateFinancialYear(context.Background(), tenantID, userID, "", time.Now(), time.Now().AddDate(1, 0, 0)); !errors.Is(err, docseries.ErrValidation) {
		t.Fatalf("expected ErrValidation for empty label, got: %v", err)
	}
	if _, err := svc.CreateFinancialYear(context.Background(), tenantID, userID, "BadDates", time.Now(), time.Now()); !errors.Is(err, docseries.ErrValidation) {
		t.Fatalf("expected ErrValidation for end_date not after start_date, got: %v", err)
	}
}

func TestCreateDocumentSeries_DeactivatesPriorActiveSeriesOfSameType(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenantAndUser(t, db)
	svc := docseries.NewService(db)

	fyID, err := svc.CreateFinancialYear(context.Background(), tenantID, userID, "FY2526",
		time.Date(2025, 4, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 3, 31, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("create financial year: %v", err)
	}

	series1, err := svc.CreateDocumentSeries(context.Background(), tenantID, userID, fyID, "INVOICE", "INV-2526-", 1, 5)
	if err != nil {
		t.Fatalf("create first invoice series: %v", err)
	}

	// Simulate a mid-year prefix change (e.g. correcting a typo'd prefix).
	series2, err := svc.CreateDocumentSeries(context.Background(), tenantID, userID, fyID, "INVOICE", "INV/2526/", 500, 4)
	if err != nil {
		t.Fatalf("create second invoice series: %v", err)
	}

	all, err := svc.ListDocumentSeries(context.Background(), tenantID, fyID)
	if err != nil {
		t.Fatalf("list document series: %v", err)
	}
	var series1Active, series2Active bool
	for _, s := range all {
		if s.ID == series1 {
			series1Active = s.Active
		}
		if s.ID == series2 {
			series2Active = s.Active
			if s.NextNumber != 500 || s.Padding != 4 {
				t.Fatalf("expected the new series' own starting number/padding, got %+v", s)
			}
		}
	}
	if series1Active {
		t.Fatal("expected the first (superseded) series to be deactivated")
	}
	if !series2Active {
		t.Fatal("expected the second (newest) series to be active")
	}

	if _, err := svc.CreateDocumentSeries(context.Background(), tenantID, userID, fyID, "NOT_A_TYPE", "X-", 1, 5); !errors.Is(err, docseries.ErrValidation) {
		t.Fatalf("expected ErrValidation for an invalid document_type, got: %v", err)
	}
	if _, err := svc.CreateDocumentSeries(context.Background(), tenantID, userID, fyID, "INVOICE", "", 1, 5); !errors.Is(err, docseries.ErrValidation) {
		t.Fatalf("expected ErrValidation for an empty prefix, got: %v", err)
	}
	if _, err := svc.CreateDocumentSeries(context.Background(), tenantID, userID, fyID, "INVOICE", "X-", 0, 5); !errors.Is(err, docseries.ErrValidation) {
		t.Fatalf("expected ErrValidation for a starting_number below 1, got: %v", err)
	}
}

func TestSeedDefaultSeries_CoversCoreDocumentTypesAndNeverDuplicates(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenantAndUser(t, db)
	svc := docseries.NewService(db)

	fyID, err := svc.CreateFinancialYear(context.Background(), tenantID, userID, "FY2526",
		time.Date(2025, 4, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 3, 31, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("create financial year: %v", err)
	}

	created, err := svc.SeedDefaultSeries(context.Background(), tenantID, userID, fyID, "2526")
	if err != nil {
		t.Fatalf("seed default series: %v", err)
	}
	if len(created) != 5 {
		t.Fatalf("expected 5 default series created (INVOICE/GRN/RETURN/CONTRA/RECEIPT), got %d: %+v", len(created), created)
	}

	// Re-seeding must not duplicate or disturb an already-active series.
	second, err := svc.SeedDefaultSeries(context.Background(), tenantID, userID, fyID, "2526")
	if err != nil {
		t.Fatalf("re-seed default series: %v", err)
	}
	if len(second) != 0 {
		t.Fatalf("expected re-seeding to create nothing new, got %+v", second)
	}

	all, err := svc.ListDocumentSeries(context.Background(), tenantID, fyID)
	if err != nil {
		t.Fatalf("list document series: %v", err)
	}
	if len(all) != 5 {
		t.Fatalf("expected exactly 5 series after re-seeding (no duplicates), got %d", len(all))
	}

	// This is the exact failure this package exists to prevent: allocating a
	// real invoice number must now succeed without any manual SQL.
	err = db.WithTenantTx(context.Background(), tenantID, func(tx pgx.Tx) error {
		fy, err := accounting.GetActiveFinancialYear(context.Background(), tx, tenantID)
		if err != nil {
			return err
		}
		if fy != fyID {
			t.Fatalf("expected active financial year to be the one just created")
		}
		return nil
	})
	if err != nil {
		t.Fatalf("resolve active financial year: %v", err)
	}
}

func TestSetDocumentSeriesActive_AndCloseFinancialYear(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenantAndUser(t, db)
	svc := docseries.NewService(db)

	fyID, err := svc.CreateFinancialYear(context.Background(), tenantID, userID, "FY2526",
		time.Date(2025, 4, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 3, 31, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("create financial year: %v", err)
	}
	seriesID, err := svc.CreateDocumentSeries(context.Background(), tenantID, userID, fyID, "GRN", "GRN-2526-", 1, 5)
	if err != nil {
		t.Fatalf("create series: %v", err)
	}

	if err := svc.SetDocumentSeriesActive(context.Background(), tenantID, seriesID, false); err != nil {
		t.Fatalf("deactivate series: %v", err)
	}
	all, err := svc.ListDocumentSeries(context.Background(), tenantID, fyID)
	if err != nil {
		t.Fatalf("list series: %v", err)
	}
	if len(all) != 1 || all[0].Active {
		t.Fatalf("expected the series to be inactive, got %+v", all)
	}

	if err := svc.CloseFinancialYear(context.Background(), tenantID, userID, fyID); err != nil {
		t.Fatalf("close financial year: %v", err)
	}
	years, err := svc.ListFinancialYears(context.Background(), tenantID)
	if err != nil {
		t.Fatalf("list years: %v", err)
	}
	if len(years) != 1 || years[0].Status != "CLOSED" || years[0].ClosedAt == nil {
		t.Fatalf("expected the year to be CLOSED with a closed_at timestamp, got %+v", years)
	}

	if err := svc.CloseFinancialYear(context.Background(), tenantID, userID, uuid.New()); !errors.Is(err, docseries.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a nonexistent financial year, got: %v", err)
	}
}
