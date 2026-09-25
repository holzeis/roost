-- FR5.2: message-notification push needs a different token per purpose on
-- iOS specifically — PushKit's VoIP token (FR5.1) can only receive
-- apns-push-type: voip pushes, so a separate "regular" token is needed for
-- ordinary alert notifications. Android's single FCM token already serves
-- both purposes, so this only ever varies in practice for iOS rows: a
-- device may now have two rows, one per token_type.
ALTER TABLE devices ADD COLUMN token_type TEXT NOT NULL DEFAULT 'fcm'
    CHECK (token_type IN ('fcm', 'voip'));
