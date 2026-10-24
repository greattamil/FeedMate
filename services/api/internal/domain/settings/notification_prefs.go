package settings

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

// NotificationPrefs is the shop's own per-event push-notification
// preferences (tenant_settings — see migration 0031), independent of the
// platform-admin "push_notifications" tenant_features master switch,
// which overrides all of these when disabled. SaleCompleted defaults
// false (see migration 0031's doc comment); every other field defaults
// true.
type NotificationPrefs struct {
	SaleCompleted     bool `json:"notify_sale_completed"`
	CreditSale        bool `json:"notify_credit_sale"`
	CreditLimitBreach bool `json:"notify_credit_limit_breach"`
	LowStock          bool `json:"notify_low_stock"`
	OutOfStock        bool `json:"notify_out_of_stock"`
	PaymentOverdue    bool `json:"notify_payment_overdue"`
}

func getNotificationPrefs(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID) (NotificationPrefs, error) {
	var p NotificationPrefs
	err := tx.QueryRow(ctx, `
		SELECT notify_sale_completed, notify_credit_sale, notify_credit_limit_breach,
		       notify_low_stock, notify_out_of_stock, notify_payment_overdue
		FROM tenant_settings WHERE tenant_id = $1
	`, tenantID).Scan(&p.SaleCompleted, &p.CreditSale, &p.CreditLimitBreach, &p.LowStock, &p.OutOfStock, &p.PaymentOverdue)
	return p, err
}

func updateNotificationPrefs(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, p NotificationPrefs) error {
	_, err := tx.Exec(ctx, `
		UPDATE tenant_settings SET
			notify_sale_completed = $2, notify_credit_sale = $3, notify_credit_limit_breach = $4,
			notify_low_stock = $5, notify_out_of_stock = $6, notify_payment_overdue = $7,
			updated_at = now()
		WHERE tenant_id = $1
	`, tenantID, p.SaleCompleted, p.CreditSale, p.CreditLimitBreach, p.LowStock, p.OutOfStock, p.PaymentOverdue)
	return err
}

func (s *Service) GetNotificationPrefs(ctx context.Context, tenantID uuid.UUID) (NotificationPrefs, error) {
	var p NotificationPrefs
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		p, err = getNotificationPrefs(ctx, tx, tenantID)
		return err
	})
	return p, err
}

// UpdateNotificationPrefs persists the shop's six per-event push toggles
// in one go, auditing the before/after state the same way
// UpdateStoreProfile does.
func (s *Service) UpdateNotificationPrefs(ctx context.Context, tenantID, userID uuid.UUID, p NotificationPrefs) error {
	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		before, err := getNotificationPrefs(ctx, tx, tenantID)
		if err != nil {
			return err
		}
		if err := updateNotificationPrefs(ctx, tx, tenantID, p); err != nil {
			return err
		}
		reqID, ip, ua := reqctx.AuditFields(ctx)
		_, err = tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, entity_id, before_json, after_json, request_id, ip_address, user_agent)
			VALUES ($1,$2,'NOTIFICATION_PREFS_UPDATED','tenant',$1,$3,$4,$5,$6,$7)
		`, tenantID, userID, before, p, reqID, ip, ua)
		return err
	})
}
