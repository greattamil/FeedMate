package location

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var ErrNotFound = errors.New("location not found")

type Location struct {
	ID     uuid.UUID
	Code   string
	Name   string
	Type   string
	Active bool
}

func ListActive(ctx context.Context, tx pgx.Tx) ([]Location, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, code, name, location_type FROM inventory_locations WHERE active ORDER BY name
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Location
	for rows.Next() {
		var l Location
		if err := rows.Scan(&l.ID, &l.Code, &l.Name, &l.Type); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// ListAll includes inactive locations too, for the dedicated location
// management screen.
func ListAll(ctx context.Context, tx pgx.Tx) ([]Location, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, code, name, location_type, active FROM inventory_locations ORDER BY name
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Location
	for rows.Next() {
		var l Location
		if err := rows.Scan(&l.ID, &l.Code, &l.Name, &l.Type, &l.Active); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

func Create(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, code, name, locationType string) (*Location, error) {
	l := &Location{Code: code, Name: name, Type: locationType, Active: true}
	err := tx.QueryRow(ctx, `
		INSERT INTO inventory_locations (tenant_id, code, name, location_type)
		VALUES ($1, $2, $3, $4)
		RETURNING id
	`, tenantID, code, name, locationType).Scan(&l.ID)
	if err != nil {
		return nil, err
	}
	return l, nil
}

func Update(ctx context.Context, tx pgx.Tx, id uuid.UUID, name, locationType string) error {
	tag, err := tx.Exec(ctx, `
		UPDATE inventory_locations SET name = $2, location_type = $3, updated_at = now() WHERE id = $1
	`, id, name, locationType)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func SetActive(ctx context.Context, tx pgx.Tx, id uuid.UUID, active bool) error {
	tag, err := tx.Exec(ctx, `UPDATE inventory_locations SET active = $2, updated_at = now() WHERE id = $1`, id, active)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
