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

A user's push-capable devices (FR5.1).

| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `user_id` | uuid, FK → `users` | |
| `platform` | text | `ios` \| `android` |
| `push_token` | text | APNs device token or FCM registration token |
| `created_at`, `last_seen_at` | timestamptz | |

### media_objects

A pointer to one object in MinIO. Rows are never deleted by a background job
— images/video persist indefinitely by default (FR2.4); manual delete (FR2.5)
removes both the row and the object.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `bucket`, `object_key` | text | Where the bytes live in MinIO |
| `content_type` | text | |
| `size_bytes` | bigint | |
| `uploaded_by` | uuid, FK → `users` | |
| `created_at` | timestamptz | |

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
| `media_id` | uuid, FK → `media_objects`, nullable | |
| `created_at`, `edited_at` | timestamptz | |

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

- Delivery/read receipts (FR1.5, FR1.6) and typing indicators (FR1.7) —
  Should/Could priority, deferred; likely ephemeral (WebSocket-only) rather
  than persisted, when built.
- Per-room "who's online" (FR6.5) is derived at runtime from the chat
  server's WebSocket hub (`server/internal/ws`), not stored.
