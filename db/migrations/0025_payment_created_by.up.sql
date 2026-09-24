-- Records which authenticated user collected a manual receipt/payment, so it
-- can be shown when a cashier reopens an old receipt later (previously this
-- was only known transiently, client-side, from the recording session).
ALTER TABLE payments ADD COLUMN created_by_user_id uuid REFERENCES users(id);
