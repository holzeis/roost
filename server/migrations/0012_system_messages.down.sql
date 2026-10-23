DELETE FROM messages WHERE kind = 'system';
ALTER TABLE messages DROP CONSTRAINT messages_kind_check;
ALTER TABLE messages ADD CONSTRAINT messages_kind_check
    CHECK (kind IN ('text', 'image', 'video', 'location', 'call'));
