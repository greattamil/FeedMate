package procurement

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
	"github.com/andipatti/feedmate/services/api/internal/domain/inventory"
	"github.com/andipatti/feedmate/services/api/internal/domain/pos"
	"github.com/andipatti/feedmate/services/api/internal/domain/supplier"
)

var ErrValidation = errors.New("validation error")

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

type GRNLineInput struct {
	ProductID       uuid.UUID
	BatchCode       string
	ManufactureDate *time.Time
	ExpiryDate      *time.Time
	ReceivedQty     decimal.Decimal
	UOMID           uuid.UUID
	LocationID      uuid.UUID
	UnitCost        decimal.Decimal
	TaxProfileID    *uuid.UUID
	QualityStatus   string // ACCEPTED/REJECTED/DAMAGED/QUARANTINE

	// Weight/tare fields are optional: a product received purely by count (no
	// weight capture at receipt) may omit them entirely. When GrossWeightKg
	// is set, TareMethod is mandatory (PRD A7 — tare must never be assumed).
	GrossWeightKg        *decimal.Decimal
	TareMethod           string
	MeasuredTareKg       *decimal.Decimal
	BagCount             *int
	StandardTarePerBagKg *decimal.Decimal
}

type PostGRNRequest struct {
	SupplierID         uuid.UUID
	PurchaseOrderID    *uuid.UUID
	SupplierDocumentNo *string
	VehicleNo          *string
	Lines              []GRNLineInput

	// TareOverride mirrors the POS credit-override pattern: exceeding the
	// configured tare threshold requires an explicit, reasoned decision by
	// someone holding grn.override_tare — never an implicit bypass (PRD A7).
	TareOverride struct {
		Requested bool
		Reason    string
	}
}

type PostGRNResult struct {
	GRNID     uuid.UUID
	GRNNumber string
}

// preparedLine holds everything computed/validated in the first pass, before
// any row is written, so the GRN header (which needs aggregated totals) can
// be inserted before the per-line batches/stock movements that reference it.
type preparedLine struct {
	input         GRNLineInput
	grossKg       *decimal.Decimal
	tareKg        *decimal.Decimal
	netKg         *decimal.Decimal
	lineCost      decimal.Decimal
	taxComponents []pos.TaxComponent
	lineTax       decimal.Decimal
	acceptedQty   decimal.Decimal
	rejectedQty   decimal.Decimal
}

// PostGRN is the authoritative, atomic event for physically received stock
// (PRD 7.4): it validates gross/tare/net weight per line, creates a batch and
// stock receipt movement for each accepted line, posts the supplier payable,
// and posts a balanced accounting journal (Dr Inventory [+ GST input], Cr
// Accounts Payable) — all in one transaction, or none of it.
func (s *Service) PostGRN(ctx context.Context, tenantID, deviceID, userID uuid.UUID, req PostGRNRequest) (*PostGRNResult, error) {
	if len(req.Lines) == 0 {
		return nil, fmt.Errorf("%w: at least one line is required", ErrValidation)
	}

	var result PostGRNResult
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		sup, err := supplier.GetByID(ctx, tx, req.SupplierID)
		if err != nil {
			return fmt.Errorf("load supplier: %w", err)
		}
		if sup.Status != "ACTIVE" {
			return fmt.Errorf("%w: supplier is not active", ErrValidation)
		}

		thresholdPct, err := GetTareThresholdPct(ctx, tx, tenantID)
		if err != nil {
			return fmt.Errorf("load tare threshold: %w", err)
		}

		// --- Pass 1: validate every line and compute totals. No writes yet. ---
		var (
			prepared        []preparedLine
			totalCost       = decimal.Zero
			totalTax        = decimal.Zero
			taxByType       = map[string]decimal.Decimal{}
			sumGross        = decimal.Zero
			sumTare         = decimal.Zero
			sumNet          = decimal.Zero
			anyWeightLines  bool
			anyOverrideUsed bool
		)

		for _, line := range req.Lines {
			if line.ReceivedQty.LessThanOrEqual(decimal.Zero) {
				return fmt.Errorf("%w: received quantity must be positive", ErrValidation)
			}
			if line.QualityStatus == "" {
				line.QualityStatus = "ACCEPTED"
			}

			pl := preparedLine{input: line}

			if line.GrossWeightKg != nil {
				anyWeightLines = true
				calc, err := CalculateTare(line.TareMethod, *line.GrossWeightKg, line.MeasuredTareKg, line.BagCount, line.StandardTarePerBagKg, thresholdPct)
				if err != nil {
					return fmt.Errorf("tare calculation for product %s: %w", line.ProductID, err)
				}
				if calc.ExceedsThreshold {
					if !req.TareOverride.Requested {
						return fmt.Errorf("%w: tare %s exceeds max allowed %s (%.2f%% of gross %s) for product %s",
							ErrTareExceedsThreshold, calc.TareWeightKg, calc.MaxAllowedTareKg, thresholdPct.InexactFloat64(), calc.GrossWeightKg, line.ProductID)
					}
					if req.TareOverride.Reason == "" {
						return fmt.Errorf("%w: a reason is required to override the tare threshold", ErrValidation)
					}
					anyOverrideUsed = true
				}
				pl.grossKg, pl.tareKg, pl.netKg = &calc.GrossWeightKg, &calc.TareWeightKg, &calc.NetWeightKg
				sumGross = sumGross.Add(calc.GrossWeightKg)
				sumTare = sumTare.Add(calc.TareWeightKg)
				sumNet = sumNet.Add(calc.NetWeightKg)
			}

			pl.acceptedQty = line.ReceivedQty
			pl.rejectedQty = decimal.Zero
			if line.QualityStatus == "REJECTED" {
				pl.acceptedQty = decimal.Zero
				pl.rejectedQty = line.ReceivedQty
			}

			pl.lineCost = line.ReceivedQty.Mul(line.UnitCost)
			totalCost = totalCost.Add(pl.lineCost)

			if line.TaxProfileID != nil && line.QualityStatus == "ACCEPTED" {
				taxProfile, err := pos.GetActiveTaxProfile(ctx, tx, *line.TaxProfileID)
				if err != nil {
					return fmt.Errorf("load tax profile: %w", err)
				}
				comps, tax := pos.CalculateLineTax(taxProfile, pl.lineCost)
				pl.taxComponents, pl.lineTax = comps, tax
				for _, c := range comps {
					taxByType[c.Type] = taxByType[c.Type].Add(c.Amount)
				}
				totalTax = totalTax.Add(tax)
			}

			prepared = append(prepared, pl)
		}

		// --- Header (needs the aggregates from pass 1) ---
		financialYearID, err := accounting.GetActiveFinancialYear(ctx, tx, tenantID)
		if err != nil {
			return fmt.Errorf("resolve financial year: %w", err)
		}
		grnNumber, err := AllocateGRNNumber(ctx, tx, tenantID, financialYearID)
		if err != nil {
			return fmt.Errorf("allocate GRN number: %w", err)
		}

		header := &GRNHeader{
			GRNNumber: grnNumber, SupplierID: req.SupplierID, PurchaseOrderID: req.PurchaseOrderID,
			SupplierDocumentNo: req.SupplierDocumentNo, VehicleNo: req.VehicleNo, ReceiverUserID: &userID,
			TareOverride: anyOverrideUsed,
		}
		if anyWeightLines {
			header.GrossWeightKg, header.TareWeightKg, header.NetWeightKg = &sumGross, &sumTare, &sumNet
			header.TareThresholdPct = &thresholdPct
		}
		if anyOverrideUsed {
			header.TareOverrideReason = &req.TareOverride.Reason
		}
		if err := InsertGRNHeader(ctx, tx, tenantID, financialYearID, header); err != nil {
			return fmt.Errorf("insert GRN header: %w", err)
		}

		// --- Pass 2: now that header.ID exists, create batches, stock
		// movements, and GRN lines, all traceable back to this GRN. ---
		for _, pl := range prepared {
			line := pl.input
			var batchID uuid.UUID
			batch := &inventory.Batch{
				ProductID: line.ProductID, SupplierID: &req.SupplierID, BatchCode: line.BatchCode,
				ManufactureDate: line.ManufactureDate, ExpiryDate: line.ExpiryDate,
				ReceivedDate: time.Now(), ReceivedUOMID: line.UOMID,
				UnitCost: line.UnitCost, LocationID: line.LocationID, QualityStatus: line.QualityStatus,
			}
			if line.QualityStatus == "ACCEPTED" && pl.acceptedQty.GreaterThan(decimal.Zero) {
				batch.ReceivedQty = pl.acceptedQty
				if err := inventory.CreateBatch(ctx, tx, tenantID, batch, "PURCHASE_GRN", "GRN", &header.ID, &deviceID, &userID); err != nil {
					return fmt.Errorf("create batch for product %s: %w", line.ProductID, err)
				}
			} else {
				// Rejected/damaged/quarantined receipts are still recorded as a
				// batch for traceability, but never enter the sellable pool
				// (PRD 7.4 / DB spec 15): immediately quarantined after creation.
				batch.ReceivedQty = line.ReceivedQty
				if err := inventory.CreateBatch(ctx, tx, tenantID, batch, "PURCHASE_GRN", "GRN", &header.ID, &deviceID, &userID); err != nil {
					return fmt.Errorf("create batch for product %s: %w", line.ProductID, err)
				}
				if _, err := tx.Exec(ctx, `UPDATE batches SET status = 'QUARANTINED' WHERE id = $1`, batch.ID); err != nil {
					return fmt.Errorf("quarantine rejected batch: %w", err)
				}
			}
			batchID = batch.ID

			if err := InsertGRNLine(ctx, tx, tenantID, header.ID, GRNLineRecord{
				ProductID: line.ProductID, BatchID: batchID, LocationID: line.LocationID,
				ReceivedQty: line.ReceivedQty, ReceivedUOMID: line.UOMID,
				GrossWeightKg: pl.grossKg, TareWeightKg: pl.tareKg, NetWeightKg: pl.netKg,
				UnitCost: line.UnitCost, TaxProfileID: line.TaxProfileID, QualityStatus: line.QualityStatus,
				AcceptedQty: pl.acceptedQty, RejectedQty: pl.rejectedQty,
				ManufactureDate: line.ManufactureDate, ExpiryDate: line.ExpiryDate,
			}); err != nil {
				return fmt.Errorf("insert GRN line: %w", err)
			}
		}

		grandTotal := totalCost.Add(totalTax)
		if _, err := supplier.PostLedgerEntry(ctx, tx, tenantID, supplier.LedgerEntry{
			SupplierID: req.SupplierID, DocumentType: "GRN", DocumentID: header.ID,
			Debit: decimal.Zero, Credit: grandTotal,
			Description: fmt.Sprintf("GRN %s", grnNumber), CreatedByUserID: &userID,
		}); err != nil {
			return fmt.Errorf("post supplier ledger entry: %w", err)
		}

		if err := postGRNJournal(ctx, tx, tenantID, financialYearID, header.ID, grnNumber, totalCost, taxByType, req.SupplierID); err != nil {
			return fmt.Errorf("post journal: %w", err)
		}

		auditPayload := map[string]interface{}{"grn_number": grnNumber, "total_cost": grandTotal.String()}
		if anyOverrideUsed {
			auditPayload["tare_override"] = true
			auditPayload["tare_override_reason"] = req.TareOverride.Reason
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, actor_device_id, action_code, entity_type, entity_id, after_json)
			VALUES ($1,$2,$3,'GRN_POSTED','goods_receipt',$4,$5)
		`, tenantID, userID, deviceID, header.ID, auditPayload); err != nil {
			return fmt.Errorf("write audit log: %w", err)
		}
		if anyOverrideUsed {
			if _, err := tx.Exec(ctx, `
				INSERT INTO audit_logs (tenant_id, actor_user_id, actor_device_id, action_code, entity_type, entity_id, reason, after_json)
				VALUES ($1,$2,$3,'TARE_OVERRIDE','goods_receipt',$4,$5,$6)
			`, tenantID, userID, deviceID, header.ID, req.TareOverride.Reason,
				map[string]interface{}{"grn_number": grnNumber, "gross_kg": sumGross.String(), "tare_kg": sumTare.String(), "net_kg": sumNet.String()}); err != nil {
				return fmt.Errorf("write tare override audit log: %w", err)
			}
		}

		result = PostGRNResult{GRNID: header.ID, GRNNumber: grnNumber}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

func postGRNJournal(ctx context.Context, tx pgx.Tx, tenantID, financialYearID, grnID uuid.UUID, grnNumber string, totalCost decimal.Decimal, taxByType map[string]decimal.Decimal, supplierID uuid.UUID) error {
	inventoryAccountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, "INVENTORY", "Inventory Asset", "ASSET")
	if err != nil {
		return err
	}
	payableAccountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, "ACCOUNTS_PAYABLE", "Trade Payables", "LIABILITY")
	if err != nil {
		return err
	}

	lines := []accounting.JournalLine{
		{AccountID: inventoryAccountID, Debit: totalCost, Credit: decimal.Zero, Description: "Inventory received"},
	}
	totalPayable := totalCost
	for taxType, amount := range taxByType {
		if amount.IsZero() {
			continue
		}
		accountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, "GST_INPUT_"+taxType, "GST Input "+taxType, "ASSET")
		if err != nil {
			return err
		}
		lines = append(lines, accounting.JournalLine{AccountID: accountID, Debit: amount, Credit: decimal.Zero, Description: "GST input " + taxType})
		totalPayable = totalPayable.Add(amount)
	}
	lines = append(lines, accounting.JournalLine{AccountID: payableAccountID, Debit: decimal.Zero, Credit: totalPayable, SupplierID: &supplierID, Description: "Supplier payable"})

	journalNumber := "JRNL-" + grnNumber
	_, err = accounting.PostJournal(ctx, tx, tenantID, financialYearID, journalNumber, "GRN", grnID, "GRN "+grnNumber, lines)
	return err
}
