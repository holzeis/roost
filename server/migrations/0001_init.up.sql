-- Initial schema: users, devices, rooms, messages (with media/location subtypes),
-- media objects, reactions, and calls. See docs/data-model.md for the narrative version.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tailscale_id     TEXT NOT NULL UNIQUE, -- stable identity from Tailscale WhoIs (login name)
    display_name     TEXT NOT NULL,
    avatar_media_id  UUID, -- FK to media_objects, added after that table exists
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE devices (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    platform      TEXT NOT NULL CHECK (platform IN ('ios', 'android')),
    push_token    TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, push_token)
);

CREATE TABLE media_objects (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket        TEXT NOT NULL,
    object_key    TEXT NOT NULL,
    content_type  TEXT NOT NULL,
    size_bytes    BIGINT NOT NULL,
    uploaded_by   UUID NOT NULL REFERENCES users(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (bucket, object_key)
);

ALTER TABLE users
    ADD CONSTRAINT users_avatar_media_id_fkey
    FOREIGN KEY (avatar_media_id) REFERENCES media_objects(id) ON DELETE SET NULL;

CREATE TABLE rooms (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT, -- null for 1:1 rooms; derived client-side from the other member
    is_group    BOOLEAN NOT NULL DEFAULT false,
    created_by  UUID NOT NULL REFERENCES users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE room_members (
    room_id    UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    joined_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    muted      BOOLEAN NOT NULL DEFAULT false, -- FR5.3: per-room notification mute
    PRIMARY KEY (room_id, user_id)
);

CREATE TABLE messages (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id      UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    sender_id    UUID NOT NULL REFERENCES users(id),
    kind         TEXT NOT NULL CHECK (kind IN ('text', 'image', 'video', 'location', 'call')),
    body         TEXT, -- text content for kind = 'text'
    media_id     UUID REFERENCES media_objects(id), -- set for kind IN ('image', 'video')
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    edited_at    TIMESTAMPTZ
);

CREATE INDEX messages_room_id_created_at_idx ON messages (room_id, created_at DESC);

-- Full-text search over text message bodies (FR1.8).
ALTER TABLE messages ADD COLUMN body_tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(body, ''))) STORED;
CREATE INDEX messages_body_tsv_idx ON messages USING GIN (body_tsv);

-- Location shares are a 1:1 subtype of a 'location' message (FR3.*).
-- The TTL is enforced at read time against expires_at; there is no cleanup job.
CREATE TABLE location_shares (
    message_id  UUID PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
    lat         DOUBLE PRECISION NOT NULL,
    lng         DOUBLE PRECISION NOT NULL,
    expires_at  TIMESTAMPTZ NOT NULL,
    ended_at    TIMESTAMPTZ -- set when the sender manually ends the share early (FR3.5)
);

CREATE TABLE message_reactions (
    message_id  UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    emoji       TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (message_id, user_id, emoji)
);

-- One row per call attempt, linked to the missed-call message shown in history (FR4.8).
CREATE TABLE calls (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id     UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    message_id  UUID REFERENCES messages(id) ON DELETE SET NULL,
    started_by  UUID NOT NULL REFERENCES users(id),
    status      TEXT NOT NULL CHECK (status IN ('ringing', 'completed', 'missed', 'declined')),
    started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at    TIMESTAMPTZ
);

CREATE TABLE call_participants (
    call_id    UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    joined_at  TIMESTAMPTZ,
    left_at    TIMESTAMPTZ,
    PRIMARY KEY (call_id, user_id)
);
