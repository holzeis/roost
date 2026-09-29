-- FR1.15: deleting a message that someone has already seen leaves a
-- "Deleted message" placeholder instead of removing it outright. The row
-- stays with its content wiped (body/media_id cleared, reactions and
-- subtype rows removed) and deleted_at set. A message nobody has seen yet
-- is still hard-deleted, as before.
ALTER TABLE messages ADD COLUMN deleted_at TIMESTAMPTZ;
