-- Reply and forward support for chat messages.
--
-- reply_to_message_id: the message this one is quoting (FR1.10). ON DELETE
-- SET NULL rather than CASCADE — deleting the original shouldn't delete the
-- reply that referenced it, it should just leave the reply pointing at
-- nothing (the client falls back to an "original message" placeholder).
--
-- forwarded: true for a message created via the forward action (FR1.11), so
-- clients can render a "Forwarded" label. Forwarding never sets
-- reply_to_message_id — the two are mutually exclusive actions.
ALTER TABLE messages
    ADD COLUMN reply_to_message_id UUID REFERENCES messages(id) ON DELETE SET NULL,
    ADD COLUMN forwarded BOOLEAN NOT NULL DEFAULT false;

CREATE INDEX messages_reply_to_message_id_idx ON messages (reply_to_message_id) WHERE reply_to_message_id IS NOT NULL;
