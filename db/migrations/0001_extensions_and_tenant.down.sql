DROP TABLE IF EXISTS document_series;
ALTER TABLE IF EXISTS tenant_settings DROP CONSTRAINT IF EXISTS fk_tenant_settings_fy;
DROP TABLE IF EXISTS financial_years;
DROP TABLE IF EXISTS tenant_features;
DROP TABLE IF EXISTS tenant_settings;
DROP TABLE IF EXISTS tenants;
