package auth

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

// AccessClaims is the payload of a short-lived access token. It carries the
// trusted tenant/user/device identity the tenant-context middleware relies on
// to establish the PostgreSQL RLS session variable — never trust any tenant
// identifier from elsewhere in the request.
type AccessClaims struct {
	UserID      uuid.UUID `json:"uid"`
	TenantID    uuid.UUID `json:"tid"`
	DeviceID    uuid.UUID `json:"did"`
	Permissions []string  `json:"perms"`
	// IsPlatform marks a platform-admin session — one with no tenant/device
	// at all (see platformadmin.Service). Checked by middleware.RequirePlatform
	// as a belt-and-braces guard alongside the "platform.admin" permission
	// string, since this field can never be forged by ordinary tenant login.
	IsPlatform bool `json:"plat,omitempty"`
	jwt.RegisteredClaims
}

func IssueAccessToken(signingKey string, userID, tenantID, deviceID uuid.UUID, permissions []string, ttl time.Duration) (string, error) {
	claims := AccessClaims{
		UserID:      userID,
		TenantID:    tenantID,
		DeviceID:    deviceID,
		Permissions: permissions,
		RegisteredClaims: jwt.RegisteredClaims{
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(ttl)),
			Subject:   userID.String(),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := token.SignedString([]byte(signingKey))
	if err != nil {
		return "", fmt.Errorf("sign access token: %w", err)
	}
	return signed, nil
}

// IssuePlatformAccessToken issues a tenant-less, device-less token for a
// platform admin — TenantID/DeviceID are the zero UUID, which is safe only
// because nothing in the tenant-scoped request path is reachable with this
// token (platform routes require IsPlatform, and no dbctx.WithTenantTx call
// site would accept uuid.Nil as a real tenant anyway).
func IssuePlatformAccessToken(signingKey string, platformAdminID uuid.UUID, ttl time.Duration) (string, error) {
	claims := AccessClaims{
		UserID:      platformAdminID,
		Permissions: []string{"platform.admin"},
		IsPlatform:  true,
		RegisteredClaims: jwt.RegisteredClaims{
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(ttl)),
			Subject:   platformAdminID.String(),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := token.SignedString([]byte(signingKey))
	if err != nil {
		return "", fmt.Errorf("sign platform access token: %w", err)
	}
	return signed, nil
}

// ParseAccessToken verifies signature and expiry and returns the trusted claims.
func ParseAccessToken(signingKey, tokenStr string) (*AccessClaims, error) {
	claims := &AccessClaims{}
	token, err := jwt.ParseWithClaims(tokenStr, claims, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return []byte(signingKey), nil
	})
	if err != nil {
		return nil, fmt.Errorf("parse access token: %w", err)
	}
	if !token.Valid {
		return nil, fmt.Errorf("invalid access token")
	}
	return claims, nil
}

// HashRefreshToken returns a deterministic hash of an opaque refresh token for
// storage/lookup. Refresh tokens themselves are never persisted in plaintext.
func HashRefreshToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
