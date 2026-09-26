# Roost — data model

The single current source of truth for schema, alongside the actual migration
files in `server/migrations/`. Any schema change updates this doc and adds a
new numbered migration in the same commit — see CLAUDE.md.

Postgres is the only structured store (`docs/architecture-overview.md` —
"Postgres for structured data, not a bespoke store"). Media bytes live in
MinIO; Postgres only holds a pointer (`media_objects`) to each object.

## Entities

### users

One row per Tailscale identity that has ever connected. Created just-in-time
on first authenticated request — there's no signup flow (FR6.1).

| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `tailscale_id` | text, unique | Tailscale login name (e.g. `alice@github`); the durable key identity resolution provisions/looks up by |
| `display_name` | text | Editable (FR6.4); seeded from the Tailscale profile on first contact |
| `avatar_media_id` | uuid, FK → `media_objects`, nullable | |
| `created_at`, `updated_at` | timestamptz | |

### devices

A user's push-capable devices (FR5.1 call wake, FR5.2 message notifications).
A single physical iOS device can have two rows — PushKit's VoIP token
(FR5.1) can only receive `apns-push-type: voip` pushes, so it can't double
as the token for a plain alert notification; Android's one FCM token
already covers both, so it never has more than one row per registration.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `user_id` | uuid, FK → `users` | |
| `platform` | text | `ios` \| `android` |
| `push_token` | text | APNs device token (VoIP or regular) or FCM registration token |
| `token_type` | text | `fcm` (message notifications, both platforms) \| `voip` (call wake, iOS only) — migration 0005 |
| `created_at`, `last_seen_at` | timestamptz | |

### media_objects

A pointer to one object in MinIO. Rows are never deleted by a background job
— images/video persist indefinitely by default (FR2.4); manual delete (FR2.5)
removes the row, the object in MinIO, and (via `messages.media_id`'s
`ON DELETE CASCADE`, migration 0002) the chat message it was attached to —
the message *was* the shared photo/video, so deleting one deletes the other.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `bucket`, `object_key` | text | Where the bytes live in MinIO |
| `content_type` | text | |
| `size_bytes` | bigint | |
| `uploaded_by` | uuid, FK → `users` | |
| `created_at` | timestamptz | |
| `width`, `height` | int, nullable | The decoded image's pixel dimensions, captured once at upload — lets clients reserve the right aspect ratio before the image has downloaded. Null for video, or an image format Go's standard library can't decode (WebP, HEIC/HEIF) — migration 0006 |
| `preview_object_key` | text, nullable | A second, lower-quality JPEG re-encode of the same image at those same dimensions (never resized, just more compressed), stored alongside the original — the chat bubble fetches this; the full-screen viewer fetches the original. Null whenever `width`/`height` are, since both come from the same decode — migration 0006 |

### rooms / room_members

A room is either a 1:1 (`is_group = false`, exactly 2 members, `name` null —
the client derives a display name from the other member) or a group
(`is_group = true`, named). `room_members.muted` backs per-room notification
muting (FR5.3).

| Column | Type | Notes |
|---|---|---|
| `rooms.id` | uuid, PK | |
| `rooms.name` | text, nullable | |
| `rooms.is_group` | boolean | |
| `rooms.created_by` | uuid, FK → `users` | |
| `rooms.created_at` | timestamptz | |
| `room_members.room_id`, `room_members.user_id` | uuid, composite PK | |
| `room_members.joined_at` | timestamptz | |
| `room_members.muted` | boolean | |

### messages

One row per chat event, including calls recorded in history (FR4.8). `kind`
picks which of the type-specific fields/subtype tables apply:

| `kind` | Uses |
|---|---|
| `text` | `body` |
| `image`, `video` | `media_id` |
| `location` | the `location_shares` subtype row (see below) |
| `call` | the `calls` row referencing this message via `calls.message_id` |

Full-text search (FR1.8) is a generated `body_tsv` column with a GIN index,
scoped to text bodies only.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `room_id` | uuid, FK → `rooms` | |
| `sender_id` | uuid, FK → `users` | |
| `kind` | text | see table above |
| `body` | text, nullable | |
| `media_id` | uuid, FK → `media_objects`, nullable, `ON DELETE CASCADE` | Deleting the media object deletes this message too (FR2.5) |
| `created_at`, `edited_at` | timestamptz | `edited_at` is also set by an edit (FR1.13), not just media deletion cascades |
| `reply_to_message_id` | uuid, FK → `messages`, nullable, `ON DELETE SET NULL` | The quoted message (FR1.10). Deleting the original clears this rather than deleting the reply — the reply just loses its preview |
| `forwarded` | boolean, default `false` | Set on a message created via the forward action (FR1.11), so clients can render a "Forwarded" label |

Forwarding never sets both `reply_to_message_id` and `forwarded` — they're
separate actions. Forwarding an image/video message doesn't reuse the
original's `media_id`; the server copies the object to a new key in MinIO
and creates an independent `media_objects` row for it (see below), so
deleting either the original or the forwarded copy never affects the other.

### location_shares

The FR3.* subtype, one row per `kind = 'location'` message. The share's TTL
(FR3.2) is stored once as `expires_at` — there is no periodic sweep. A read
simply checks `now() < expires_at AND (ended_at IS NULL OR now() < ended_at)`
(see `models.LocationShare.Active` in the server) to decide whether it's
still live (FR3.4); the row itself is retained after expiry like any other
message, since it's small structured data, not accumulating media.

| Column | Type | Notes |
|---|---|---|
| `message_id` | uuid, PK, FK → `messages` | |
| `lat`, `lng` | double precision | Latest known position |
| `expires_at` | timestamptz | Sender-chosen TTL (FR3.2) |
| `ended_at` | timestamptz, nullable | Set on manual early end (FR3.5) |

### message_reactions

Emoji reactions (FR1.9), one row per (message, user, emoji) triple.

| Column | Type | Notes |
|---|---|---|
| `message_id` | uuid, FK → `messages` | |
| `user_id` | uuid, FK → `users` | |
| `emoji` | text | |
| `created_at` | timestamptz | |

### message_receipts

Per-recipient delivery/seen tracking (FR1.5, FR1.6), one row per (message, user) once that
user has acknowledged the message. `seen_at` implies `delivered_at` — the store's upsert never
sets one without the other. A message's overall status (`sent` | `delivered` | `seen`), shown
to its sender, is computed at read time rather than stored: it's `seen` once every other member
of the room has `seen_at` set, `delivered` once every other member has `delivered_at` set, else
`sent` (see `models.ComputeMessageStatus`). "Every other member" is evaluated against
`room_members` at read time, not snapshotted, so it reflects the room's membership as of now.

| Column | Type | Notes |
|---|---|---|
| `message_id` | uuid, FK → `messages`, `ON DELETE CASCADE` | |
| `user_id` | uuid, FK → `users`, `ON DELETE CASCADE` | |
| `delivered_at` | timestamptz, nullable | |
| `seen_at` | timestamptz, nullable | |

Composite PK `(message_id, user_id)`.

### calls / call_participants

One `calls` row per call attempt (FR4.1, FR4.2), linked back to the
`messages` row that shows it in history. `call_participants` tracks who
actually joined vs. who was invited, for a future "who was on the call" view.

| Column | Type | Notes |
|---|---|---|
| `calls.id` | uuid, PK | |
| `calls.room_id` | uuid, FK → `rooms` | |
| `calls.message_id` | uuid, FK → `messages`, nullable | The history entry (FR4.8) |
| `calls.started_by` | uuid, FK → `users` | |
| `calls.status` | text | `ringing` \| `completed` \| `missed` \| `declined` |
| `calls.started_at`, `calls.ended_at` | timestamptz | |
| `call_participants.call_id`, `call_participants.user_id` | uuid, composite PK | |
| `call_participants.joined_at`, `call_participants.left_at` | timestamptz, nullable | |

## Not yet modeled

- Typing indicators (FR1.7) are implemented but intentionally unmodeled:
  ephemeral, WebSocket-only signals (`server/internal/ws/socket.go`'s
  `handleTypingSignal`) relayed between room members and never persisted.
- Per-room "who's online" (FR6.5) is derived at runtime from the chat
  server's WebSocket hub (`server/internal/ws`), not stored.
