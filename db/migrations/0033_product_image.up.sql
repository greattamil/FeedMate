-- The product photo uploaded from the FeedMate app, stored as a URL
-- pointing at the product-images Worker/R2 bucket (see
-- deploy/cloudflare/product-images/) — never the image bytes themselves,
-- unlike tenants' logo_data_uri, since photos are shown on the public
-- marketing website's catalog grid and a jsonb-inline blob would make
-- every public-catalog response carry every product's full image.
ALTER TABLE products ADD COLUMN image_url text;
