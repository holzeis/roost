-- Notes the chat makes about itself ("Alice added Bob", "Alice left"): the
-- sender is who did it, the body is the text shown.
ALTER TABLE messages DROP CONSTRAINT messages_kind_check;
ALTER TABLE messages ADD CONSTRAINT messages_kind_check
    CHECK (kind IN ('text', 'image', 'video', 'location', 'call', 'system'));
