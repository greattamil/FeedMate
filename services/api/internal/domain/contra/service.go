package contra

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/accounting"
	"github.com/andipatti/feedmate/services/api/internal/domain/customer"
	"github.com/andipatti/feedmate/services/api/internal/domain/inventory"
)

var ErrValidation = errors.New("validation error")

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

type ContraLineInput struct {
	ProductID          uuid.UUID
	BatchCode          string
	ManufactureDate    *time.Time
	ExpiryDate         *time.Time
	Quantity           decimal.Decimal
	UOMID              uuid.UUID
	ValuationUnitPrice decimal.Decimal
	QualityStatus      string // ACCEPTED, REJECTED, QUARANTINE
	LocationID         uuid.UUID
}

type PostContraRequest struct {
	CustomerID      uuid.UUID
	SourceReference string
	Lines           []ContraLineInput
}

type PostContraResult struct {
	ContraID     uuid.UUID
	ContraNumber string
	TotalValue   decimal.Decimal
}

// PostContra is the atomic transaction for a buy-back / contra (PRD 10.3): a
// customer brings approved raw material (e.g. maize, husk) in exchange for
// reducing their outstanding Khata balance. This is not a negative payment —
// it is a genuine inventory receipt (a new batch is created, exactly like a
// GRN) combined with a financial settlement against the customer's
// receivable. Posting this endpoint requires contra.approve — there is no
// separate draft/approve step in this implementation, so the permission
// itself is the approval control (PRD 10.3: "never permit arbitrary
// valuation without an authorized price/approval rule").
func (s *Service) PostContra(ctx context.Context, tenantID, deviceID, userID uuid.UUID, req PostContraRequest) (*PostContraResult, error) {
	if len(req.Lines) == 0 {
		return nil, fmt.Errorf("%w: at least one line is required", ErrValidation)
	}

	var result PostContraResult
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		cust, err := customer.GetByID(ctx, tx, req.CustomerID)
		if err != nil {
			return fmt.Errorf("load customer: %w", err)
		}
		if cust.Status != "ACTIVE" {
			return fmt.Errorf("%w: customer is not active", ErrValidation)
		}

		type preparedLine struct {
			input ContraLineInput
			value decimal.Decimal
		}
		var (
			prepared   []preparedLine
			totalValue = decimal.Zero
		)
		for _, line := range req.Lines {
			if line.Quantity.LessThanOrEqual(decimal.Zero) {
				return fmt.Errorf("%w: quantity must be positive", ErrValidation)
			}
			if line.ValuationUnitPrice.LessThan(decimal.Zero) {
				return fmt.Errorf("%w: valuation unit price cannot be negative", ErrValidation)
			}
			if line.QualityStatus == "" {
				line.QualityStatus = "ACCEPTED"
			}
			value := line.Quantity.Mul(line.ValuationUnitPrice).Round(2)
			totalValue = totalValue.Add(value)
			prepared = append(prepared, preparedLine{input: line, value: value})
		}

		financialYearID, err := accounting.GetActiveFinancialYear(ctx, tx, tenantID)
		if err != nil {
			return fmt.Errorf("resolve financial year: %w", err)
		}
		contraNumber, err := AllocateContraNumber(ctx, tx, tenantID, financialYearID)
		if err != nil {
			return fmt.Errorf("allocate contra number: %w", err)
		}

		header := &ContraHeader{
			ContraNumber: contraNumber, CustomerID: req.CustomerID, TotalValue: totalValue,
			ApprovedByUserID: &userID,
		}
		if req.SourceReference != "" {
			header.SourceReference = &req.SourceReference
		}
		if err := InsertContraHeader(ctx, tx, tenantID, header); err != nil {
			return fmt.Errorf("insert contra header: %w", err)
		}

		for _, pl := range prepared {
			line := pl.input
			var batchID *uuid.UUID
			// Only an ACCEPTED commodity becomes sellable/usable inventory;
			// rejected/quarantined intake is still recorded (via a
			// non-ACTIVE batch) for traceability but never becomes sellable
			// stock, mirroring the GRN quality-status handling.
			batch := &inventory.Batch{
				ProductID: line.ProductID, BatchCode: line.BatchCode,
				ManufactureDate: line.ManufactureDate, ExpiryDate: line.ExpiryDate,
				ReceivedDate: time.Now(), ReceivedQty: line.Quantity, ReceivedUOMID: line.UOMID,
				UnitCost: line.ValuationUnitPrice, LocationID: line.LocationID, QualityStatus: line.QualityStatus,
			}
			if err := inventory.CreateBatch(ctx, tx, tenantID, batch, "CONTRA_RECEIPT", "CONTRA", &header.ID, &deviceID, &userID); err != nil {
				return fmt.Errorf("create batch for product %s: %w", line.ProductID, err)
			}
			if line.QualityStatus != "ACCEPTED" {
				if _, err := tx.Exec(ctx, `UPDATE batches SET status = 'QUARANTINED' WHERE id = $1`, batch.ID); err != nil {
					return fmt.Errorf("quarantine batch: %w", err)
				}
			}
			batchID = &batch.ID

			if err := InsertContraLine(ctx, tx, tenantID, header.ID, ContraLineRecord{
				ProductID: line.ProductID, BatchID: batchID, Quantity: line.Quantity, UOMID: line.UOMID,
				ValuationUnitPrice: line.ValuationUnitPrice, Value: pl.value,
				QualityStatus: line.QualityStatus, LocationID: line.LocationID,
			}); err != nil {
				return fmt.Errorf("insert contra line: %w", err)
			}
		}

		if _, err := customer.PostLedgerEntry(ctx, tx, tenantID, customer.LedgerEntry{
			CustomerID: req.CustomerID, DocumentType: "CONTRA", DocumentID: header.ID,
			Debit: decimal.Zero, Credit: totalValue,
			Description: fmt.Sprintf("Contra/buy-back %s", contraNumber),
			DeviceID: &deviceID, CreatedByUserID: &userID,
		}); err != nil {
			return fmt.Errorf("post customer ledger entry: %w", err)
		}

		if err := postContraJournal(ctx, tx, tenantID, financialYearID, header.ID, contraNumber, totalValue, req.CustomerID); err != nil {
			return fmt.Errorf("post journal: %w", err)
		}

		if _, err := tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, actor_device_id, action_code, entity_type, entity_id, after_json)
			VALUES ($1,$2,$3,'CONTRA_APPROVED','contra_transaction',$4,$5)
		`, tenantID, userID, deviceID, header.ID, map[string]interface{}{"contra_number": contraNumber, "total_value": totalValue.String()}); err != nil {
			return fmt.Errorf("write audit log: %w", err)
		}

		result = PostContraResult{ContraID: header.ID, ContraNumber: contraNumber, TotalValue: totalValue}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

func postContraJournal(ctx context.Context, tx pgx.Tx, tenantID, financialYearID, contraID uuid.UUID, contraNumber string, totalValue decimal.Decimal, customerID uuid.UUID) error {
	inventoryAccountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, "INVENTORY", "Inventory Asset", "ASSET")
	if err != nil {
		return err
	}
	receivableAccountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, "ACCOUNTS_RECEIVABLE", "Trade Receivables", "ASSET")
	if err != nil {
		return err
	}
	journalNumber := "JRNL-" + contraNumber
	_, err = accounting.PostJournal(ctx, tx, tenantID, financialYearID, journalNumber, "CONTRA", contraID, "Contra "+contraNumber, []accounting.JournalLine{
		{AccountID: inventoryAccountID, Debit: totalValue, Credit: decimal.Zero, Description: "Commodity received via contra"},
		{AccountID: receivableAccountID, Debit: decimal.Zero, Credit: totalValue, CustomerID: &customerID, Description: "Receivable reduced via contra"},
	})
	return err
}
