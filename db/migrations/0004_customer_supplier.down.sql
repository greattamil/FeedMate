DROP TABLE IF EXISTS supplier_ledger_entries;
DROP TABLE IF EXISTS supplier_bank_accounts;
DROP TABLE IF EXISTS supplier_contacts;
DROP TABLE IF EXISTS suppliers;
DROP TABLE IF EXISTS customer_ledger_entries;
DROP TABLE IF EXISTS customer_credit_profiles;
DROP TABLE IF EXISTS customer_addresses;
ALTER TABLE IF EXISTS price_list_items DROP CONSTRAINT IF EXISTS fk_price_list_items_customer;
DROP TABLE IF EXISTS customers;
