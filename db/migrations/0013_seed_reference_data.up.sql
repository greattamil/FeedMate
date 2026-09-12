-- Migration 0013: global (tenant_id NULL) reference data — standard UOMs and their conversions.
-- Tenant-specific data (tax profiles, price lists, customer tiers, roles) is NEVER seeded here;
-- it is created through the controlled tenant onboarding / seed workflow (see db/seed).

INSERT INTO uoms (id, tenant_id, code, name, symbol, dimension, decimal_scale) VALUES
    ('00000000-0000-0000-0000-000000000101', NULL, 'KG', 'Kilogram', 'kg', 'WEIGHT', 3),
    ('00000000-0000-0000-0000-000000000102', NULL, 'G',  'Gram', 'g', 'WEIGHT', 3),
    ('00000000-0000-0000-0000-000000000103', NULL, 'TON','Tonne', 't', 'WEIGHT', 3),
    ('00000000-0000-0000-0000-000000000104', NULL, 'BAG','Bag', 'bag', 'COUNT', 0),
    ('00000000-0000-0000-0000-000000000105', NULL, 'PC', 'Piece', 'pc', 'COUNT', 0),
    ('00000000-0000-0000-0000-000000000106', NULL, 'L',  'Litre', 'L', 'VOLUME', 3),
    ('00000000-0000-0000-0000-000000000107', NULL, 'ML', 'Millilitre', 'ml', 'VOLUME', 3);

-- Fixed physical conversions (exact, dimension-consistent). Bag<->kg is intentionally NOT
-- seeded here because bag weight is package-specific and must be configured per product
-- via product_uoms.conversion_to_base (see PRD 6.2 / DB spec 9.4).
INSERT INTO uom_conversions (tenant_id, from_uom_id, to_uom_id, factor, product_specific) VALUES
    (NULL, '00000000-0000-0000-0000-000000000103', '00000000-0000-0000-0000-000000000101', 1000.000000, false), -- 1 tonne = 1000 kg
    (NULL, '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000102', 1000.000000, false), -- 1 kg = 1000 g
    (NULL, '00000000-0000-0000-0000-000000000106', '00000000-0000-0000-0000-000000000107', 1000.000000, false); -- 1 L = 1000 ml
