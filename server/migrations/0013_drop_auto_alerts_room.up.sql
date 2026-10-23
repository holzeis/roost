-- The alert identity no longer creates an "Alerts" group of its own: it posts
-- to the groups someone adds it to. Remove the one it auto-created (and its
-- messages). Only the alert identity has a 'tag:' tailscale_id.
DELETE FROM rooms
WHERE is_group AND created_by IN (SELECT id FROM users WHERE tailscale_id LIKE 'tag:%');
