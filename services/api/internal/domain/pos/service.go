package pos

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/shopspring/decimal"

	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/accounting"
	"github.com/andipatti/feedmate/services/api/internal/domain/customer"
	"github.com/andipatti/feedmate/services/api/internal/domain/inventory"
	"github.com/andipatti/feedmate/services/api/internal/domain/product"
)

var (
	ErrValidation          = errors.New("validation error")
	ErrTenderMismatch      = errors.New("tender total does not equal invoice grand total")
	ErrCreditLimitExceeded = errors.New("credit limit exceeded")
)

type Service struct {
	db *dbctx.DB
}

func NewService(db *dbctx.DB) *Service {
	return &Service{db: db}
}

// InvoiceForReturn is everything a cashier needs to pick which lines of a
// past sale to return: the header (for display/context) and each line's
// remaining eligible quantity (never more than sold minus already returned
// via a POSTED return — PRD 9.7).
type InvoiceForReturn struct {
	Header *InvoiceHeader
	Lines  []InvoiceLineSummary
}

// GetInvoiceForReturn looks an invoice up by its human-facing number (what's
// on the printed receipt) and loads its lines with remaining-eligible
// quantities — the read side of the returns flow. PostReturn itself
// re-derives quantities inside its own transaction and never trusts a value
// from an earlier read.
func (s *Service) GetInvoiceForReturn(ctx context.Context, tenantID uuid.UUID, invoiceNumber string) (*InvoiceForReturn, error) {
	var result InvoiceForReturn
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		header, err := GetByInvoiceNumber(ctx, tx, invoiceNumber)
		if err != nil {
			return err
		}
		lines, err := ListInvoiceLines(ctx, tx, header.ID)
		if err != nil {
			return err
		}
		result.Header = header
		result.Lines = lines
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

type SaleLine struct {
	ProductID         uuid.UUID
	Quantity          decimal.Decimal
	UnitPriceOverride *decimal.Decimal
	DiscountAmount    decimal.Decimal
	WeightSource      *string // SCALE or MANUAL, for scale-required products
}

type Tender struct {
	Method string // CASH, UPI, BANK, CREDIT, OTHER
	Amount decimal.Decimal
}

type FinalizeRequest struct {
	ClientTransactionID uuid.UUID
	LocationID          uuid.UUID
	CustomerID          *uuid.UUID
	Lines               []SaleLine
	Tenders             []Tender

	// CreditOverride is set only when the operator has EXPLICITLY chosen to
	// exceed the customer's credit limit for this specific sale, and the HTTP
	// handler has confirmed the caller holds the credit.override permission.
	// Simply holding the permission is not enough — PRD 10.1 requires an
	// explicit approval decision with a recorded reason, not a silent bypass
	// that happens merely because the logged-in role includes the
	// permission. When Requested is true, Reason must be non-empty.
	CreditOverride struct {
		Requested bool
		Reason    string
	}
}

type FinalizeResult struct {
	InvoiceID     uuid.UUID
	InvoiceNumber string
	GrandTotal    decimal.Decimal
	Duplicate     bool // true if this was an idempotent replay of an already-finalized invoice
}

// InvoiceListPage is one page of the invoice history/reprint list.
type InvoiceListPage struct {
	Invoices []InvoiceHeader
	Total    int
}

// ListInvoices returns finalized invoices newest-first — the history/reprint
// screen's browse endpoint (distinct from GetInvoiceForReturn's single
// lookup-by-number, which exists purely to feed the returns line picker).
func (s *Service) ListInvoices(ctx context.Context, tenantID uuid.UUID, query string, limit, offset int) (*InvoiceListPage, error) {
	var page InvoiceListPage
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		invoices, total, err := ListInvoices(ctx, tx, query, limit, offset)
		if err != nil {
			return err
		}
		page.Invoices = invoices
		page.Total = total
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &page, nil
}

// InvoiceDetail is the full reprint view of one past sale: header, lines,
// and how it was actually paid for.
type InvoiceDetail struct {
	Header  *InvoiceHeader
	Lines   []InvoiceLineSummary
	Tenders []InvoiceTenderRecord
}

func (s *Service) GetInvoiceDetail(ctx context.Context, tenantID, invoiceID uuid.UUID) (*InvoiceDetail, error) {
	var result InvoiceDetail
	err := s.db.WithTenantReadTx(ctx, tenantID, func(tx pgx.Tx) error {
		header, err := GetInvoiceByID(ctx, tx, invoiceID)
		if err != nil {
			return err
		}
		lines, err := ListInvoiceLines(ctx, tx, header.ID)
		if err != nil {
			return err
		}
		tenders, err := ListTenders(ctx, tx, header.ID)
		if err != nil {
			return err
		}
		result.Header = header
		result.Lines = lines
		result.Tenders = tenders
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

// FinalizeInvoice is the single authoritative, atomic transaction for a POS
// sale: it validates stock, allocates batches (FEFO/FIFO), calculates tax
// from the current tax-profile snapshot, validates the tender split,
// enforces the customer credit limit, posts the stock ledger, the customer
// ledger (if credit was used), and a balanced accounting journal — all in one
// PostgreSQL transaction. If any step fails, nothing is committed: an
// invoice never exists as "successful" with only some of its postings done
// (PRD A10).
func (s *Service) FinalizeInvoice(ctx context.Context, tenantID, deviceID, userID uuid.UUID, req FinalizeRequest) (*FinalizeResult, error) {
	if len(req.Lines) == 0 {
		return nil, fmt.Errorf("%w: at least one line is required", ErrValidation)
	}
	if len(req.Tenders) == 0 {
		return nil, fmt.Errorf("%w: at least one tender is required", ErrValidation)
	}

	var result FinalizeResult
	err := s.db.WithTenantTx(ctx, tenantID, func(tx pgx.Tx) error {
		// --- Idempotency: a retried finalize from the same device with the
		// same client_transaction_id returns the original result untouched. ---
		if existing, err := FindByClientTransactionID(ctx, tx, deviceID, req.ClientTransactionID); err == nil {
			result = FinalizeResult{InvoiceID: existing.ID, InvoiceNumber: existing.InvoiceNumber, GrandTotal: existing.GrandTotal, Duplicate: true}
			return nil
		} else if !errors.Is(err, ErrNotFound) {
			return fmt.Errorf("check idempotency: %w", err)
		}

		fifoFefoPolicy, _, err := inventory.GetTenantPolicy(ctx, tx, tenantID)
		if err != nil {
			return fmt.Errorf("load tenant policy: %w", err)
		}

		// Every sale must be billed against a customer — never nothing.
		// A CREDIT tender already requires the caller to have picked a real,
		// accountable customer (checked below); for a sale with no credit
		// tender and no customer captured, fall back to the tenant's
		// "Walking Customer" rather than leaving customer_id null, so every
		// invoice/journal/ledger entry has a home. See customer.GetOrCreateWalkIn.
		if req.CustomerID == nil {
			hasCreditTender := false
			for _, t := range req.Tenders {
				if t.Method == "CREDIT" {
					hasCreditTender = true
					break
				}
			}
			if !hasCreditTender {
				walkIn, err := customer.GetOrCreateWalkIn(ctx, tx, tenantID)
				if err != nil {
					return fmt.Errorf("resolve walk-in customer: %w", err)
				}
				req.CustomerID = &walkIn.ID
			}
		}

		var customerName *string
		var customerCode string
		if req.CustomerID != nil {
			c, err := customer.GetByID(ctx, tx, *req.CustomerID)
			if err != nil {
				return fmt.Errorf("load customer: %w", err)
			}
			if c.Status != "ACTIVE" {
				return fmt.Errorf("%w: customer is not active", ErrValidation)
			}
			customerName = &c.Name
			customerCode = c.CustomerCode
		}

		type preparedLine struct {
			input        SaleLine
			product      *product.Product
			unitPrice    decimal.Decimal
			taxableValue decimal.Decimal
			taxProfile   *TaxProfile
			taxComps     []TaxComponent
			taxTotal     decimal.Decimal
			lineTotal    decimal.Decimal
			allocations  []inventory.Allocation
		}

		var (
			prepared      []preparedLine
			subtotal      = decimal.Zero
			discountTotal = decimal.Zero
			taxableTotal  = decimal.Zero
			taxTotal      = decimal.Zero
			taxByType     = map[string]decimal.Decimal{}
		)

		for _, line := range req.Lines {
			priced, err := priceLine(ctx, tx, line)
			if err != nil {
				return err
			}
			for _, c := range priced.taxComps {
				taxByType[c.Type] = taxByType[c.Type].Add(c.Amount)
			}

			allocations, err := inventory.AllocateForSale(ctx, tx, tenantID, priced.product.ID, req.LocationID, line.Quantity, fifoFefoPolicy)
			if err != nil {
				if errors.Is(err, inventory.ErrInsufficientStock) {
					return fmt.Errorf("%w: product %s", inventory.ErrInsufficientStock, priced.product.SKU)
				}
				return fmt.Errorf("allocate stock for %s: %w", priced.product.SKU, err)
			}

			subtotal = subtotal.Add(priced.unitPrice.Mul(line.Quantity))
			discountTotal = discountTotal.Add(line.DiscountAmount)
			taxableTotal = taxableTotal.Add(priced.taxableValue)
			taxTotal = taxTotal.Add(priced.taxTotal)

			prepared = append(prepared, preparedLine{
				input: line, product: priced.product, unitPrice: priced.unitPrice, taxableValue: priced.taxableValue,
				taxProfile: priced.taxProfile, taxComps: priced.taxComps, taxTotal: priced.taxTotal,
				lineTotal: priced.lineTotal, allocations: allocations,
			})
		}

		grandTotal := taxableTotal.Add(taxTotal)

		tenderTotal := decimal.Zero
		creditAmount := decimal.Zero
		for _, t := range req.Tenders {
			if t.Amount.LessThanOrEqual(decimal.Zero) {
				return fmt.Errorf("%w: tender amount must be positive", ErrValidation)
			}
			tenderTotal = tenderTotal.Add(t.Amount)
			if t.Method == "CREDIT" {
				creditAmount = creditAmount.Add(t.Amount)
			}
		}
		if !tenderTotal.Equal(grandTotal) {
			return fmt.Errorf("%w: tenders total %s, invoice grand total %s", ErrTenderMismatch, tenderTotal, grandTotal)
		}

		creditOverrideApplied := false
		if creditAmount.GreaterThan(decimal.Zero) {
			if req.CustomerID == nil {
				return fmt.Errorf("%w: credit tender requires a customer", ErrValidation)
			}
			// Hard rule, never overridable by credit.override: the Walking
			// Customer is a shared anonymous bucket with no single
			// accountable person behind it — extending credit to it would
			// mean every unknown walk-in shares one open-ended balance no
			// one can ever be asked to repay. Only a real, registered
			// customer can be billed on credit. This check is intentionally
			// placed before the credit-limit/override logic below so no
			// permission or reason can bypass it. Keyed off customer_code,
			// not customer_type — WALK_IN is also this table's default type
			// for any ordinary customer nobody categorized, so plenty of
			// real customers can legitimately share that type (see
			// customer.List's doc comment); customer_code is the only value
			// GetOrCreateWalkIn reserves uniquely for this one row.
			if customerCode == customer.WalkInCustomerCode {
				return fmt.Errorf("%w: the Walking Customer cannot be used for a credit sale — select a registered customer", ErrValidation)
			}
			profile, err := customer.GetCreditProfile(ctx, tx, *req.CustomerID)
			if err != nil {
				return fmt.Errorf("load credit profile: %w", err)
			}
			outstanding, err := customer.OutstandingBalance(ctx, tx, *req.CustomerID)
			if err != nil {
				return fmt.Errorf("load outstanding balance: %w", err)
			}
			projected := outstanding.Add(creditAmount)
			if projected.GreaterThan(profile.CreditLimit) {
				// Holding the credit.override permission is not sufficient on
				// its own (PRD 10.1): the operator must explicitly request the
				// override for this specific sale and give a reason, which the
				// HTTP handler has already gated on the caller actually holding
				// the permission before it ever reaches here.
				if !req.CreditOverride.Requested {
					return fmt.Errorf("%w: projected balance %s exceeds limit %s", ErrCreditLimitExceeded, projected, profile.CreditLimit)
				}
				if req.CreditOverride.Reason == "" {
					return fmt.Errorf("%w: a reason is required to override the credit limit", ErrValidation)
				}
				creditOverrideApplied = true
			}
		}

		financialYearID, err := accounting.GetActiveFinancialYear(ctx, tx, tenantID)
		if err != nil {
			return fmt.Errorf("resolve financial year: %w", err)
		}
		invoiceNumber, err := AllocateInvoiceNumber(ctx, tx, tenantID, financialYearID)
		if err != nil {
			return fmt.Errorf("allocate invoice number: %w", err)
		}

		paymentStatus := "PAID"
		if creditAmount.GreaterThan(decimal.Zero) {
			paymentStatus = "CREDIT"
		}

		header := &InvoiceHeader{
			FinancialYearID:     financialYearID,
			InvoiceNumber:       invoiceNumber,
			CustomerID:          req.CustomerID,
			CustomerNameSnap:    customerName,
			Subtotal:            subtotal,
			DiscountTotal:       discountTotal,
			TaxableTotal:        taxableTotal,
			TaxTotal:            taxTotal,
			RoundingAmount:      decimal.Zero,
			GrandTotal:          grandTotal,
			PaymentStatus:       paymentStatus,
			Source:              "ONLINE",
			ClientTransactionID: &req.ClientTransactionID,
			DeviceID:            &deviceID,
			CashierUserID:       &userID,
		}
		if err := InsertInvoiceHeader(ctx, tx, tenantID, header); err != nil {
			return fmt.Errorf("insert invoice header: %w", err)
		}

		for i, pl := range prepared {
			var hsn *string
			if pl.product.HSNCode != nil {
				hsn = pl.product.HSNCode
			}
			uomCode, err := GetUOMCode(ctx, tx, pl.product.DefaultSaleUOMID)
			if err != nil {
				return fmt.Errorf("load uom code: %w", err)
			}
			snapshot, err := json.Marshal(map[string]interface{}{
				"tax_profile_id": pl.taxProfile.ID,
				"code":           pl.taxProfile.Code,
				"cgst_rate":      pl.taxProfile.CGSTRate,
				"sgst_rate":      pl.taxProfile.SGSTRate,
				"igst_rate":      pl.taxProfile.IGSTRate,
				"cess_rate":      pl.taxProfile.CessRate,
			})
			if err != nil {
				return fmt.Errorf("marshal tax snapshot: %w", err)
			}

			lineRec := &InvoiceLineInput{
				LineNo: i + 1, ProductID: pl.product.ID, ProductNameSnap: pl.product.Name,
				SKUSnap: pl.product.SKU, HSNSnap: hsn, UOMID: pl.product.DefaultSaleUOMID,
				UOMCodeSnap: uomCode, Quantity: pl.input.Quantity, UnitPrice: pl.unitPrice,
				DiscountAmount: pl.input.DiscountAmount, TaxableValue: pl.taxableValue,
				TaxProfileSnapshot: snapshot, TaxTotal: pl.taxTotal, LineTotal: pl.lineTotal,
			}
			lineID, err := InsertInvoiceLine(ctx, tx, tenantID, header.ID, lineRec)
			if err != nil {
				return fmt.Errorf("insert invoice line: %w", err)
			}

			for _, c := range pl.taxComps {
				if err := InsertTaxLine(ctx, tx, tenantID, header.ID, TaxLineInput{
					InvoiceLineID: lineID, TaxType: c.Type, Rate: c.Rate,
					TaxableValue: pl.taxableValue, TaxAmount: c.Amount,
				}); err != nil {
					return fmt.Errorf("insert tax line: %w", err)
				}
			}

			for _, alloc := range pl.allocations {
				if err := InsertBatchAllocation(ctx, tx, tenantID, lineID, alloc.BatchID, pl.product.DefaultSaleUOMID, alloc.Quantity, alloc.UnitCost); err != nil {
					return fmt.Errorf("insert batch allocation: %w", err)
				}
				batchID := alloc.BatchID
				if err := inventory.PostStockMovement(ctx, tx, tenantID, inventory.StockMovement{
					ProductID: pl.product.ID, BatchID: &batchID, LocationID: req.LocationID,
					UOMID: pl.product.DefaultSaleUOMID, Quantity: alloc.Quantity,
					SignedQuantity: alloc.Quantity.Neg(), MovementType: "SALE",
					SourceType: "INVOICE", SourceID: &header.ID, SourceLineID: &lineID,
					UnitCost: &alloc.UnitCost, DeviceID: &deviceID, CreatedByUserID: &userID,
				}); err != nil {
					return fmt.Errorf("post stock movement: %w", err)
				}
			}
		}

		for _, t := range req.Tenders {
			if err := InsertTender(ctx, tx, tenantID, header.ID, t.Method, t.Amount, nil, nil); err != nil {
				return fmt.Errorf("insert tender: %w", err)
			}
		}

		if creditAmount.GreaterThan(decimal.Zero) {
			description := fmt.Sprintf("Credit sale %s", invoiceNumber)
			if creditOverrideApplied {
				description = fmt.Sprintf("Credit sale %s (credit limit override: %s)", invoiceNumber, req.CreditOverride.Reason)
			}
			if _, err := customer.PostLedgerEntry(ctx, tx, tenantID, customer.LedgerEntry{
				CustomerID: *req.CustomerID, DocumentType: "INVOICE", DocumentID: header.ID,
				Debit: creditAmount, Credit: decimal.Zero,
				Description: description,
				DeviceID:    &deviceID, CreatedByUserID: &userID,
			}); err != nil {
				return fmt.Errorf("post customer ledger entry: %w", err)
			}
		}

		if err := postSaleJournal(ctx, tx, tenantID, financialYearID, header.ID, invoiceNumber, req.Tenders, creditAmount, taxableTotal, taxByType, req.CustomerID); err != nil {
			return fmt.Errorf("post journal: %w", err)
		}

		auditPayload := map[string]interface{}{"invoice_number": invoiceNumber, "grand_total": grandTotal.String()}
		if creditOverrideApplied {
			auditPayload["credit_limit_override"] = true
			auditPayload["credit_override_reason"] = req.CreditOverride.Reason
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO audit_logs (tenant_id, actor_user_id, actor_device_id, action_code, entity_type, entity_id, after_json)
			VALUES ($1,$2,$3,'INVOICE_FINALIZED','sales_invoice',$4,$5)
		`, tenantID, userID, deviceID, header.ID, auditPayload); err != nil {
			return fmt.Errorf("write audit log: %w", err)
		}
		if creditOverrideApplied {
			if _, err := tx.Exec(ctx, `
				INSERT INTO audit_logs (tenant_id, actor_user_id, actor_device_id, action_code, entity_type, entity_id, reason, after_json)
				VALUES ($1,$2,$3,'CREDIT_OVERRIDE','sales_invoice',$4,$5,$6)
			`, tenantID, userID, deviceID, header.ID, req.CreditOverride.Reason,
				map[string]interface{}{"invoice_number": invoiceNumber, "credit_amount": creditAmount.String()}); err != nil {
				return fmt.Errorf("write credit override audit log: %w", err)
			}
		}

		result = FinalizeResult{InvoiceID: header.ID, InvoiceNumber: invoiceNumber, GrandTotal: grandTotal}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

func tenderAccountCode(method string) (code, name string) {
	switch method {
	case "CASH":
		return "CASH", "Cash on Hand"
	case "UPI":
		return "UPI_CLEARING", "UPI Clearing Account"
	case "BANK":
		return "BANK", "Bank Account"
	case "CREDIT":
		return "ACCOUNTS_RECEIVABLE", "Trade Receivables"
	default:
		return "OTHER_SETTLEMENT", "Other Settlement"
	}
}

func taxAccountCode(taxType string) (code, name string) {
	return "GST_" + taxType + "_PAYABLE", "GST " + taxType + " Payable"
}

// postSaleJournal posts one balanced double-entry journal for a finalized
// sale: a debit line per tender method (cash/UPI/bank/receivable) and credit
// lines for sales revenue and each GST component. The PostgreSQL deferred
// trigger fn_check_journal_balance verifies sum(debit)=sum(credit) at commit.
func postSaleJournal(ctx context.Context, tx pgx.Tx, tenantID, financialYearID, invoiceID uuid.UUID, invoiceNumber string, tenders []Tender, creditAmount, taxableTotal decimal.Decimal, taxByType map[string]decimal.Decimal, customerID *uuid.UUID) error {
	// Merge same-method tenders (e.g. two CASH lines) into one journal debit.
	byMethod := map[string]decimal.Decimal{}
	for _, t := range tenders {
		byMethod[t.Method] = byMethod[t.Method].Add(t.Amount)
	}

	var lines []accounting.JournalLine
	for method, amount := range byMethod {
		code, name := tenderAccountCode(method)
		accountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, code, name, accountTypeFor(code))
		if err != nil {
			return err
		}
		line := accounting.JournalLine{AccountID: accountID, Debit: amount, Credit: decimal.Zero, Description: "Tender: " + method}
		if method == "CREDIT" {
			line.CustomerID = customerID
		}
		lines = append(lines, line)
	}

	salesAccountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, "SALES", "Sales Revenue", "INCOME")
	if err != nil {
		return err
	}
	lines = append(lines, accounting.JournalLine{AccountID: salesAccountID, Debit: decimal.Zero, Credit: taxableTotal, Description: "Sales revenue"})

	for taxType, amount := range taxByType {
		if amount.IsZero() {
			continue
		}
		code, name := taxAccountCode(taxType)
		accountID, err := accounting.GetOrCreateAccount(ctx, tx, tenantID, code, name, "LIABILITY")
		if err != nil {
			return err
		}
		lines = append(lines, accounting.JournalLine{AccountID: accountID, Debit: decimal.Zero, Credit: amount, Description: taxType + " payable"})
	}

	journalNumber := "JRNL-" + invoiceNumber
	_, err = accounting.PostJournal(ctx, tx, tenantID, financialYearID, journalNumber, "INVOICE", invoiceID, "Sale "+invoiceNumber, lines)
	return err
}

func accountTypeFor(code string) string {
	if code == "ACCOUNTS_RECEIVABLE" {
		return "ASSET"
	}
	return "ASSET"
}
