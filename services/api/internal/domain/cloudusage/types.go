package cloudusage

import "time"

// LatestUsage is one provider/metric's most recent snapshot, with the
// percentage-used already computed server-side (nil when no limit is
// known, e.g. Aiven before its API token is configured).
type LatestUsage struct {
	Provider    string
	MetricKey   string
	Label       string
	UsedValue   float64
	LimitValue  *float64
	LimitIsLive bool
	Unit        string
	PctUsed     *float64
	CapturedAt  time.Time
}

type Threshold struct {
	ID          string
	Provider    string
	MetricKey   string
	WarningPct  float64
	CriticalPct float64
}

type Alert struct {
	ID         string
	Provider   string
	MetricKey  string
	Severity   string
	Message    string
	PctUsed    float64
	CreatedAt  time.Time
	ResolvedAt *time.Time
}
