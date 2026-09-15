-- Per-recipient delivery/seen tracking (FR1.5, FR1.6).
--
-- One row per (message, user) the message was addressed to. delivered_at is
-- set once that user's client has explicitly acknowledged receiving the
-- message (not merely that a WebSocket write succeeded); seen_at is set once
-- it has been visible in that user's viewport with the chat open. seen
-- implies delivered — the store's upsert never sets one without the other.
--
-- A message's overall status (sent/delivered/seen), shown to the sender, is
-- computed at read time by comparing counts here against room membership
-- (see models.ComputeMessageStatus) rather than stored — the "all other
-- members" rule depends on room_members, which can itself change over time.
CREATE TABLE message_receipts (
    message_id   UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    delivered_at TIMESTAMPTZ,
    seen_at      TIMESTAMPTZ,
    PRIMARY KEY (message_id, user_id)
);
