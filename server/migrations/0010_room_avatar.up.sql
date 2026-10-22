-- Group image: a member of a group room can set a picture for it, shown in
-- the chat list, the chat header and group info. Nullable (a room starts
-- without one, and 1:1 rooms never have one — they show the other person's
-- profile picture instead). Same media_objects pointer as users.avatar_media_id.
ALTER TABLE rooms
    ADD COLUMN avatar_media_id UUID REFERENCES media_objects(id) ON DELETE SET NULL;
