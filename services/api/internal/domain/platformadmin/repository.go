package platformadmin

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/andipatti/feedmate/services/api/internal/reqctx"
)

var ErrNotFound = errors.New("not found")

type PlatformAdmin struct {
	ID           uuid.UUID
	Username     string
	PasswordHash string
	DisplayName  string
	Status       string
}

func FindPlatformAdminByUsername(ctx context.Context, tx pgx.Tx, username string) (*PlatformAdmin, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, username, password_hash, display_name, status
		FROM platform_admins WHERE username = $1
	`, username)
	var a PlatformAdmin
	if err := row.Scan(&a.ID, &a.Username, &a.PasswordHash, &a.DisplayName, &a.Status); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &a, nil
}

func CreateSession(ctx context.Context, tx pgx.Tx, platformAdminID uuid.UUID, refreshHash string, expiresAt time.Time) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO platform_admin_sessions (platform_admin_id, refresh_token_hash, expires_at)
		VALUES ($1,$2,$3)
	`, platformAdminID, refreshHash, expiresAt)
	return err
}

// ResolveSession returns the platform admin owning a still-valid (unexpired,
// unrevoked) refresh token hash, mirroring identity.ResolveSession's shape.
// GetPlatformAdminDisplayName is used by Service.Refresh so a refreshed
// session's response carries the same display_name a fresh Login would —
// ResolveSession only has the admin's ID, not their display name.
func GetPlatformAdminDisplayName(ctx context.Context, tx pgx.Tx, id uuid.UUID) (string, error) {
	var name string
	row := tx.QueryRow(ctx, `SELECT display_name FROM platform_admins WHERE id = $1`, id)
	if err := row.Scan(&name); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", ErrNotFound
		}
		return "", err
	}
	return name, nil
}

func ResolveSession(ctx context.Context, tx pgx.Tx, refreshHash string) (uuid.UUID, error) {
	var platformAdminID uuid.UUID
	row := tx.QueryRow(ctx, `
		SELECT platform_admin_id FROM platform_admin_sessions
		WHERE refresh_token_hash = $1 AND revoked_at IS NULL AND expires_at > now()
	`, refreshHash)
	if err := row.Scan(&platformAdminID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return uuid.Nil, ErrNotFound
		}
		return uuid.Nil, err
	}
	return platformAdminID, nil
}

func RevokeSession(ctx context.Context, tx pgx.Tx, refreshHash string) error {
	_, err := tx.Exec(ctx, `UPDATE platform_admin_sessions SET revoked_at = now() WHERE refresh_token_hash = $1`, refreshHash)
	return err
}

// TenantSummary is one row of the platform admin's tenant list.
type TenantSummary struct {
	ID            uuid.UUID
	LegalName     string
	TradeName     *string
	City          string
	Status        string
	PlanCode      string
	PlanExpiresAt *time.Time
	CreatedAt     time.Time
	UserCount     int
}

func ListTenants(ctx context.Context, tx pgx.Tx) ([]TenantSummary, error) {
	rows, err := tx.Query(ctx, `
		SELECT t.id, t.legal_name, t.trade_name, t.city, t.status, t.plan_code, t.plan_expires_at, t.created_at,
		       (SELECT count(*) FROM users u WHERE u.tenant_id = t.id) AS user_count
		FROM tenants t
		ORDER BY t.created_at DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TenantSummary
	for rows.Next() {
		var s TenantSummary
		if err := rows.Scan(&s.ID, &s.LegalName, &s.TradeName, &s.City, &s.Status, &s.PlanCode, &s.PlanExpiresAt, &s.CreatedAt, &s.UserCount); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// TenantDetail is the full tenant record plus its feature flags, for the
// platform admin's tenant detail/edit screen.
type TenantDetail struct {
	TenantSummary
	GSTIN          *string
	FSSAILicenseNo *string
	AddressLine1   string
	AddressLine2   *string
	District       *string
	PostalCode     *string
	StateCode      string
	Phone          *string
	Email          *string
	AppDisplayName *string
	LogoURL        *string
	PrimaryColor   *string
	Features       map[string]bool
}

func GetTenant(ctx context.Context, tx pgx.Tx, id uuid.UUID) (*TenantDetail, error) {
	row := tx.QueryRow(ctx, `
		SELECT id, legal_name, trade_name, gstin, fssai_license_no,
		       address_line1, address_line2, city, district, state_code, postal_code, phone, email, status,
		       plan_code, plan_expires_at, app_display_name, logo_url, primary_color, created_at,
		       (SELECT count(*) FROM users u WHERE u.tenant_id = tenants.id) AS user_count
		FROM tenants WHERE id = $1
	`, id)
	var d TenantDetail
	if err := row.Scan(
		&d.ID, &d.LegalName, &d.TradeName, &d.GSTIN, &d.FSSAILicenseNo,
		&d.AddressLine1, &d.AddressLine2, &d.City, &d.District, &d.StateCode, &d.PostalCode, &d.Phone, &d.Email, &d.Status,
		&d.PlanCode, &d.PlanExpiresAt, &d.AppDisplayName, &d.LogoURL, &d.PrimaryColor, &d.CreatedAt, &d.UserCount,
	); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	features, err := listTenantFeatures(ctx, tx, id)
	if err != nil {
		return nil, err
	}
	d.Features = features
	return &d, nil
}

// UpdateTenantInput is every tenant-identity field a platform admin can
// correct after creation — unlike SetTenantStatus/SetTenantPlan/
// SetTenantBranding/SetTenantFeature (narrow, single-purpose), this covers
// the legal/contact fields CreateTenant sets once at provisioning time and
// nothing since has been able to edit.
type UpdateTenantInput struct {
	LegalName      string
	TradeName      string
	GSTIN          string
	FSSAILicenseNo string
	AddressLine1   string
	AddressLine2   string
	City           string
	District       string
	StateCode      string
	PostalCode     string
	Phone          string
	Email          string
}

func UpdateTenant(ctx context.Context, tx pgx.Tx, id uuid.UUID, in UpdateTenantInput) error {
	tag, err := tx.Exec(ctx, `
		UPDATE tenants SET
			legal_name = $2, trade_name = $3, gstin = $4, fssai_license_no = $5,
			address_line1 = $6, address_line2 = $7, city = $8, district = $9, state_code = $10, postal_code = $11,
			phone = $12, email = $13, updated_at = now()
		WHERE id = $1
	`, id, in.LegalName, nullIfEmpty(in.TradeName), nullIfEmpty(in.GSTIN), nullIfEmpty(in.FSSAILicenseNo),
		in.AddressLine1, nullIfEmpty(in.AddressLine2), in.City, nullIfEmpty(in.District), in.StateCode, nullIfEmpty(in.PostalCode),
		nullIfEmpty(in.Phone), nullIfEmpty(in.Email))
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func listTenantFeatures(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID) (map[string]bool, error) {
	rows, err := tx.Query(ctx, `SELECT feature_code, enabled FROM tenant_features WHERE tenant_id = $1`, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var code string
		var enabled bool
		if err := rows.Scan(&code, &enabled); err != nil {
			return nil, err
		}
		out[code] = enabled
	}
	return out, rows.Err()
}

func SetTenantStatus(ctx context.Context, tx pgx.Tx, id uuid.UUID, status string) error {
	tag, err := tx.Exec(ctx, `UPDATE tenants SET status = $2, updated_at = now() WHERE id = $1`, id, status)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func SetTenantPlan(ctx context.Context, tx pgx.Tx, id uuid.UUID, planCode string, expiresAt *time.Time) error {
	tag, err := tx.Exec(ctx, `UPDATE tenants SET plan_code = $2, plan_expires_at = $3, updated_at = now() WHERE id = $1`, id, planCode, expiresAt)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func SetTenantBranding(ctx context.Context, tx pgx.Tx, id uuid.UUID, appDisplayName, logoURL, primaryColor *string) error {
	tag, err := tx.Exec(ctx, `
		UPDATE tenants SET app_display_name = $2, logo_url = $3, primary_color = $4, updated_at = now() WHERE id = $1
	`, id, appDisplayName, logoURL, primaryColor)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func SetTenantFeature(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, featureCode string, enabled bool) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO tenant_features (tenant_id, feature_code, enabled, updated_at)
		VALUES ($1,$2,$3,now())
		ON CONFLICT (tenant_id, feature_code) DO UPDATE SET enabled = $3, updated_at = now()
	`, tenantID, featureCode, enabled)
	return err
}

// CreateTenantInput bootstraps a brand-new tenant end-to-end: the tenant
// record, its settings row, an "Owner" role holding every permission in the
// system catalogue, the current financial year, a default document-numbering
// series for every document type, and the first Owner user — everything a
// client needs to actually start using the app, none of it left for a
// developer to patch in by hand via direct SQL (see IMPLEMENTATION_STATUS's
// device-pairing emergency, which is exactly the gap this closes).
type CreateTenantInput struct {
	LegalName     string
	TradeName     string
	AddressLine1  string
	City          string
	StateCode     string
	Phone         string
	Email         string
	PlanCode      string
	OwnerUsername string
	OwnerPassword string
	OwnerName     string
}

func InsertTenant(ctx context.Context, tx pgx.Tx, in CreateTenantInput) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO tenants (legal_name, trade_name, address_line1, city, state_code, phone, email, plan_code)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		RETURNING id
	`, in.LegalName, nullIfEmpty(in.TradeName), in.AddressLine1, in.City, in.StateCode,
		nullIfEmpty(in.Phone), nullIfEmpty(in.Email), in.PlanCode).Scan(&id)
	return id, err
}

func InsertTenantSettings(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID) error {
	_, err := tx.Exec(ctx, `INSERT INTO tenant_settings (tenant_id) VALUES ($1)`, tenantID)
	return err
}

// InsertOwnerRoleWithAllPermissions creates the tenant's first role, granted
// every permission in the global catalogue — every other role a tenant
// later creates is deliberately narrower than this.
func InsertOwnerRoleWithAllPermissions(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID) (uuid.UUID, error) {
	var roleID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO roles (tenant_id, name, description, is_system_role) VALUES ($1,'Owner','Full access to everything',true)
		RETURNING id
	`, tenantID).Scan(&roleID); err != nil {
		return uuid.Nil, err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO role_permissions (tenant_id, role_id, permission_id) SELECT $1, $2, id FROM permissions
	`, tenantID, roleID); err != nil {
		return uuid.Nil, err
	}
	return roleID, nil
}

func InsertFinancialYear(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID, label string, start, end time.Time) (uuid.UUID, error) {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO financial_years (tenant_id, label, start_date, end_date, status)
		VALUES ($1,$2,$3,$4,'OPEN')
		RETURNING id
	`, tenantID, label, start, end).Scan(&id)
	return id, err
}

func InsertDocumentSeries(ctx context.Context, tx pgx.Tx, tenantID, financialYearID uuid.UUID, documentType, prefix string) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO document_series (tenant_id, financial_year_id, document_type, prefix, next_number, padding)
		VALUES ($1,$2,$3,$4,1,4)
	`, tenantID, financialYearID, documentType, prefix)
	return err
}

func InsertOwnerUser(ctx context.Context, tx pgx.Tx, tenantID, roleID uuid.UUID, username, passwordHash, displayName string) (uuid.UUID, error) {
	var userID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO users (tenant_id, username, password_hash, display_name, status) VALUES ($1,$2,$3,$4,'ACTIVE')
		RETURNING id
	`, tenantID, username, passwordHash, displayName).Scan(&userID); err != nil {
		return uuid.Nil, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO user_roles (tenant_id, user_id, role_id) VALUES ($1,$2,$3)`, tenantID, userID, roleID); err != nil {
		return uuid.Nil, err
	}
	return userID, nil
}

// InsertCrossTenantAuditLog records a platform admin's action against a
// specific tenant's resources (password reset, device revoke, pairing-code
// generation, user create/edit) — attributed by actor_platform_admin_id
// rather than actor_user_id, since a platform admin is never a row in
// `users` (see migration 0026). afterJSON may be nil.
func InsertCrossTenantAuditLog(ctx context.Context, tx pgx.Tx, tenantID, platformAdminID uuid.UUID, actionCode, entityType string, entityID *uuid.UUID, reason string, afterJSON interface{}) error {
	reqID, ip, ua := reqctx.AuditFields(ctx)
	_, err := tx.Exec(ctx, `
		INSERT INTO audit_logs (tenant_id, actor_platform_admin_id, action_code, entity_type, entity_id, reason, after_json, request_id, ip_address, user_agent)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
	`, tenantID, platformAdminID, actionCode, entityType, entityID, nullIfEmpty(reason), afterJSON, reqID, ip, ua)
	return err
}

func nullIfEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// AuditLogEntry mirrors auditlog.Entry but is used for the cross-tenant
// platform listing, which also needs the tenant's name (a per-tenant
// listing has no reason to show it, since it's implicit).
// AuditLogEntry is one full-detail audit-log row — every field the schema
// actually captures, including the ones (before_json/after_json/
// actor_device_id/actor_platform_admin_id/request_id/ip_address/
// user_agent) this query previously silently dropped even though many
// rows already had them populated.
type AuditLogEntry struct {
	ID                     uuid.UUID
	TenantID               *uuid.UUID
	TenantName             *string
	ActorUserID            *uuid.UUID
	ActorName              *string
	ActorDeviceID          *uuid.UUID
	ActorPlatformAdminID   *uuid.UUID
	ActorPlatformAdminName *string
	ActionCode             string
	EntityType             string
	EntityID               *uuid.UUID
	BeforeJSON             []byte
	AfterJSON              []byte
	Reason                 *string
	RequestID              *uuid.UUID
	IPAddress              *string
	UserAgent              *string
	CreatedAt              time.Time
}

// AuditLogFilter narrows ListAuditLogsAllTenants — every field optional.
type AuditLogFilter struct {
	ActionCode string
	EntityType string
	TenantID   *uuid.UUID
	From       *time.Time
	To         *time.Time
	Query      string // substring match against action_code/reason/tenant/actor name
}

func ListAuditLogsAllTenants(ctx context.Context, tx pgx.Tx, filter AuditLogFilter, limit, offset int) ([]AuditLogEntry, int, error) {
	where := "WHERE ($1 = '' OR a.action_code = $1) AND ($2 = '' OR a.entity_type = $2) AND ($3::uuid IS NULL OR a.tenant_id = $3) " +
		"AND ($4::timestamptz IS NULL OR a.created_at >= $4) AND ($5::timestamptz IS NULL OR a.created_at <= $5) " +
		"AND ($6 = '' OR a.action_code ILIKE '%' || $6 || '%' OR a.reason ILIKE '%' || $6 || '%' " +
		"     OR t.legal_name ILIKE '%' || $6 || '%' OR u.display_name ILIKE '%' || $6 || '%')"
	args := []interface{}{filter.ActionCode, filter.EntityType, filter.TenantID, filter.From, filter.To, filter.Query}
	fromJoin := `
		FROM audit_logs a
		LEFT JOIN tenants t ON t.id = a.tenant_id
		LEFT JOIN users u ON u.id = a.actor_user_id
		LEFT JOIN platform_admins pa ON pa.id = a.actor_platform_admin_id
	`

	var total int
	if err := tx.QueryRow(ctx, "SELECT count(*) "+fromJoin+" "+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	args = append(args, limit, offset)
	rows, err := tx.Query(ctx, `
		SELECT a.id, a.tenant_id, t.legal_name, a.actor_user_id, u.display_name, a.actor_device_id,
		       a.actor_platform_admin_id, pa.display_name, a.action_code, a.entity_type, a.entity_id,
		       a.before_json, a.after_json, a.reason, a.request_id, a.ip_address::text, a.user_agent, a.created_at
		`+fromJoin+where+`
		ORDER BY a.created_at DESC
		LIMIT $7 OFFSET $8
	`, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []AuditLogEntry
	for rows.Next() {
		var e AuditLogEntry
		if err := rows.Scan(&e.ID, &e.TenantID, &e.TenantName, &e.ActorUserID, &e.ActorName, &e.ActorDeviceID,
			&e.ActorPlatformAdminID, &e.ActorPlatformAdminName, &e.ActionCode, &e.EntityType, &e.EntityID,
			&e.BeforeJSON, &e.AfterJSON, &e.Reason, &e.RequestID, &e.IPAddress, &e.UserAgent, &e.CreatedAt); err != nil {
			return nil, 0, err
		}
		out = append(out, e)
	}
	return out, total, rows.Err()
}

// ErrorLogEntry is one full-debug-level error-log row — every error this
// API ever returns gets one of these (not just 500s/panics), so the
// platform admin's error log screen never has to guess what happened from
// a bare status code and a one-line message.
type ErrorLogEntry struct {
	ID                   uuid.UUID
	RequestID            *uuid.UUID
	StatusCode           int
	Code                 *string
	Message              string
	Method               *string
	Path                 *string
	QueryParams          *string
	RequestBody          []byte
	IPAddress            *string
	UserAgent            *string
	TenantID             *uuid.UUID
	ActorUserID          *uuid.UUID
	ActorPlatformAdminID *uuid.UUID
	StackTrace           *string
	CreatedAt            time.Time
}

// ErrorLogFilter narrows ListErrorLogs — every field is optional (zero
// value = no filter on that dimension).
type ErrorLogFilter struct {
	StatusCode *int
	Code       string
	Method     string
	From       *time.Time
	To         *time.Time
	Query      string // substring match against path or message
}

func ListErrorLogs(ctx context.Context, tx pgx.Tx, filter ErrorLogFilter, limit, offset int) ([]ErrorLogEntry, int, error) {
	where := "WHERE ($1::int IS NULL OR status_code = $1) AND ($2 = '' OR code = $2) AND ($3 = '' OR method = $3) " +
		"AND ($4::timestamptz IS NULL OR created_at >= $4) AND ($5::timestamptz IS NULL OR created_at <= $5) " +
		"AND ($6 = '' OR path ILIKE '%' || $6 || '%' OR message ILIKE '%' || $6 || '%')"
	args := []interface{}{filter.StatusCode, filter.Code, filter.Method, filter.From, filter.To, filter.Query}

	var total int
	if err := tx.QueryRow(ctx, "SELECT count(*) FROM error_logs "+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	args = append(args, limit, offset)
	rows, err := tx.Query(ctx, `
		SELECT id, request_id, status_code, code, message, method, path, query_params, request_body,
		       ip_address::text, user_agent, tenant_id, actor_user_id, actor_platform_admin_id, stack_trace, created_at
		FROM error_logs `+where+`
		ORDER BY created_at DESC
		LIMIT $7 OFFSET $8
	`, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []ErrorLogEntry
	for rows.Next() {
		var e ErrorLogEntry
		if err := rows.Scan(&e.ID, &e.RequestID, &e.StatusCode, &e.Code, &e.Message, &e.Method, &e.Path, &e.QueryParams,
			&e.RequestBody, &e.IPAddress, &e.UserAgent, &e.TenantID, &e.ActorUserID, &e.ActorPlatformAdminID, &e.StackTrace, &e.CreatedAt); err != nil {
			return nil, 0, err
		}
		out = append(out, e)
	}
	return out, total, rows.Err()
}

// RecordErrorInput is every field WriteError/WriteErrorWithPanic capture
// synchronously about one error response — see httpapi.ErrorLogDetail,
// which main.go's error sink converts into this (platformadmin cannot
// import httpapi directly: httpapi already imports platformadmin's sibling
// packages' error codes are one-way).
type RecordErrorInput struct {
	RequestID            *uuid.UUID
	StatusCode           int
	Code                 string
	Message              string
	Method               string
	Path                 string
	QueryParams          string
	RequestBody          []byte
	IPAddress            string
	UserAgent            string
	TenantID             *uuid.UUID
	ActorUserID          *uuid.UUID
	ActorPlatformAdminID *uuid.UUID
	StackTrace           string
}

func InsertErrorLog(ctx context.Context, tx pgx.Tx, in RecordErrorInput) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO error_logs (request_id, status_code, code, message, method, path, query_params, request_body,
		                         ip_address, user_agent, tenant_id, actor_user_id, actor_platform_admin_id, stack_trace)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
	`, in.RequestID, in.StatusCode, nullIfEmpty(in.Code), in.Message, nullIfEmpty(in.Method), nullIfEmpty(in.Path), nullIfEmpty(in.QueryParams),
		nullIfEmptyBytes(in.RequestBody), nullIfEmpty(in.IPAddress), nullIfEmpty(in.UserAgent), in.TenantID, in.ActorUserID, in.ActorPlatformAdminID,
		nullIfEmpty(in.StackTrace))
	return err
}

func nullIfEmptyBytes(b []byte) []byte {
	if len(b) == 0 {
		return nil
	}
	return b
}

// PlatformSettings is the single global row of default branding — the one
// place "FeedMate" / a tagline / a logo / a color live as data instead of
// being hardcoded into the Flutter source, per that codebase-wide sweep.
type PlatformSettings struct {
	AppName      string
	AppTagline   string
	LogoURL      *string
	PrimaryColor *string
}

func GetPlatformSettings(ctx context.Context, tx pgx.Tx) (*PlatformSettings, error) {
	var s PlatformSettings
	err := tx.QueryRow(ctx, `SELECT app_name, app_tagline, logo_url, primary_color FROM platform_settings WHERE id = 1`).
		Scan(&s.AppName, &s.AppTagline, &s.LogoURL, &s.PrimaryColor)
	return &s, err
}

func UpdatePlatformSettings(ctx context.Context, tx pgx.Tx, appName, appTagline string, logoURL, primaryColor *string) error {
	_, err := tx.Exec(ctx, `
		UPDATE platform_settings SET app_name = $1, app_tagline = $2, logo_url = $3, primary_color = $4, updated_at = now() WHERE id = 1
	`, appName, appTagline, logoURL, primaryColor)
	return err
}

// TenantBrandingOverride is just the three whitelabel fields — a lean
// projection of GetTenant used by the branding-resolution path, which runs
// on every app cold start and shouldn't pay for the feature-map/user-count
// queries GetTenant also does.
type TenantBrandingOverride struct {
	AppDisplayName *string
	LogoURL        *string
	PrimaryColor   *string
}

func GetTenantBrandingOverride(ctx context.Context, tx pgx.Tx, tenantID uuid.UUID) (*TenantBrandingOverride, error) {
	var o TenantBrandingOverride
	err := tx.QueryRow(ctx, `SELECT app_display_name, logo_url, primary_color FROM tenants WHERE id = $1`, tenantID).
		Scan(&o.AppDisplayName, &o.LogoURL, &o.PrimaryColor)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &o, nil
}
