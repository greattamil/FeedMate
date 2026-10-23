-- Firebase Cloud Messaging push-token storage per device (Android only for
-- now). Nullable — a device with no token just never receives pushes,
-- same graceful-degrade convention as every other optional integration in
-- this app.
ALTER TABLE devices ADD COLUMN fcm_token text;
ALTER TABLE devices ADD COLUMN fcm_token_updated_at timestamptz;
