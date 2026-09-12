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
