// Package notify is the single chokepoint every business-event push
// notification goes through. Nothing else in this codebase should call
// pushnotify.Service directly for a specific business event — this
// package centralizes the two layers of on/off control (the
// platform-admin master switch and the tenant's own per-event
// preferences) and the per-event title/body/channel design, so every
// event gets consistent treatment instead of each call site reinventing
// its own checks and copy.
package notify

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/pushnotify"
)

// EventType is one business event that can trigger a push. Every event
// here must have a case in render() and a column in getNotificationPrefs.
type EventType string

const (
	EventCreditLimitBreach EventType = "credit_limit_breach"
	EventCreditSale        EventType = "credit_sale"
	EventSaleCompleted     EventType = "sale_completed"
	EventLowStock          EventType = "low_stock"
	EventOutOfStock        EventType = "out_of_stock"
	EventPaymentOverdue    EventType = "payment_overdue"
)

// Android notification channel IDs. Must match exactly what the Flutter
// client creates at startup (lib/core/notification_service.dart) — an
// unrecognized channel ID just falls back to Android's default channel
// rather than failing the send, so a mismatch degrades silently; keep
// these two definitions in sync by hand.
const (
	ChannelSalesBilling = "sales_billing"
	ChannelCreditAlerts = "credit_alerts"
	ChannelStockAlerts  = "stock_alerts"
)

// featureCode is the platform-admin tenant_features row (see
// SetTenantFeature in domain/platformadmin) that acts as a hard kill
// switch, overriding every one of the tenant's own preferences below. A
// missing row is treated as enabled, so a tenant that has never been
// touched by a platform admin keeps receiving pushes exactly as before
// this feature existed.
const featureCode = "push_notifications"

type Service struct {
	db   *dbctx.DB
	push *pushnotify.Service
}

func NewService(db *dbctx.DB, push *pushnotify.Service) *Service {
	return &Service{db: db, push: push}
}

// Dispatch checks both layers of on/off control and, if the event passes
// both, sends a rich push built from the given event's template, with
// data carried through unchanged as the deep-link payload the Flutter
// client's notification-tap router switches on (see
// lib/core/notification_service.dart) — callers set data["type"] plus
// whatever ID fields that type's screen needs (e.g.
// {"type":"invoice","invoice_id":...}).
//
// Never surfaces an error to the caller: a notification is explicitly a
// side effect, never load-bearing for the business operation that
// triggered it (the same convention pos.Service.FinalizeInvoice already
// followed for its one hard-coded push before this package existed).
// Callers are expected to invoke this from their own fire-and-forget
// goroutine with a short detached context, exactly as FinalizeInvoice
// does today.
func (s *Service) Dispatch(ctx context.Context, tenantID uuid.UUID, event EventType, data map[string]string) {
	if s.push == nil {
		return
	}

	var (
		masterDisabled bool
		prefs          notificationPrefs
	)
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		masterDisabled, err = isFeatureDisabled(ctx, tx, tenantID, featureCode)
		if err != nil {
			return fmt.Errorf("check master switch: %w", err)
		}
		prefs, err = getNotificationPrefs(ctx, tx, tenantID)
		if err != nil {
			return fmt.Errorf("load notification prefs: %w", err)
		}
		return nil
	})
	if err != nil {
		slog.Warn("notify: preference lookup failed, skipping push", "event", event, "error", err)
		return
	}
	if masterDisabled {
		return
	}
	if !prefs.enabled(event) {
		return
	}

	title, body, channel := render(event, data)
	// channel_id also goes into the data payload, not just the Android-only
	// android.notification.channel_id field: that field is consumed by the
	// OS before message.data is built, so it's invisible to the Flutter
	// client's own foreground handler (see
	// lib/core/notification_service.dart) when the app is open — it needs
	// this to pick the right local-notification channel itself, since FCM
	// only auto-displays via the system tray when backgrounded/killed.
	richData := make(map[string]string, len(data)+1)
	for k, v := range data {
		richData[k] = v
	}
	richData["channel_id"] = channel
	if _, err := s.push.SendToTenantRich(ctx, tenantID, pushnotify.RichMessage{
		Title: title, Body: body, Data: richData, ChannelID: channel,
	}); err != nil {
		slog.Warn("notify: send failed", "event", event, "error", err)
	}
}

// render builds the user-facing title/body and picks the notification
// channel for one event. data's keys are whatever the call site in
// pos.Service/customer.Service populated — see each case below for what
// it expects.
func render(event EventType, data map[string]string) (title, body, channel string) {
	switch event {
	case EventCreditLimitBreach:
		return "Credit limit exceeded",
			fmt.Sprintf("%s's credit sale pushed them to ₹%s, over their ₹%s limit.", data["customer_name"], data["projected"], data["limit"]),
			ChannelCreditAlerts
	case EventCreditSale:
		return "Credit sale recorded",
			fmt.Sprintf("₹%s sold on credit to %s (invoice %s).", data["amount"], data["customer_name"], data["invoice_number"]),
			ChannelSalesBilling
	case EventSaleCompleted:
		return "Sale completed",
			fmt.Sprintf("Invoice %s finalized for ₹%s.", data["invoice_number"], data["amount"]),
			ChannelSalesBilling
	case EventLowStock:
		return "Low stock",
			fmt.Sprintf("%s is down to %s units (reorder level %s).", data["product_name"], data["on_hand"], data["reorder_level"]),
			ChannelStockAlerts
	case EventOutOfStock:
		return "Out of stock",
			fmt.Sprintf("%s is now out of stock.", data["product_name"]),
			ChannelStockAlerts
	case EventPaymentOverdue:
		return "Payment reminders",
			fmt.Sprintf("%s customer(s) overdue, ₹%s outstanding.", data["count"], data["total"]),
			ChannelCreditAlerts
	default:
		return "FeedMate", "", ChannelSalesBilling
	}
}

type notificationPrefs struct {
	saleCompleted     bool
	creditSale        bool
	creditLimitBreach bool
	lowStock          bool
	outOfStock        bool
	paymentOverdue    bool
}

func (p notificationPrefs) enabled(event EventType) bool {
	switch event {
	case EventSaleCompleted:
		return p.saleCompleted
	case EventCreditSale:
		return p.creditSale
	case EventCreditLimitBreach:
		return p.creditLimitBreach
	case EventLowStock:
		return p.lowStock
	case EventOutOfStock:
		return p.outOfStock
	case EventPaymentOverdue:
		return p.paymentOverdue
	default:
		return false
	}
}

func getNotificationPrefs(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID) (notificationPrefs, error) {
	row := tx.QueryRow(ctx, `
		SELECT notify_sale_completed, notify_credit_sale, notify_credit_limit_breach,
		       notify_low_stock, notify_out_of_stock, notify_payment_overdue
		FROM tenant_settings WHERE tenant_id = $1
	`, tenantID)
	var p notificationPrefs
	err := row.Scan(&p.saleCompleted, &p.creditSale, &p.creditLimitBreach, &p.lowStock, &p.outOfStock, &p.paymentOverdue)
	if errors.Is(err, pgx.ErrNoRows) {
		// No tenant_settings row should never happen for a real tenant, but
		// fail safe to the same defaults the migration itself gives new
		// rows (everything on except sale_completed) rather than silently
		// going fully dark.
		return notificationPrefs{creditSale: true, creditLimitBreach: true, lowStock: true, outOfStock: true, paymentOverdue: true}, nil
	}
	return p, err
}

func isFeatureDisabled(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, code string) (bool, error) {
	var enabled bool
	err := tx.QueryRow(ctx, `SELECT enabled FROM tenant_features WHERE tenant_id = $1 AND feature_code = $2`, tenantID, code).Scan(&enabled)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return !enabled, nil
}
