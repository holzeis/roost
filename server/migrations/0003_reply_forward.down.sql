DROP INDEX messages_reply_to_message_id_idx;
ALTER TABLE messages
    DROP COLUMN reply_to_message_id,
    DROP COLUMN forwarded;
