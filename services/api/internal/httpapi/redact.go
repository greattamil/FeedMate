package httpapi

import (
	"encoding/json"
	"strings"
)

// sensitiveKeyNames is the denylist of JSON field names RedactJSON never
// persists the real value of — matched case-insensitively against a key at
// any depth. Keep this list narrow but err toward over-redacting: a
// debugging session losing one extra field costs far less than a leaked
// password or token sitting in a queryable log table.
var sensitiveKeyNames = map[string]bool{
	"password":        true,
	"new_password":    true,
	"old_password":    true,
	"owner_password":  true,
	"password_hash":   true,
	"pin":             true,
	"pin_hash":        true,
	"access_token":    true,
	"refresh_token":   true,
	"token":           true,
	"idempotency_key": false, // not secret, deliberately excluded from the denylist
}

const redactedPlaceholder = "[REDACTED]"

// maxLoggedBodySize caps how much of a request body ever gets persisted —
// generous enough for every real request this API handles (the largest is
// a POS invoice finalize with many lines), small enough that one giant
// payload can't bloat error_logs/audit_logs without bound.
const maxLoggedBodySize = 16 * 1024

// RedactJSON returns a version of raw safe to persist: valid JSON has every
// sensitive field's value replaced with redactedPlaceholder at any nesting
// depth; anything that isn't valid JSON (or exceeds maxLoggedBodySize) is
// never stored verbatim — only a short, explicit placeholder is, since a
// non-JSON body is unparseable here and therefore unredactable.
func RedactJSON(raw []byte) []byte {
	if len(raw) == 0 {
		return nil
	}
	if len(raw) > maxLoggedBodySize {
		return []byte(`"[BODY TOO LARGE TO LOG]"`)
	}
	var parsed interface{}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return []byte(`"[NON-JSON BODY OMITTED]"`)
	}
	redacted := redactValue(parsed)
	out, err := json.Marshal(redacted)
	if err != nil {
		return []byte(`"[BODY COULD NOT BE SERIALIZED]"`)
	}
	return out
}

func redactValue(v interface{}) interface{} {
	switch val := v.(type) {
	case map[string]interface{}:
		out := make(map[string]interface{}, len(val))
		for k, v := range val {
			if sensitiveKeyNames[strings.ToLower(k)] {
				out[k] = redactedPlaceholder
				continue
			}
			out[k] = redactValue(v)
		}
		return out
	case []interface{}:
		out := make([]interface{}, len(val))
		for i, item := range val {
			out[i] = redactValue(item)
		}
		return out
	default:
		return val
	}
}
