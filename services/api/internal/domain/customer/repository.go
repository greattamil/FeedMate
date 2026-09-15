package customer

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"
)

var ErrNotFound = errors.New("customer not found")

type Customer struct {
	ID            uuid.UUID
	CustomerCode  string
	Name          string
	LocalName     *string
	Phone         *string
	WhatsAppPhone *string
	CustomerType  string
	TierID        *uuid.UUID
	Status        string
}

func GetByID(ctx context.Context, tx pgx.Tx, id uuid.UUID) (*Customer, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, customer_code, name, local_name, phone, whatsapp_phone, customer_type, tier_id, status
		FROM customers WHERE id = $1
	`, id)
	return scanCustomer(row)
}

func scanCustomer(row pgx.Row) (*Customer, error) {
	var c Customer
	if err := row.Scan(&c.ID, &c.CustomerCode, &c.Name, &c.LocalName, &c.Phone, &c.WhatsAppPhone, &c.CustomerType, &c.TierID, &c.Status); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &c, nil
}

// Create inserts a new customer. If creditLimit is non-nil, a matching
// customer_credit_profiles row is created in the same statement group so a
// credit-eligible customer (e.g. a registered farmer) never has a moment
// where its credit limit is undefined — GetCreditProfile's zero-limit
// fallback exists for customers that were never meant to have credit, not as
// a substitute for actually configuring one.
func Create(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, c *Customer, creditLimit *decimal.Decimal) error {
	row := tx.QueryRow(ctx, `
		INSERT INTO customers (tenant_id, customer_code, name, local_name, phone, whatsapp_phone, customer_type, tier_id, status)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,'ACTIVE')
		RETURNING id, status
	`, tenantID, c.CustomerCode, c.Name, c.LocalName, c.Phone, c.WhatsAppPhone, c.CustomerType, c.TierID)
	if err := row.Scan(&c.ID, &c.Status); err != nil {
		return err
	}
	if creditLimit != nil {
		_, err := tx.Exec(ctx, `
			INSERT INTO customer_credit_profiles (customer_id, tenant_id, credit_limit)
			VALUES ($1, $2, $3)
		`, c.ID, tenantID, *creditLimit)
		if err != nil {
			return err
		}
	}
	return nil
}

// WalkInCustomerCode identifies the one reserved, auto-created customer row
// per tenant that every sale with no captured customer is billed against —
// see GetOrCreateWalkIn's doc comment for why this exists.
const WalkInCustomerCode = "WALK-IN"

// GetOrCreateWalkIn returns the tenant's "Walking Customer" — a real,
// permanent customer row (customer_type WALK_IN, zero credit limit) that
// exists so a sale can never be billed with no customer attached at all,
// without forcing the cashier to pick or create a real customer record for
// every anonymous cash sale. It is looked up by a fixed, well-known
// customer_code and lazily created on first use per tenant (there is no
// tenant-provisioning step that seeds it up front). Never used for a
// CREDIT tender — pos.Service.FinalizeInvoice only calls this for
// non-credit sales; extending shared credit to an anonymous bucket with no
// single accountable customer would defeat the entire point of a credit
// limit.
func GetOrCreateWalkIn(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID) (*Customer, error) {
	c, err := getByCode(ctx, tx, tenantID, WalkInCustomerCode)
	if err == nil {
		return c, nil
	}
	if !errors.Is(err, ErrNotFound) {
		return nil, err
	}
	// Insert then re-select rather than RETURNING, so a race between two
	// concurrent first-sales (both missing the row) resolves to the same
	// row instead of a duplicate-key error on the second insert.
	_, err = tx.Exec(ctx, `
		INSERT INTO customers (tenant_id, customer_code, name, customer_type, status)
		VALUES ($1, $2, 'Walking Customer', 'WALK_IN', 'ACTIVE')
		ON CONFLICT (tenant_id, customer_code) DO NOTHING
	`, tenantID, WalkInCustomerCode)
	if err != nil {
		return nil, err
	}
	return getByCode(ctx, tx, tenantID, WalkInCustomerCode)
}

func getByCode(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, code string) (*Customer, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, customer_code, name, local_name, phone, whatsapp_phone, customer_type, tier_id, status
		FROM customers WHERE tenant_id = $1 AND customer_code = $2
	`, tenantID, code)
	return scanCustomer(row)
}

// List returns active, non-walk-in customers, optionally filtered by a
// case-insensitive substring match on name/customer_code/phone (for a
// customer picker's search box). Ordered by name for a stable, predictable
// picker list. The Walking Customer is deliberately excluded here by its
// reserved customer_code (WalkInCustomerCode) — never by customer_type,
// since "WALK_IN" is also this table's default customer_type for any
// ordinary customer nobody bothered to categorize (see the column default
// and Service.Create's fallback), so plenty of real, named customers can
// legitimately carry that same type. customer_code is unique per tenant
// and only ever assigned this reserved value by GetOrCreateWalkIn, so it's
// the only safe discriminator. The Walking Customer is excluded here
// because it's an automatic fallback for a sale with nobody picked, never
// something a cashier should explicitly select, and it can never carry a
// CREDIT tender (see pos.Service.FinalizeInvoice's walk-in exclusion) —
// showing it in a credit-customer picker would only invite that mistake.
func List(ctx context.Context, tx pgx.Tx, query string, limit int) ([]Customer, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	rows, err := tx.Query(ctx, `
		SELECT id, customer_code, name, local_name, phone, whatsapp_phone, customer_type, tier_id, status
		FROM customers
		WHERE status = 'ACTIVE'
		  AND customer_code != $3
		  AND ($1 = '' OR name ILIKE '%' || $1 || '%' OR customer_code ILIKE '%' || $1 || '%' OR phone ILIKE '%' || $1 || '%')
		ORDER BY name
		LIMIT $2
	`, query, limit, WalkInCustomerCode)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Customer
	for rows.Next() {
		var c Customer
		if err := rows.Scan(&c.ID, &c.CustomerCode, &c.Name, &c.LocalName, &c.Phone, &c.WhatsAppPhone, &c.CustomerType, &c.TierID, &c.Status); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// SetCreditLimit creates or updates a customer's credit profile. Callers must
// gate this behind the credit.configure permission — see PRD 10.1: credit
// limits are master data governed by explicit authorization, never something
// a cashier can silently change mid-sale.
func SetCreditLimit(ctx context.Context, tx pgx.Tx, tenantID, customerID uuid.UUID, creditLimit decimal.Decimal, updatedByUserID uuid.UUID) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO customer_credit_profiles (customer_id, tenant_id, credit_limit, updated_by_user_id, updated_at)
		VALUES ($1, $2, $3, $4, now())
		ON CONFLICT (customer_id) DO UPDATE SET credit_limit = EXCLUDED.credit_limit, updated_by_user_id = EXCLUDED.updated_by_user_id, updated_at = now()
	`, customerID, tenantID, creditLimit, updatedByUserID)
	return err
}

// CreditProfile mirrors customer_credit_profiles. A customer with no row here
// has zero credit (credit_allowed defaults closed, not open).
type CreditProfile struct {
	CreditLimit           decimal.Decimal
	OverrideRequiredAbove *decimal.Decimal
	RiskStatus            string
}

func GetCreditProfile(ctx context.Context, tx pgx.Tx, customerID uuid.UUID) (*CreditProfile, error) {
	row := tx.QueryRow(ctx, `
		SELECT credit_limit, override_required_above, risk_status
		FROM customer_credit_profiles WHERE customer_id = $1
	`, customerID)
	var cp CreditProfile
	if err := row.Scan(&cp.CreditLimit, &cp.OverrideRequiredAbove, &cp.RiskStatus); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			zero := decimal.Zero
			return &CreditProfile{CreditLimit: zero, RiskStatus: "NORMAL"}, nil
		}
		return nil, err
	}
	return &cp, nil
}

// OutstandingBalance is the authoritative customer receivable balance,
// derived from the append-only ledger (debits - credits) — never a
// separately maintained, independently editable field (PRD 10.1).
func OutstandingBalance(ctx context.Context, tx pgx.Tx, customerID uuid.UUID) (decimal.Decimal, error) {
	row := tx.QueryRow(ctx, `
		SELECT COALESCE(SUM(debit),0) - COALESCE(SUM(credit),0)
		FROM customer_ledger_entries WHERE customer_id = $1
	`, customerID)
	var balance decimal.Decimal
	err := row.Scan(&balance)
	return balance, err
}

type LedgerEntry struct {
	CustomerID      uuid.UUID
	DocumentType    string
	DocumentID      uuid.UUID
	Debit           decimal.Decimal
	Credit          decimal.Decimal
	Description     string
	DeviceID        *uuid.UUID
	CreatedByUserID *uuid.UUID
}

// LedgerEntryRecord is one posted row as returned to a Khata statement view —
// LedgerEntry above is the write-side shape; this is the read-side shape,
// including the server-generated id/entry_date that a caller building a new
// entry doesn't have yet.
type LedgerEntryRecord struct {
	ID           uuid.UUID
	EntryDate    time.Time
	DocumentType string
	DocumentID   uuid.UUID
	Debit        decimal.Decimal
	Credit       decimal.Decimal
	Description  *string
}

// ListLedger returns a customer's ledger entries newest-first, for a Khata
// statement view. Never aggregated or netted here — OutstandingBalance is
// the authoritative running total; this is the itemized history behind it.
func ListLedger(ctx context.Context, tx pgx.Tx, customerID uuid.UUID, limit int) ([]LedgerEntryRecord, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	// Ordered by seq, not entry_date: entry_date defaults to now(), which
	// Postgres freezes for the whole transaction, so two entries posted in
	// the same transaction would otherwise tie and fall back to comparing
	// random UUIDs. seq is a bigserial — monotonically increasing regardless
	// of transaction timing, so it reflects true posting order.
	rows, err := tx.Query(ctx, `
		SELECT id, entry_date, document_type, document_id, debit, credit, description
		FROM customer_ledger_entries
		WHERE customer_id = $1
		ORDER BY seq DESC
		LIMIT $2
	`, customerID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []LedgerEntryRecord
	for rows.Next() {
		var r LedgerEntryRecord
		if err := rows.Scan(&r.ID, &r.EntryDate, &r.DocumentType, &r.DocumentID, &r.Debit, &r.Credit, &r.Description); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// PostLedgerEntry appends one immutable ledger row. Debits increase the
// customer's receivable (e.g. a credit sale); credits decrease it (e.g. a
// receipt). Corrections must be posted as a compensating entry, never an
// UPDATE of a posted row.
func PostLedgerEntry(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, e LedgerEntry) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO customer_ledger_entries (
			tenant_id, customer_id, document_type, document_id, debit, credit, description,
			device_id, created_by_user_id
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		RETURNING id
	`, tenantID, e.CustomerID, e.DocumentType, e.DocumentID, e.Debit, e.Credit, e.Description,
		e.DeviceID, e.CreatedByUserID).Scan(&id)
	return id, err
}
