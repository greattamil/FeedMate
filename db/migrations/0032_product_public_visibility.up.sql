-- Opt-in flag for the public marketing-website catalog (GET
-- /api/v1/public/catalog) — defaults to false so the ERP's full internal
-- catalog is never exposed publicly by accident; a shop must explicitly
-- mark each product it wants visible on bpkscattlefeeds.com.
ALTER TABLE products ADD COLUMN show_on_website boolean NOT NULL DEFAULT false;
