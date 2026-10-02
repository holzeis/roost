-- FR5.2: a device's X25519 public key for end-to-end encrypted message
-- previews in push notifications. The server encrypts each preview to the
-- receiving device's key, so Apple/Google only ever see ciphertext; only
-- that device holds the private key. Nullable: a device that hasn't sent
-- one (an older app version, or a "voip" call-wake row) gets the generic
-- notification text instead.
ALTER TABLE devices ADD COLUMN push_public_key TEXT;
