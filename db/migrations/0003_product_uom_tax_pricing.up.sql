-- Migration 0003: categories, brands, UOM, products, aliases, barcodes, tax profiles, pricing

CREATE TABLE categories (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenants(id),
    name        varchar(150) NOT NULL,
    local_name  varchar(150),
    active      boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name),
    UNIQUE (tenant_id, id)
);

CREATE TABLE brands (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenants(id),
    name        varchar(150) NOT NULL,
    local_name  varchar(150),
    active      boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name),
    UNIQUE (tenant_id, id)
);

-- UOMs: tenant_id nullable = global/system-defined unit, usable by all tenants.
CREATE TABLE uoms (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid REFERENCES tenants(id),
    code            varchar(20) NOT NULL,
    name            varchar(80) NOT NULL,
    symbol          varchar(20) NOT NULL,
    dimension       varchar(20) NOT NULL CHECK (dimension IN ('WEIGHT','COUNT','VOLUME','OTHER')),
    decimal_scale   integer NOT NULL DEFAULT 3,
    active          boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_uoms_tenant_code ON uoms (COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), code);

CREATE TABLE uom_conversions (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid REFERENCES tenants(id),
    from_uom_id         uuid NOT NULL REFERENCES uoms(id),
    to_uom_id           uuid NOT NULL REFERENCES uoms(id),
    factor              numeric(12,6) NOT NULL CHECK (factor > 0), -- 1 from_uom = factor * to_uom
    product_specific    boolean NOT NULL DEFAULT false,
    product_id          uuid, -- FK added in migration 0006 after products table (deferred via ALTER there is unnecessary; product FK added below is not possible yet)
    effective_from      date NOT NULL DEFAULT CURRENT_DATE,
    effective_to        date,
    reason              varchar(250),
    created_at          timestamptz NOT NULL DEFAULT now(),
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);
CREATE INDEX idx_uom_conversions_lookup ON uom_conversions (tenant_id, from_uom_id, to_uom_id, effective_from);

CREATE TABLE products (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               uuid NOT NULL REFERENCES tenants(id),
    sku                     varchar(80) NOT NULL,
    name                    varchar(250) NOT NULL,
    local_name_ta           varchar(250),
    category_id             uuid,
    brand_id                uuid,
    default_sale_uom_id     uuid NOT NULL REFERENCES uoms(id),
    default_purchase_uom_id uuid NOT NULL REFERENCES uoms(id),
    base_inventory_uom_id   uuid NOT NULL REFERENCES uoms(id),
    hsn_code                varchar(20),
    tax_profile_id          uuid,
    pack_size               numeric(12,3),
    standard_weight_kg      numeric(12,3),
    mrp                     numeric(12,2),
    selling_price           numeric(12,2),
    reorder_level           numeric(12,3),
    reorder_target          numeric(12,3),
    reorder_lead_time_days  integer,
    min_price_floor         numeric(12,2),
    batch_required          boolean NOT NULL DEFAULT true,
    expiry_required         boolean NOT NULL DEFAULT true,
    loose_sale_allowed      boolean NOT NULL DEFAULT false,
    scale_required          boolean NOT NULL DEFAULT false,
    product_type            varchar(20) NOT NULL DEFAULT 'FEED' CHECK (product_type IN ('FEED','SUPPLEMENT','ADDITIVE','SERVICE','OTHER')),
    active                  boolean NOT NULL DEFAULT true,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, sku),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, category_id) REFERENCES categories (tenant_id, id),
    FOREIGN KEY (tenant_id, brand_id) REFERENCES brands (tenant_id, id)
);
CREATE INDEX idx_products_tenant_active ON products (tenant_id, active);
CREATE INDEX idx_products_name_trgm ON products USING gin (name gin_trgm_ops);
CREATE INDEX idx_products_local_name_trgm ON products USING gin (local_name_ta gin_trgm_ops);

ALTER TABLE uom_conversions
    ADD CONSTRAINT fk_uom_conversions_product
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id);

CREATE TABLE product_uoms (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    product_id          uuid NOT NULL,
    uom_id              uuid NOT NULL REFERENCES uoms(id),
    is_purchase_uom     boolean NOT NULL DEFAULT false,
    is_sale_uom         boolean NOT NULL DEFAULT false,
    is_inventory_uom    boolean NOT NULL DEFAULT false,
    pack_size           numeric(12,3),
    standard_weight_kg  numeric(12,3),
    conversion_to_base  numeric(12,6) NOT NULL,
    active              boolean NOT NULL DEFAULT true,
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    UNIQUE (tenant_id, product_id, uom_id)
);

CREATE TABLE product_barcodes (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL,
    product_id  uuid NOT NULL,
    barcode     varchar(80) NOT NULL,
    barcode_type varchar(20) NOT NULL DEFAULT 'EAN13',
    is_primary  boolean NOT NULL DEFAULT false,
    active      boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    UNIQUE (tenant_id, barcode)
);

CREATE TABLE product_aliases (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    product_id      uuid NOT NULL,
    alias_text      varchar(250) NOT NULL,
    normalized_text varchar(250) NOT NULL,
    language_code   varchar(10) NOT NULL DEFAULT 'ta',
    script_code     varchar(10),
    alias_type      varchar(20) NOT NULL DEFAULT 'COLLOQUIAL' CHECK (alias_type IN ('CANONICAL','COLLOQUIAL','TRANSLITERATION','PHONETIC','ABBREVIATION','ENGLISH')),
    region_code     varchar(20),
    priority        integer NOT NULL DEFAULT 100,
    active          boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id)
);
CREATE INDEX idx_product_aliases_normalized_trgm ON product_aliases USING gin (normalized_text gin_trgm_ops);
CREATE INDEX idx_product_aliases_product ON product_aliases (tenant_id, product_id);

-- =====================================================================
-- Tax profiles (effective-dated, configuration-driven — never hardcode rates)
-- =====================================================================
CREATE TABLE tax_profiles (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL REFERENCES tenants(id),
    code                varchar(40) NOT NULL,
    description         varchar(250) NOT NULL,
    supply_type         varchar(20) NOT NULL DEFAULT 'INTRA_STATE' CHECK (supply_type IN ('INTRA_STATE','INTER_STATE','EXPORT','EXEMPT','NON_GST')),
    hsn_applicability   varchar(20),
    cgst_rate           numeric(7,4) NOT NULL DEFAULT 0,
    sgst_rate           numeric(7,4) NOT NULL DEFAULT 0,
    igst_rate           numeric(7,4) NOT NULL DEFAULT 0,
    cess_rate           numeric(7,4) NOT NULL DEFAULT 0,
    exemption_type      varchar(30),
    price_inclusive     boolean NOT NULL DEFAULT false,
    rounding_policy     varchar(20) NOT NULL DEFAULT 'ROUND_HALF_UP' CHECK (rounding_policy IN ('ROUND_HALF_UP','ROUND_HALF_EVEN','ROUND_DOWN')),
    effective_from      date NOT NULL DEFAULT CURRENT_DATE,
    effective_to        date,
    active              boolean NOT NULL DEFAULT true,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code, effective_from),
    UNIQUE (tenant_id, id),
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);

ALTER TABLE products
    ADD CONSTRAINT fk_products_tax_profile
    FOREIGN KEY (tenant_id, tax_profile_id) REFERENCES tax_profiles (tenant_id, id);

CREATE TABLE customer_tiers (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                   uuid NOT NULL REFERENCES tenants(id),
    code                        varchar(40) NOT NULL,
    name                        varchar(150) NOT NULL,
    default_discount_type      varchar(10) CHECK (default_discount_type IN ('PERCENT','FIXED') OR default_discount_type IS NULL),
    default_discount_value     numeric(12,4),
    credit_allowed              boolean NOT NULL DEFAULT false,
    priority                    integer NOT NULL DEFAULT 100,
    active                      boolean NOT NULL DEFAULT true,
    created_at                  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code),
    UNIQUE (tenant_id, id)
);

CREATE TABLE price_lists (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL REFERENCES tenants(id),
    name                varchar(150) NOT NULL,
    customer_tier_id    uuid,
    currency_code       char(3) NOT NULL DEFAULT 'INR',
    effective_from      date NOT NULL DEFAULT CURRENT_DATE,
    effective_to        date,
    priority             integer NOT NULL DEFAULT 100,
    active              boolean NOT NULL DEFAULT true,
    created_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, id),
    FOREIGN KEY (tenant_id, customer_tier_id) REFERENCES customer_tiers (tenant_id, id),
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);

CREATE TABLE price_list_items (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid NOT NULL,
    price_list_id       uuid NOT NULL,
    product_id          uuid NOT NULL,
    uom_id              uuid NOT NULL REFERENCES uoms(id),
    unit_price          numeric(12,2) NOT NULL CHECK (unit_price >= 0),
    minimum_quantity    numeric(12,3) NOT NULL DEFAULT 0,
    discount_type       varchar(10) CHECK (discount_type IN ('PERCENT','FIXED') OR discount_type IS NULL),
    discount_value      numeric(12,4),
    effective_from      date NOT NULL DEFAULT CURRENT_DATE,
    effective_to        date,
    customer_id         uuid, -- nullable: customer-specific override, FK added in 0004
    FOREIGN KEY (tenant_id, price_list_id) REFERENCES price_lists (tenant_id, id),
    FOREIGN KEY (tenant_id, product_id) REFERENCES products (tenant_id, id),
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);
CREATE INDEX idx_price_list_items_lookup ON price_list_items (tenant_id, product_id, effective_from);
