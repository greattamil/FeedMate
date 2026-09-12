package auth

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"

	"golang.org/x/crypto/bcrypt"
)

// HashPassword hashes a plaintext password with bcrypt. Never store the plaintext
// or a reversible encoding of it anywhere (logs, audit payloads, DB columns).
func HashPassword(plaintext string, cost int) (string, error) {
	if len(plaintext) < 8 {
		return "", fmt.Errorf("password must be at least 8 characters")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(plaintext), cost)
	if err != nil {
		return "", fmt.Errorf("hash password: %w", err)
	}
	return string(hash), nil
}

// VerifyPassword returns true only if plaintext matches the stored bcrypt hash.
func VerifyPassword(hash, plaintext string) bool {
	if hash == "" || plaintext == "" {
		return false
	}
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(plaintext)) == nil
}

// HashOverridePIN hashes a manager/owner override PIN using the same algorithm as
// passwords. PINs must never be stored in plaintext (PRD section 19).
func HashOverridePIN(pin string, cost int) (string, error) {
	if len(pin) < 4 {
		return "", fmt.Errorf("override PIN must be at least 4 digits")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(pin), cost)
	if err != nil {
		return "", fmt.Errorf("hash pin: %w", err)
	}
	return string(hash), nil
}

func VerifyOverridePIN(hash, pin string) bool {
	if hash == "" || pin == "" {
		return false
	}
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(pin)) == nil
}

// GenerateOpaqueToken produces a cryptographically random token suitable for
// refresh tokens and idempotency-adjacent secrets. Only its hash is stored.
func GenerateOpaqueToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generate random token: %w", err)
	}
	return hex.EncodeToString(buf), nil
}
