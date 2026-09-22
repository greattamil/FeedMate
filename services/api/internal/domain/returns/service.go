package returns

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
	"github.com/andipatti/feedmate/services/api/internal/domain/pos"
)

var (
	ErrValidation           = errors.New("validation error")
	ErrExceedsSoldQuantity  = errors.New("return quantity exceeds remaining eligible sold quantity")
	ErrOriginalInvoiceState = errors.New("original invoice is not in a returnable state")
)

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

type ReturnLineInput struct {
	OriginalLineID    uuid.UUID
	Quantity          decimal.Decimal
	ConditionStatus   string     // SELLABLE, DAMAGED, EXPIRED, QUARANTINE, OTHER
	RestockLocationID *uuid.UUID // required only when ConditionStatus != SELLABLE
}

type PostReturnRequest struct {
	OriginalInvoiceID uuid.UUID
	Reason            string
	Lines             []ReturnLineInput
	RefundMethod      string // CASH, UPI, CREDIT_NOTE
}

type PostReturnResult struct {
	ReturnID     uuid.UUID
	ReturnNumber string
	TotalRefund  decimal.Decimal
}

// PostReturn is the atomic transaction for a sales return: it validates the
// returned quantity against what remains eligible on the original invoice
// line (PRD 9.7 — never more than sold, minus already returned), restocks
// sellable goods back into their original batch (preserving FIFO/FEFO
// traceability) while routing non-sellable goods into a new quarantined
// batch, reverses the proportional sales/tax journal, and issues the refund
// either as a cash/UPI payout or as a Khata credit note — all in one
// transaction, or none of it.
func (s *Service) PostReturn(ctx context.Context, tenantID, deviceID, userID uuid.UUID, req PostReturnRequest) (*PostReturnResult, error) {
	if len(req.Lines) == 0 {
		return nil, fmt.Errorf("%w: at least one line is required", ErrValidation)
	}
	if req.RefundMethod != "CASH" && req.RefundMethod != "UPI" && req.RefundMethod != "CREDIT_NOTE" {
		return nil, fmt.Errorf("%w: refund_method must be CASH, UPI or CREDIT_NOTE", ErrValidation)
	}

	var result PostReturnResult
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		invoice, err := pos.GetInvoiceByID(ctx, tx, req.OriginalInvoiceID)
		if err != nil {
			return fmt.Errorf("load original invoice: %w", err)
		}
		if invoice.Status != "FINALIZED" {
			return fmt.Errorf("%w: invoice status is %s", ErrOriginalInvoiceState, invoice.Status)
		}
		if req.RefundMethod == "CREDIT_NOTE" && invoice.CustomerID == nil {
			return fmt.Errorf("%w: credit note refund requires the original invoice to have a customer", ErrValidation)
		}

		type preparedLine struct {
			input          ReturnLineInput
			original       *OriginalLine
			refundTaxable  decimal.Decimal
			taxByType      map[string]decimal.Decimal
			refundTaxTotal decimal.Decimal
			refundAmount   decimal.Decimal
			allocations    []BatchAllocation
		}

		var (
			prepared      []preparedLine
			subtotalTotal = decimal.Zero
			taxTotal      = decimal.Zero
			taxByTypeAll  = map[string]decimal.Decimal{}
		)

		for _, line := range req.Lines {
			if line.Quantity.LessThanOrEqual(decimal.Zero) {
				return fmt.Errorf("%w: return quantity must be positive", ErrValidation)
			}
			if line.ConditionStatus == "" {
				line.ConditionStatus = "SELLABLE"
			}
			if line.ConditionStatus != "SELLABLE" && line.RestockLocationID == nil {
				return fmt.Errorf("%w: restock_location_id is required for non-sellable condition %s", ErrValidation, line.ConditionStatus)
			}

			original, err := GetOriginalLine(ctx, tx, line.OriginalLineID)
			if err != nil {
				return fmt.Errorf("load original line: %w", err)
			}
			if original.InvoiceID != req.OriginalInvoiceID {
				return fmt.Errorf("%w: original_line_id does not belong to the specified invoice", ErrValidation)
			}

			alreadyReturned, err := AlreadyReturnedQty(ctx, tx, line.OriginalLineID)
			if err != nil {
				return fmt.Errorf("load already-returned quantity: %w", err)
			}
			remaining := original.Quantity.Sub(alreadyReturned)
			if line.Quantity.GreaterThan(remaining) {
				return fmt.Errorf("%w: requested %s, only %s remains eligible", ErrExceedsSoldQuantity, line.Quantity, remaining)
			}

			proportion := line.Quantity.Div(original.Quantity)
			refundTaxable := original.TaxableValue.Mul(proportion).Round(2)

			taxLines, err := GetTaxLinesForLine(ctx, tx, line.OriginalLineID)
			if err != nil {
				return fmt.Errorf("load original tax lines: %w", err)
			}
			taxByType := map[string]decimal.Decimal{}
			refundTaxTotal := decimal.Zero
			for _, tl := range taxLines {
				amount := tl.TaxAmount.Mul(proportion).Round(2)
				taxByType[tl.TaxType] = taxByType[tl.TaxType].Add(amount)
				taxByTypeAll[tl.TaxType] = taxByTypeAll[tl.TaxType].Add(amount)
				refundTaxTotal = refundTaxTotal.Add(amount)
			}

			var allocations []BatchAllocation
			if line.ConditionStatus == "SELLABLE" {
				allocations, err = GetBatchAllocations(ctx, tx, line.OriginalLineID)
				if err != nil {
					return fmt.Errorf("load batch allocations: %w", err)
				}
				if len(allocations) == 0 {
					return fmt.Errorf("%w: original line has no batch allocation to restock into", ErrValidation)
				}
			}

			subtotalTotal = subtotalTotal.Add(refundTaxable)
			taxTotal = taxTotal.Add(refundTaxTotal)

			prepared = append(prepared, preparedLine{
				input: line, original: original, refundTaxable: refundTaxable,
				taxByType: taxByType, refundTaxTotal: refundTaxTotal,
				refundAmount: refundTaxable.Add(refundTaxTotal), allocations: allocations,
			})
		}

		financialYearID, err := accounting.GetActiveFinancialYear(ctx, tx, tenantID)
		if err != nil {
			return fmt.Errorf("resolve financial year: %w", err)
		}
		returnNumber, err := AllocateReturnNumber(ctx, tx, tenantID, financialYearID)
		if err != nil {
			return fmt.Errorf("allocate return number: %w", err)
		}

		grandTotal := subtotalTotal.Add(taxTotal)
		header := &ReturnHeader{
			ReturnNumber: returnNumber, OriginalInvoiceID: req.OriginalInvoiceID, CustomerID: invoice.CustomerID,
			Reason: req.Reason, Subtotal: subtotalTotal, TaxTotal: taxTotal, Total: grandTotal,
			RefundStatus: "COMPLETED", CreatedByUserID: &userID,
		}
		if err := InsertReturnHeader(ctx, tx, tenantID, header); err != nil {
			return fmt.Errorf("insert return header: %w", err)
		}

		for _, pl := range prepared {
			if err := InsertReturnLine(ctx, tx, tenantID, header.ID, ReturnLineRecord{
				OriginalLineID: pl.original.ID, ProductID: pl.original.ProductID, Quantity: pl.input.Quantity,
				UOMID: pl.original.UOMID, ConditionStatus: pl.input.ConditionStatus,
				RestockLocationID: pl.input.RestockLocationID, RefundAmount: pl.refundAmount,
			}); err != nil {
				return fmt.Errorf("insert return line: %w", err)
			}

			if pl.input.ConditionStatus == "SELLABLE" {
				if err := restockSellable(ctx, tx, tenantID, deviceID, userID, header.ID, pl.original.ProductID, pl.original.UOMID, pl.input.Quantity, pl.allocations); err != nil {
					return fmt.Errorf("restock sellable return: %w", err)
				}
			} else {
				if err := quarantineNonSellable(ctx, tx, tenantID, deviceID, userID, header.ID, pl.original.ProductID, pl.original.UOMID, pl.input.Quantity, pl.input.ConditionStatus, *pl.input.RestockLocationID, pl.allocations); err != nil {
					return fmt.Errorf("quarantine non-sellable return: %w", err)
				}
			}
		}

		// Every return against a real customer belongs in their ledger, not
		// only credit-note ones — the same 360°-visibility reasoning as a
		// cash sale's invoice entry above. A CREDIT_NOTE genuinely reduces
		// what they owe (credit only, no offsetting debit). A CASH/UPI
		// refund never touches their balance (cash changes hands directly),
		// but is still a real event a shop owner expects to see in that
		// customer's history — posted as a self-cancelling credit+debit
		// pair so it's visible with zero net balance impact.
		if invoice.CustomerID != nil {
			if _, err := customer.PostLedgerEntry(ctx, tx, tenantID, customer.LedgerEntry{
				CustomerID: *invoice.CustomerID, DocumentType: "RETURN", DocumentID: header.ID,
				Debit: decimal.Zero, Credit: grandTotal,
				Description: fmt.Sprintf("Return %s", returnNumber),
				DeviceID:    &deviceID, CreatedByUserID: &userID,
			}); err != nil {
				return fmt.Errorf("post customer return entry: %w", err)
			}
			if req.RefundMethod != "CREDIT_NOTE" {
				if _, err := customer.PostLedgerEntry(ctx, tx, tenantID, customer.LedgerEntry{
					CustomerID: *invoice.CustomerID, DocumentType: "RETURN", DocumentID: header.ID,
					Debit: grandTotal, Credit: decimal.Zero,
					Description: fmt.Sprintf("Refund paid via %s for return %s", req.RefundMethod, returnNumber),
					DeviceID:    &deviceID, CreatedByUserID: &userID,
				}); err != nil {
					return fmt.Errorf("post customer refund entry: %w", err)
				}
			}
		}

		if err := postReturnJournal(ctx, tx, tenantID, financialYearID, header.ID, returnNumber, req.RefundMethod, subtotalTotal, taxByTypeAll, invoice.CustomerID); err != nil {
			return fmt.Errorf("post journal: %w", err)
		}

		if _, err := tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, actor_device_id, action_code, entity_type, entity_id, after_json)
			VALUES ($1,$2,$3,'RETURN_CREATED','sales_return',$4,$5)
		`, tenantID, userID, deviceID, header.ID, map[string]interface{}{
			"return_number": returnNumber, "total_refund": grandTotal.String(), "refund_method": req.RefundMethod,
		}); err != nil {
			return fmt.Errorf("write audit log: %w", err)
		}

		result = PostReturnResult{ReturnID: header.ID, ReturnNumber: returnNumber, TotalRefund: grandTotal}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

// restockSellable puts returned sellable stock back into the exact batch(es)
// it was originally allocated from, split proportionally to the original
// allocation ratio, preserving batch/expiry traceability end to end.
func restockSellable(ctx context.Context, tx pgx.Tx, tenantID, deviceID, userID, returnID, productID, uomID uuid.UUID, qty decimal.Decimal, allocations []BatchAllocation) error {
	totalOriginal := decimal.Zero
	for _, a := range allocations {
		totalOriginal = totalOriginal.Add(a.Quantity)
	}
	remaining := qty
	for i, a := range allocations {
		var restockQty decimal.Decimal
		if i == len(allocations)-1 {
			restockQty = remaining // last allocation absorbs any rounding remainder
		} else {
			restockQty = qty.Mul(a.Quantity).Div(totalOriginal).Round(3)
			remaining = remaining.Sub(restockQty)
		}
		if restockQty.LessThanOrEqual(decimal.Zero) {
			continue
		}
		locationID, err := GetBatchLocation(ctx, tx, a.BatchID)
		if err != nil {
			return fmt.Errorf("resolve batch location: %w", err)
		}
		batchID := a.BatchID
		if err := inventory.PostStockMovement(ctx, tx, tenantID, inventory.StockMovement{
			ProductID: productID, BatchID: &batchID, LocationID: locationID, UOMID: uomID,
			Quantity: restockQty, SignedQuantity: restockQty, MovementType: "SALE_RETURN",
			SourceType: "RETURN", SourceID: &returnID, UnitCost: &a.UnitCost,
			DeviceID: &deviceID, CreatedByUserID: &userID,
		}); err != nil {
			return err
		}
		// A depleted batch that receives stock back becomes sellable again.
		if _, err := tx.Exec(ctx, `UPDATE batches SET status = 'ACTIVE' WHERE id = $1 AND status = 'DEPLETED'`, batchID); err != nil {
			return err
		}
	}
	return nil
}

// quarantineNonSellable receives damaged/expired/quarantined returns into a
// new, distinctly quarantined batch — never back into the sellable pool
// (PRD 9.7: returned goods require condition classification, and quarantined
// stock cannot be allocated to sales).
func quarantineNonSellable(ctx context.Context, tx pgx.Tx, tenantID, deviceID, userID, returnID, productID, uomID uuid.UUID, qty decimal.Decimal, conditionStatus string, locationID uuid.UUID, allocations []BatchAllocation) error {
	unitCost := decimal.Zero
	if len(allocations) > 0 {
		unitCost = allocations[0].UnitCost // approximate; exact original cost layer is preserved on the sale side
	}
	batch := &inventory.Batch{
		ProductID: productID, BatchCode: "RETURN-" + returnID.String()[:8],
		ReceivedDate: time.Now(), ReceivedQty: qty, ReceivedUOMID: uomID,
		UnitCost: unitCost, LocationID: locationID, QualityStatus: mapConditionToQuality(conditionStatus),
	}
	if err := inventory.CreateBatch(ctx, tx, tenantID, batch, "SALE_RETURN", "RETURN", &returnID, &deviceID, &userID); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `UPDATE batches SET status = 'QUARANTINED' WHERE id = $1`, batch.ID)
	return err
}

func mapConditionToQuality(condition string) string {
	switch condition {
	case "DAMAGED":
		return "DAMAGED"
	case "QUARANTINE":
		return "QUARANTINE"
	default:
		return "REJECTED"
	}
}

func postReturnJournal(ctx context.Context, tx pgx.Tx, tenantID, financialYearID, returnID uuid.UUID, returnNumber, refundMethod string, subtotal decimal.Decimal, taxByType map[string]decimal.Decimal, customerID *uuid.UUID) error {
	salesAccountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, "SALES", "Sales Revenue", "INCOME")
	if err != nil {
		return err
	}
	lines := []accounting.JournalLine{
		{AccountID: salesAccountID, Debit: subtotal, Credit: decimal.Zero, Description: "Sales return reversal"},
	}
	total := subtotal
	for taxType, amount := range taxByType {
		if amount.IsZero() {
			continue
		}
		accountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, "GST_"+taxType+"_PAYABLE", "GST "+taxType+" Payable", "LIABILITY")
		if err != nil {
			return err
		}
		lines = append(lines, accounting.JournalLine{AccountID: accountID, Debit: amount, Credit: decimal.Zero, Description: taxType + " reversal"})
		total = total.Add(amount)
	}

	var settlementCode, settlementName string
	switch refundMethod {
	case "CASH":
		settlementCode, settlementName = "CASH", "Cash on Hand"
	case "UPI":
		settlementCode, settlementName = "UPI_CLEARING", "UPI Clearing Account"
	case "CREDIT_NOTE":
		settlementCode, settlementName = "ACCOUNTS_RECEIVABLE", "Trade Receivables"
	}
	settlementAccountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, settlementCode, settlementName, "ASSET")
	if err != nil {
		return err
	}
	creditLine := accounting.JournalLine{AccountID: settlementAccountID, Debit: decimal.Zero, Credit: total, Description: "Refund via " + refundMethod}
	if refundMethod == "CREDIT_NOTE" {
		creditLine.CustomerID = customerID
	}
	lines = append(lines, creditLine)

	journalNumber := "JRNL-" + returnNumber
	_, err = accounting.PostJournal(ctx, tx, tenantID, financialYearID, journalNumber, "RETURN", returnID, "Return "+returnNumber, lines)
	return err
}
