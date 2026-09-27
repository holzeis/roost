-- FR3.7: once a location share ends/expires, its preview switches from a
-- live map (repeatedly re-rendered, each a separately billed Maps Platform
-- load) to a single static snapshot fetched once by the server and stored
-- like any other media object. Nullable: populated lazily, the first time
-- any client actually asks to view an ended share (see
-- handleLocationSnapshot) — never eagerly, since most ended shares are
-- never revisited.
ALTER TABLE location_shares ADD COLUMN snapshot_media_id UUID REFERENCES media_objects(id);
