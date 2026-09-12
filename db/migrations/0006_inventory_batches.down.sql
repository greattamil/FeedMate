DROP TABLE IF EXISTS stock_adjustments;
DROP TABLE IF EXISTS stock_count_lines;
DROP TABLE IF EXISTS stock_counts;
DROP TABLE IF EXISTS stock_balances;
DROP TABLE IF EXISTS stock_movements;
ALTER TABLE IF EXISTS goods_receipt_lines DROP CONSTRAINT IF EXISTS fk_grn_lines_batch;
ALTER TABLE IF EXISTS batches DROP CONSTRAINT IF EXISTS fk_batches_grn_line;
DROP TABLE IF EXISTS batches;
