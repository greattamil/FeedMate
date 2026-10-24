package httpapi

import (
	"crypto/subtle"
	"fmt"
	"net/http"

	"github.com/andipatti/feedmate/services/api/internal/domain/cloudusage"
	"github.com/andipatti/feedmate/services/api/internal/domain/customer"
	"github.com/andipatti/feedmate/services/api/internal/domain/notify"
	"github.com/andipatti/feedmate/services/api/internal/domain/subscription"
)

// CronHandlers exposes the two background jobs (subscription billing
// cycle, cloud-usage poll) as plain HTTP endpoints that Google Cloud
// Scheduler calls on a schedule, instead of relying solely on an
// in-process time.Ticker goroutine.
//
// Why this exists: on Cloud Run, a container scales to zero when idle
// (killing any in-process ticker outright) and has its CPU frozen between
// requests even while warm (default cost-saving behavior — see
// config.EnableInProcessScheduler's doc comment) — so a goroutine ticker
// was found, by checking the actual logs, to only ever fire at container
// boot, never on its genuine hourly/daily schedule. Cloud Scheduler's HTTP
// call IS a request, so it reliably wakes the container (cold-starting it
// if needed) and keeps CPU allocated for exactly as long as the job takes
// — the same "pay only for real work" cost profile scale-to-zero already
// gives the rest of the app, just applied to scheduled jobs instead of
// user traffic.
//
// These routes sit outside RequireAuth/RequirePlatform (Cloud Scheduler
// carries no user JWT) and are gated instead by a dedicated CronSecret —
// separate from EdgeSharedSecret, which only proves "came through the
// Cloudflare Worker, not a random scanner" — because triggering a billing
// suspension run is sensitive enough to warrant its own, narrower secret
// rather than reusing the broader edge gate.
type CronHandlers struct {
	Subscription *subscription.Service
	CloudUsage   *cloudusage.Service
	Customer     *customer.Service
	Notify       *notify.Service
	CronSecret   string
}

func (h *CronHandlers) requireCronSecret(w http.ResponseWriter, r *http.Request) bool {
	if h.CronSecret == "" {
		WriteError(w, r, CodeNotFound, "not found")
		return false
	}
	got := r.Header.Get("X-Cron-Secret")
	if subtle.ConstantTimeCompare([]byte(got), []byte(h.CronSecret)) != 1 {
		WriteError(w, r, CodeNotFound, "not found")
		return false
	}
	return true
}

func (h *CronHandlers) RunBillingCycle(w http.ResponseWriter, r *http.Request) {
	if !h.requireCronSecret(w, r) {
		return
	}
	result, err := h.Subscription.RunBillingCycleNow(r.Context())
	if err != nil {
		WriteError(w, r, CodeInternal, "billing cycle run failed: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{
		"marked_past_due": result.MarkedPastDue,
		"suspended":       result.Suspended,
	})
}

func (h *CronHandlers) PollCloudUsage(w http.ResponseWriter, r *http.Request) {
	if !h.requireCronSecret(w, r) {
		return
	}
	polled, err := h.CloudUsage.RunPollOnce(r.Context())
	if err != nil {
		WriteError(w, r, CodeInternal, "cloud usage poll failed: "+err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"metrics_polled": polled})
}

// RunOverdueSweep computes, per tenant, which customers owe money and
// have had no ledger activity in a while (customer.RunOverdueSweepNow's
// doc comment has the precise definition), then dispatches at most one
// payment_overdue push per affected tenant through notify.Service —
// the same master-switch/per-event-preference checks every other event
// goes through, so a tenant that has disabled payment_overdue reminders
// stays silent here too.
func (h *CronHandlers) RunOverdueSweep(w http.ResponseWriter, r *http.Request) {
	if !h.requireCronSecret(w, r) {
		return
	}
	summaries, err := h.Customer.RunOverdueSweepNow(r.Context())
	if err != nil {
		WriteError(w, r, CodeInternal, "overdue sweep failed: "+err.Error())
		return
	}
	for _, sum := range summaries {
		h.Notify.Dispatch(r.Context(), sum.TenantID, notify.EventPaymentOverdue, map[string]string{
			"type":  "overdue_summary",
			"count": fmt.Sprintf("%d", sum.OverdueCount),
			"total": sum.TotalOutstanding.String(),
		})
	}
	WriteJSON(w, http.StatusOK, map[string]interface{}{"tenants_notified": len(summaries)})
}
