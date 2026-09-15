ALTER TABLE messages DROP CONSTRAINT messages_media_id_fkey;
ALTER TABLE messages
    ADD CONSTRAINT messages_media_id_fkey
    FOREIGN KEY (media_id) REFERENCES media_objects(id);
