-- Lets a shop owner turn off low/out-of-stock alerting for a specific
-- product (e.g. a made-to-order or rarely-stocked item they don't want
-- nagging them) without touching the reorder_level/reorder_target
-- thresholds themselves, which stay meaningful for anyone who does want
-- them. Defaults to true so every existing product keeps today's
-- behavior — this is an opt-out control, not an opt-in one.
ALTER TABLE products ADD COLUMN stock_alert_enabled boolean NOT NULL DEFAULT true;
