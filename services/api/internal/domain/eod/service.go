package eod

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
)

var (
	ErrValidation      = errors.New("validation error")
	ErrSessionExists   = errors.New("an EOD session already exists for this business date")
	ErrSessionNotOpen  = errors.New("EOD session is not open")
	ErrNotClosed       = errors.New("EOD session is not closed")
)

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

func normalizeDate(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
}

// OpenSession starts the day's cash session. The eod_sessions table's
// UNIQUE(tenant_id, business_date) constraint is the ultimate guard against
// opening the same business date twice — this check just gives a clean
// error before hitting that constraint.
func (s *Service) OpenSession(ctx context.Context, tenantID, userID uuid.UUID, businessDate time.Time, openingCash decimal.Decimal) (uuid.UUID, error) {
	if openingCash.LessThan(decimal.Zero) {
		return uuid.Nil, fmt.Errorf("%w: opening cash cannot be negative", ErrValidation)
	}
	businessDate = normalizeDate(businessDate)

	var sessionID uuid.UUID
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		if _, err := GetSessionByDate(ctx, tx, businessDate); err == nil {
			return ErrSessionExists
		} else if !errors.Is(err, ErrNotFound) {
			return err
		}
		id, err := InsertOpenSession(ctx, tx, tenantID, businessDate, openingCash)
		if err != nil {
			return err
		}
		sessionID = id
		return nil
	})
	if err != nil {
		return uuid.Nil, err
	}
	return sessionID, nil
}

type CloseResult struct {
	SessionID    uuid.UUID
	ExpectedCash decimal.Decimal
	ActualCash   decimal.Decimal
	Variance     decimal.Decimal
}

// CloseSession computes expected cash directly from the accounting journal's
// CASH account for the business date (opening + cash sales - cash refunds),
// compares it against the physically counted actual cash, and requires an
// explicit reason for any non-zero variance (PRD 12.2: "difference is logged
// as short/over with reason and approval"). Once closed, correcting the
// business date requires the separate, audited ReopenSession operation —
// this function never silently allows a second close.
func (s *Service) CloseSession(ctx context.Context, tenantID, userID uuid.UUID, businessDate time.Time, actualCash decimal.Decimal, varianceReason string) (*CloseResult, error) {
	if actualCash.LessThan(decimal.Zero) {
		return nil, fmt.Errorf("%w: actual cash cannot be negative", ErrValidation)
	}
	businessDate = normalizeDate(businessDate)

	var result CloseResult
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		session, err := GetSessionByDate(ctx, tx, businessDate)
		if err != nil {
			return err
		}
		if session.Status != "OPEN" {
			return fmt.Errorf("%w: current status is %s", ErrSessionNotOpen, session.Status)
		}

		cashSales, cashRefunds, err := GetCashJournalTotals(ctx, tx, tenantID, businessDate)
		if err != nil {
			return fmt.Errorf("compute cash journal totals: %w", err)
		}
		cashPayouts := decimal.Zero // no payout/expense module yet; reserved for future use
		expectedCash := session.OpeningCash.Add(cashSales).Sub(cashRefunds).Sub(cashPayouts)
		variance := actualCash.Sub(expectedCash)

		var reasonPtr *string
		if !variance.IsZero() {
			if varianceReason == "" {
				return fmt.Errorf("%w: a reason is required when actual cash does not match expected cash (variance %s)", ErrValidation, variance)
			}
			reasonPtr = &varianceReason
		}

		if err := CloseSession(ctx, tx, session.ID, cashSales, cashRefunds, cashPayouts, expectedCash, actualCash, variance, reasonPtr, userID); err != nil {
			return fmt.Errorf("close session: %w", err)
		}

		auditPayload := map[string]interface{}{
			"business_date": businessDate.Format("2006-01-02"), "expected_cash": expectedCash.String(),
			"actual_cash": actualCash.String(), "variance": variance.String(),
		}
		if reasonPtr != nil {
			auditPayload["variance_reason"] = *reasonPtr
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, entity_id, after_json)
			VALUES ($1,$2,'EOD_CLOSED','eod_session',$3,$4)
		`, tenantID, userID, session.ID, auditPayload); err != nil {
			return fmt.Errorf("write audit log: %w", err)
		}

		result = CloseResult{SessionID: session.ID, ExpectedCash: expectedCash, ActualCash: actualCash, Variance: variance}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

// ReopenSession is a deliberately narrow, permission-gated, audited escape
// hatch for correcting a closed business date (PRD 12.2: "late transactions
// require controlled reopen/adjustment workflow"). It does not undo the
// financial postings already made for that date — it only allows CloseSession
// to be run again later after any necessary corrections.
func (s *Service) ReopenSession(ctx context.Context, tenantID, userID uuid.UUID, businessDate time.Time, reason string) error {
	if reason == "" {
		return fmt.Errorf("%w: a reason is required to reopen a closed EOD session", ErrValidation)
	}
	businessDate = normalizeDate(businessDate)

	return s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		session, err := GetSessionByDate(ctx, tx, businessDate)
		if err != nil {
			return err
		}
		if session.Status != "CLOSED" {
			return fmt.Errorf("%w: current status is %s", ErrNotClosed, session.Status)
		}
		if err := ReopenSession(ctx, tx, session.ID, userID, reason); err != nil {
			return fmt.Errorf("reopen session: %w", err)
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, action_code, entity_type, entity_id, reason)
			VALUES ($1,$2,'EOD_REOPENED','eod_session',$3,$4)
		`, tenantID, userID, session.ID, reason)
		return err
	})
}

func (s *Service) GetSession(ctx context.Context, tenantID uuid.UUID, businessDate time.Time) (*Session, error) {
	businessDate = normalizeDate(businessDate)
	var session *Session
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		var err error
		session, err = GetSessionByDate(ctx, tx, businessDate)
		return err
	})
	return session, err
}
