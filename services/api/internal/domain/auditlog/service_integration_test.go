//go:build integration

package auditlog_test

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/auditlog"
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
		if _, err := tx.Exec(ctx, `INSERT INTO tenants (id, legal_name, address_line1, city, state_code) VALUES ($1,'Audit Test Tenant','1 St','Town','TN')`, tenantID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO users (id, tenant_id, username, password_hash, display_name, status) VALUES ($1,$2,'audituser','x','Audit Test User','ACTIVE')`, userID, tenantID)
		return err
	})
	if err != nil {
		t.Fatalf("seed tenant/user: %v", err)
	}
	t.Cleanup(func() {
		_ = db.WithAdminTx(context.Background(), func(tx pgx.Tx) error {
			ctx := context.Background()
			for _, stmt := range []string{
				`DELETE FROM audit_logs WHERE tenant_id = $1`,
				`DELETE FROM users WHERE tenant_id = $1`,
				`DELETE FROM tenants WHERE id = $1`,
			} {
				if _, err := tx.Exec(ctx, stmt, tenantID); err != nil {
					return err
				}
			}
			return nil
		})
	})
	return tenantID, userID
}

func TestList_ReturnsNewestFirstAndFiltersByQueryAndEntity(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantID, userID := seedTenantAndUser(t, db)
	svc := auditlog.NewService(db)

	entityID := uuid.New()
	// Seeded in two separate transactions (rather than batched in one) so
	// each gets its own now() — audit_logs has no seq column to break ties
	// the way the customer/supplier ledgers do, so same-transaction inserts
	// would otherwise share one created_at and leave the newest-first order
	// undefined.
	err := db.WithTenantTx(context.Background(), tenantID, func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, entity_id, reason, after_json)
			VALUES ($1,$2,'EOD_CLOSED','eod_session',$3,NULL,'{"expected_cash":"3520.00"}')
		`, tenantID, userID, entityID)
		return err
	})
	if err != nil {
		t.Fatalf("seed first audit entry: %v", err)
	}
	time.Sleep(10 * time.Millisecond)
	err = db.WithTenantTx(context.Background(), tenantID, func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, entity_id, reason, after_json)
			VALUES ($1,$2,'CREDIT_LIMIT_OVERRIDE','invoice',$3,'Regular customer, approved by owner','{"override":true}')
		`, tenantID, userID, uuid.New())
		return err
	})
	if err != nil {
		t.Fatalf("seed second audit entry: %v", err)
	}

	page, err := svc.List(context.Background(), tenantID, "", nil, 10, 0)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if page.Total != 2 {
		t.Fatalf("expected total 2, got %d", page.Total)
	}
	// Newest-first: CREDIT_LIMIT_OVERRIDE was inserted second.
	if page.Entries[0].ActionCode != "CREDIT_LIMIT_OVERRIDE" || page.Entries[1].ActionCode != "EOD_CLOSED" {
		t.Fatalf("expected newest-first order, got %+v", page.Entries)
	}
	if page.Entries[0].ActorName == nil || *page.Entries[0].ActorName != "Audit Test User" {
		t.Fatalf("expected actor name to be joined in, got %+v", page.Entries[0].ActorName)
	}

	byAction, err := svc.List(context.Background(), tenantID, "EOD_CLOSED", nil, 10, 0)
	if err != nil {
		t.Fatalf("list by action: %v", err)
	}
	if len(byAction.Entries) != 1 || byAction.Entries[0].ActionCode != "EOD_CLOSED" {
		t.Fatalf("expected exactly the matching entry, got %+v", byAction.Entries)
	}

	byEntity, err := svc.List(context.Background(), tenantID, "", &entityID, 10, 0)
	if err != nil {
		t.Fatalf("list by entity: %v", err)
	}
	if len(byEntity.Entries) != 1 || byEntity.Entries[0].EntityID == nil || *byEntity.Entries[0].EntityID != entityID {
		t.Fatalf("expected exactly the matching entity, got %+v", byEntity.Entries)
	}
}

func TestList_TenantIsolation(t *testing.T) {
	db := connectTest(t)
	defer db.Close()
	tenantA, userA := seedTenantAndUser(t, db)
	tenantB, _ := seedTenantAndUser(t, db)
	svc := auditlog.NewService(db)

	err := db.WithTenantTx(context.Background(), tenantA, func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type)
			VALUES ($1,$2,'TENANT_A_ACTION','test_entity')
		`, tenantA, userA)
		return err
	})
	if err != nil {
		t.Fatalf("seed tenant A entry: %v", err)
	}

	pageB, err := svc.List(context.Background(), tenantB, "", nil, 10, 0)
	if err != nil {
		t.Fatalf("list for tenant B: %v", err)
	}
	for _, e := range pageB.Entries {
		if e.ActionCode == "TENANT_A_ACTION" {
			t.Fatalf("tenant B must never see tenant A's audit entries (RLS failure)")
		}
	}
}
