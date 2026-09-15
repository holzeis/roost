-- FR2.5: deleting a media object should delete the message it belongs to
-- (the message *was* the shared photo/video), not fail with a foreign key
-- violation or leave an orphaned message with a dangling media_id.
ALTER TABLE messages DROP CONSTRAINT messages_media_id_fkey;
ALTER TABLE messages
    ADD CONSTRAINT messages_media_id_fkey
    FOREIGN KEY (media_id) REFERENCES media_objects(id) ON DELETE CASCADE;
