-- FR2.*: a photo's pixel dimensions, captured once at upload time, let
-- clients reserve the correct aspect ratio before the image itself has
-- downloaded (no more layout jump once it loads). preview_object_key points
-- at a second, lower-quality re-encode of the same image (same dimensions,
-- just more compressed) stored alongside the original in MinIO — the inline
-- chat bubble fetches that instead of the full-quality original, which is
-- only ever fetched when the full-screen viewer opens it. All three are
-- nullable: populated for images the server could decode (JPEG/PNG/GIF),
-- left null for video or anything undecodable (WebP/HEIC aren't supported
-- by Go's standard image package) — those fall back to serving the
-- original for both purposes, same as before this migration.
ALTER TABLE media_objects ADD COLUMN width INT;
ALTER TABLE media_objects ADD COLUMN height INT;
ALTER TABLE media_objects ADD COLUMN preview_object_key TEXT;
