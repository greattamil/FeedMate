package location

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type Location struct {
	ID   uuid.UUID
	Code string
	Name string
	Type string
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
