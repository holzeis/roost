-- FR5.3: a member can mute a group for a while. `muted` (migration 0001)
-- now means "until I turn it back on"; `muted_until` is the timed mute and
-- simply lapses.
ALTER TABLE room_members ADD COLUMN muted_until TIMESTAMPTZ;
