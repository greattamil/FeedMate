// Package entitycode generates short, readable, sequential codes
// (CUST-0001, SUPP-0001, ...) for master-data entities that previously
// required a shop owner to type a unique code by hand — a real source of
// friction and duplicate-code errors at data entry time. One counter row
// per (tenant, entity type) is incremented atomically via an upsert, so
// concurrent creates from two devices never race to the same number.
package entitycode

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Next atomically allocates and returns the next sequence number for
// (tenantID, entityType), creating the counter row starting at 1 if this
// is the first code ever requested for that pair.
func Next(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, entityType string) (int, error) {
	var n int
	err := tx.QueryRow(ctx, `
		INSERT INTO entity_code_counters (tenant_id, entity_type, next_number)
		VALUES ($1, $2, 2)
		ON CONFLICT (tenant_id, entity_type)
		DO UPDATE SET next_number = entity_code_counters.next_number + 1
		RETURNING next_number - 1
	`, tenantID, entityType).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("allocate next code for %s: %w", entityType, err)
	}
	return n, nil
}

// Generate returns a zero-padded, prefixed code like "CUST-0001" for the
// next number in (tenantID, entityType)'s sequence.
func Generate(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, entityType, prefix string, padding int) (string, error) {
	n, err := Next(ctx, tx, tenantID, entityType)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%s-%0*d", prefix, padding, n), nil
}
