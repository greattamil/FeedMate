-- Migration 0009: chart_of_accounts, journal_entries, journal_lines, contra, cash sessions, EOD

CREATE TABLE chart_of_accounts (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants(id),
    account_code    varchar(30) NOT NULL,
    account_name    varchar(150) NOT NULL,
    account_type    varchar(20) NOT NULL CHECK (account_type IN ('ASSET','LIABILITY','EQUITY','INCOME','EXPENSE')),
    active          boolean NOT NULL DEFAULT true,
    UNIQUE (tenant_id, account_code),
    UNIQUE (tenant_id, id)
);

CREATE TABLE journal_entries (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    financial_year_id   uuid NOT NULL,
    journal_number      varchar(60) NOT NULL,
    entry_date          timestamptz NOT NULL DEFAULT now(),
    source_type         varchar(40) NOT NULL, -- INVOICE/GRN/RECEIPT/CONTRA/EOD/etc.
    source_id           uuid,
    description         varchar(500),
    status              varchar(20) NOT NULL DEFAULT 'POSTED' CHECK (status IN ('POSTED','REVERSED')),
    posted_at           timestamptz NOT NULL DEFAULT now(),
    posted_by_user_id   uuid,
    reversal_of_id      uuid,
    FOREIGN KEY (tenant_id, financial_year_id) REFERENCES financial_years (tenant_id, id),
    UNIQUE (tenant_id, journal_number),
    UNIQUE (tenant_id, id)
);
CREATE INDEX idx_journal_entries_source ON journal_entries (tenant_id, source_type, source_id);

CREATE TABLE journal_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    journal_entry_id    uuid NOT NULL,
    account_id          uuid NOT NULL,
    debit               numeric(12,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
    credit              numeric(12,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
    customer_id         uuid,
    supplier_id         uuid,
    product_id          uuid,
    batch_id            uuid,
    description         varchar(500),
    FOREIGN KEY (tenant_id, journal_entry_id) REFERENCES journal_entries (tenant_id, id),
    FOREIGN KEY (tenant_id, account_id) REFERENCES chart_of_accounts (tenant_id, id),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id),
    FOREIGN KEY (tenant_id, supplier_id) REFERENCES suppliers (tenant_id, id),
    CHECK (NOT (debit > 0 AND credit > 0))
);
CREATE INDEX idx_journal_lines_entry ON journal_lines (tenant_id, journal_entry_id);

-- Trigger: enforce sum(debit) = sum(credit) per journal entry at commit time (deferred constraint trigger).
CREATE OR REPLACE FUNCTION fn_check_journal_balance() RETURNS trigger AS $$
DECLARE
    v_debit numeric(14,2);
    v_credit numeric(14,2);
    v_journal_id uuid;
BEGIN
    v_journal_id := COALESCE(NEW.journal_entry_id, OLD.journal_entry_id);
    SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0)
      INTO v_debit, v_credit
      FROM journal_lines WHERE journal_entry_id = v_journal_id;
    IF v_debit <> v_credit THEN
        RAISE EXCEPTION 'Journal entry % is not balanced: debit=% credit=%', v_journal_id, v_debit, v_credit;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_journal_balance
    AFTER INSERT OR UPDATE OR DELETE ON journal_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_check_journal_balance();

CREATE TABLE contra_transactions (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    contra_number       varchar(60) NOT NULL,
    customer_id         uuid NOT NULL,
    contra_date         timestamptz NOT NULL DEFAULT now(),
    status              varchar(20) NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','PENDING_APPROVAL','POSTED','REVERSED','CANCELLED')),
    total_value         numeric(12,2) NOT NULL DEFAULT 0,
    approved_by_user_id uuid,
    approved_at         timestamptz,
    source_reference    varchar(150),
    created_by_user_id  uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, customer_id) REFERENCES customers (tenant_id, id),
    UNIQUE (tenant_id, contra_number),
    UNIQUE (tenant_id, id)
);

CREATE TABLE contra_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    contra_transaction_id uuid NOT NULL,
    product_id          uuid NOT NULL,
    batch_id            uuid,
    quantity            numeric(12,3) NOT NULL CHECK (quantity > 0),
    uom_id              uuid NOT NULL REFERENCES uoms(id),
    valuation_unit_price numeric(12,2) NOT NULL CHECK (valuation_unit_price >= 0),
    value               numeric(12,2) NOT NULL,
    quality_status      varchar(20) NOT NULL DEFAULT 'ACCEPTED' CHECK (quality_status IN ('ACCEPTED','REJECTED','QUARANTINE')),
    location_id         uuid NOT NULL,
    FOREIGN KEY (tenant_id, contra_transaction_id) REFERENCES contra_transactions (tenant_id, id),
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    FOREIGN KEY (tenant_id, location_id) REFERENCES inventory_locations (tenant_id, id)
);

CREATE TABLE cash_sessions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    device_id       uuid,
    location_id     uuid,
    business_date   date NOT NULL,
    opening_cash    numeric(12,2) NOT NULL DEFAULT 0,
    opened_by_user_id uuid,
    opened_at       timestamptz NOT NULL DEFAULT now(),
    status          varchar(20) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED')),
    UNIQUE (tenant_id, id),
    UNIQUE (tenant_id, device_id, business_date)
);

CREATE TABLE cash_movements (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    cash_session_id     uuid NOT NULL,
    movement_type       varchar(20) NOT NULL CHECK (movement_type IN ('SALE','REFUND','PAYOUT','EXPENSE','DEPOSIT','WITHDRAWAL','ADJUSTMENT')),
    source_id           uuid,
    amount              numeric(12,2) NOT NULL CHECK (amount > 0),
    direction           varchar(10) NOT NULL CHECK (direction IN ('IN','OUT')),
    reason              varchar(500),
    created_by_user_id  uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, cash_session_id) REFERENCES cash_sessions (tenant_id, id)
);
CREATE INDEX idx_cash_movements_session ON cash_movements (tenant_id, cash_session_id);

CREATE TABLE eod_sessions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    business_date   date NOT NULL,
    cash_session_id uuid,
    opening_cash    numeric(12,2) NOT NULL DEFAULT 0,
    cash_sales      numeric(12,2) NOT NULL DEFAULT 0,
    cash_refunds    numeric(12,2) NOT NULL DEFAULT 0,
    cash_payouts    numeric(12,2) NOT NULL DEFAULT 0,
    expected_cash   numeric(12,2) NOT NULL DEFAULT 0,
    actual_cash     numeric(12,2),
    variance        numeric(12,2),
    variance_reason varchar(500),
    status          varchar(20) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED','REOPENED')),
    closed_by_user_id uuid,
    closed_at       timestamptz,
    reopened_by_user_id uuid,
    reopened_at     timestamptz,
    reopen_reason   varchar(500),
    FOREIGN KEY (tenant_id, cash_session_id) REFERENCES cash_sessions (tenant_id, id),
    UNIQUE (tenant_id, business_date),
    UNIQUE (tenant_id, id)
);
