package auditlog

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Entry is one row of the append-only audit trail — every explicit-reasoned
// override (credit limit, tare threshold), EOD close/reopen, and other
// sensitive action across the system writes here (see e.g.
// eod.Service.CloseSession, pos.Service.FinalizeInvoice's credit override).
// This package only ever reads it; nothing here ever inserts or mutates a
// row, since the whole point of an audit trail is that it is never itself
// editable.
type Entry struct {
	ID          uuid.UUID
	ActorUserID *uuid.UUID
	ActorName   *string
	ActionCode  string
	EntityType  string
	EntityID    *uuid.UUID
	Reason      *string
	BeforeJSON  []byte
	AfterJSON   []byte
	CreatedAt   time.Time
}

// List returns audit log entries newest-first, optionally filtered by a
// case-insensitive substring match on action_code or entity_type, and/or an
// exact entity_id. RLS (tenant_isolation_nullable) already restricts rows to
// the caller's tenant plus any tenant-less system rows.
func List(ctx context.Context, tx pgx.Tx, query string, entityID *uuid.UUID, limit, offset int) ([]Entry, int, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	var total int
	if err := tx.QueryRow(ctx, `
		SELECT COUNT(*) FROM audit_logs a
		WHERE ($1 = '' OR a.action_code ILIKE '%' || $1 || '%' OR a.entity_type ILIKE '%' || $1 || '%')
		  AND ($2::uuid IS NULL OR a.entity_id = $2)
	`, query, entityID).Scan(&total); err != nil {
		return nil, 0, err
	}

	rows, err := tx.Query(ctx, `
		SELECT a.id, a.actor_user_id, u.display_name, a.action_code, a.entity_type, a.entity_id,
		       a.reason, a.before_json, a.after_json, a.created_at
		FROM audit_logs a
		LEFT JOIN users u ON u.id = a.actor_user_id
		WHERE ($1 = '' OR a.action_code ILIKE '%' || $1 || '%' OR a.entity_type ILIKE '%' || $1 || '%')
		  AND ($2::uuid IS NULL OR a.entity_id = $2)
		ORDER BY a.created_at DESC, a.id DESC
		LIMIT $3 OFFSET $4
	`, query, entityID, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var out []Entry
	for rows.Next() {
		var e Entry
		if err := rows.Scan(&e.ID, &e.ActorUserID, &e.ActorName, &e.ActionCode, &e.EntityType, &e.EntityID,
			&e.Reason, &e.BeforeJSON, &e.AfterJSON, &e.CreatedAt); err != nil {
			return nil, 0, err
		}
		out = append(out, e)
	}
	return out, total, rows.Err()
}
