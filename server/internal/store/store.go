// Package store implements Postgres-backed persistence for the domain
// models. It's hand-written SQL via pgx rather than an ORM, in keeping with
// the project's "reuse mature infra, build only what's product-specific"
// principle — the query surface here is small and stable enough that an ORM
// would add indirection without saving real effort.
package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"roost/server/internal/models"
)

var ErrNotFound = errors.New("store: not found")

type Store struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Store {
	return &Store{pool: pool}
}

// GetOrCreateUserByTailscaleID implements just-in-time provisioning (FR6.1):
// the first request from a given Tailscale identity creates the user row.
func (s *Store) GetOrCreateUserByTailscaleID(ctx context.Context, tailscaleID, defaultDisplayName string) (models.User, error) {
	const q = `
		INSERT INTO users (tailscale_id, display_name)
		VALUES ($1, $2)
		ON CONFLICT (tailscale_id) DO UPDATE SET tailscale_id = EXCLUDED.tailscale_id
		RETURNING id, tailscale_id, display_name, avatar_media_id, created_at, updated_at`
	return scanUser(s.pool.QueryRow(ctx, q, tailscaleID, defaultDisplayName))
}

func (s *Store) GetUser(ctx context.Context, id string) (models.User, error) {
	const q = `SELECT id, tailscale_id, display_name, avatar_media_id, created_at, updated_at FROM users WHERE id = $1`
	return scanUser(s.pool.QueryRow(ctx, q, id))
}

// ListUsers returns every provisioned user (FR6: the contact list is simply
// everyone who has ever connected — there's no separate contacts/friends
// concept at family scale), ordered for a stable contacts list.
func (s *Store) ListUsers(ctx context.Context) ([]models.User, error) {
	const q = `SELECT id, tailscale_id, display_name, avatar_media_id, created_at, updated_at FROM users ORDER BY display_name`
	rows, err := s.pool.Query(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("store: list users: %w", err)
	}
	defer rows.Close()

	var users []models.User
	for rows.Next() {
		var u models.User
		if err := rows.Scan(&u.ID, &u.TailscaleID, &u.DisplayName, &u.AvatarMediaID, &u.CreatedAt, &u.UpdatedAt); err != nil {
			return nil, fmt.Errorf("store: scan user: %w", err)
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

func (s *Store) UpdateUserProfile(ctx context.Context, id, displayName string, avatarMediaID *string) (models.User, error) {
	const q = `
		UPDATE users SET display_name = $2, avatar_media_id = $3, updated_at = now()
		WHERE id = $1
		RETURNING id, tailscale_id, display_name, avatar_media_id, created_at, updated_at`
	return scanUser(s.pool.QueryRow(ctx, q, id, displayName, avatarMediaID))
}

func scanUser(row pgx.Row) (models.User, error) {
	var u models.User
	err := row.Scan(&u.ID, &u.TailscaleID, &u.DisplayName, &u.AvatarMediaID, &u.CreatedAt, &u.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return models.User{}, ErrNotFound
	}
	if err != nil {
		return models.User{}, fmt.Errorf("store: scan user: %w", err)
	}
	return u, nil
}

// CreateRoom creates a room and adds creatorID plus memberIDs as members.
func (s *Store) CreateRoom(ctx context.Context, creatorID string, name *string, isGroup bool, memberIDs []string) (models.Room, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return models.Room{}, fmt.Errorf("store: begin: %w", err)
	}
	defer tx.Rollback(ctx)

	var room models.Room
	const insertRoom = `
		INSERT INTO rooms (name, is_group, created_by) VALUES ($1, $2, $3)
		RETURNING id, name, is_group, created_by, created_at`
	if err := tx.QueryRow(ctx, insertRoom, name, isGroup, creatorID).
		Scan(&room.ID, &room.Name, &room.IsGroup, &room.CreatedBy, &room.CreatedAt); err != nil {
		return models.Room{}, fmt.Errorf("store: insert room: %w", err)
	}

	members := append([]string{creatorID}, memberIDs...)
	const insertMember = `INSERT INTO room_members (room_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`
	for _, memberID := range members {
		if _, err := tx.Exec(ctx, insertMember, room.ID, memberID); err != nil {
			return models.Room{}, fmt.Errorf("store: add member: %w", err)
		}
	}
	room.Members = members

	if err := tx.Commit(ctx); err != nil {
		return models.Room{}, fmt.Errorf("store: commit: %w", err)
	}
	return room, nil
}

// ListRoomsForUser returns userID's rooms, each with its most recent message
// (if any) for the room-list preview, most recently active first.
// FindDirectRoom returns the existing 1:1 (non-group) room between userA
// and userB, if one exists — used to avoid creating duplicate 1:1
// conversations every time a contact is tapped (FR1.1).
func (s *Store) FindDirectRoom(ctx context.Context, userA, userB string) (models.Room, error) {
	const q = `
		SELECT r.id FROM rooms r
		WHERE r.is_group = false
		  AND EXISTS (SELECT 1 FROM room_members WHERE room_id = r.id AND user_id = $1)
		  AND EXISTS (SELECT 1 FROM room_members WHERE room_id = r.id AND user_id = $2)
		  AND (SELECT COUNT(*) FROM room_members WHERE room_id = r.id) = 2
		LIMIT 1`
	var roomID string
	err := s.pool.QueryRow(ctx, q, userA, userB).Scan(&roomID)
	if errors.Is(err, pgx.ErrNoRows) {
		return models.Room{}, ErrNotFound
	}
	if err != nil {
		return models.Room{}, fmt.Errorf("store: find direct room: %w", err)
	}
	return s.GetRoom(ctx, roomID)
}

func (s *Store) ListRoomsForUser(ctx context.Context, userID string) ([]models.Room, error) {
	const q = `
		SELECT r.id, r.name, r.is_group, r.created_by, r.created_at,
		       lm.body, lm.kind, lm.created_at
		FROM rooms r
		JOIN room_members rm ON rm.room_id = r.id
		LEFT JOIN LATERAL (
			SELECT body, kind, created_at FROM messages
			WHERE room_id = r.id
			ORDER BY created_at DESC
			LIMIT 1
		) lm ON true
		WHERE rm.user_id = $1
		ORDER BY COALESCE(lm.created_at, r.created_at) DESC`
	rows, err := s.pool.Query(ctx, q, userID)
	if err != nil {
		return nil, fmt.Errorf("store: list rooms: %w", err)
	}
	defer rows.Close()

	var rooms []models.Room
	for rows.Next() {
		var r models.Room
		var lastKind *string
		if err := rows.Scan(&r.ID, &r.Name, &r.IsGroup, &r.CreatedBy, &r.CreatedAt, &r.LastMessageBody, &lastKind, &r.LastMessageAt); err != nil {
			return nil, fmt.Errorf("store: scan room: %w", err)
		}
		if lastKind != nil {
			kind := models.MessageKind(*lastKind)
			r.LastMessageKind = &kind
		}
		rooms = append(rooms, r)
	}
	return rooms, rows.Err()
}

// GetRoom returns a single room with its member IDs populated, for the chat
// screen header (FR1.4: who else is in this room).
func (s *Store) GetRoom(ctx context.Context, roomID string) (models.Room, error) {
	const q = `SELECT id, name, is_group, created_by, created_at FROM rooms WHERE id = $1`
	var r models.Room
	err := s.pool.QueryRow(ctx, q, roomID).Scan(&r.ID, &r.Name, &r.IsGroup, &r.CreatedBy, &r.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return models.Room{}, ErrNotFound
	}
	if err != nil {
		return models.Room{}, fmt.Errorf("store: get room: %w", err)
	}
	members, err := s.ListRoomMemberIDs(ctx, roomID)
	if err != nil {
		return models.Room{}, err
	}
	r.Members = members
	return r, nil
}

func (s *Store) ListRoomMemberIDs(ctx context.Context, roomID string) ([]string, error) {
	const q = `SELECT user_id FROM room_members WHERE room_id = $1`
	rows, err := s.pool.Query(ctx, q, roomID)
	if err != nil {
		return nil, fmt.Errorf("store: list room members: %w", err)
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("store: scan member id: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func (s *Store) IsRoomMember(ctx context.Context, roomID, userID string) (bool, error) {
	const q = `SELECT EXISTS(SELECT 1 FROM room_members WHERE room_id = $1 AND user_id = $2)`
	var exists bool
	if err := s.pool.QueryRow(ctx, q, roomID, userID).Scan(&exists); err != nil {
		return false, fmt.Errorf("store: check membership: %w", err)
	}
	return exists, nil
}

func (s *Store) CreateTextMessage(ctx context.Context, roomID, senderID, body string) (models.Message, error) {
	const q = `
		INSERT INTO messages (room_id, sender_id, kind, body) VALUES ($1, $2, 'text', $3)
		RETURNING id, room_id, sender_id, kind, body, media_id, created_at, edited_at`
	return scanMessage(s.pool.QueryRow(ctx, q, roomID, senderID, body))
}

// CreateMediaObject records a MinIO upload's pointer row (FR2.1/2.2). The
// bytes themselves are already in MinIO by the time this is called — see
// the upload handler in internal/api, which uploads first so a DB failure
// never leaves a message referencing bytes that don't exist.
func (s *Store) CreateMediaObject(ctx context.Context, bucket, objectKey, contentType string, sizeBytes int64, uploadedBy string) (models.MediaObject, error) {
	const q = `
		INSERT INTO media_objects (bucket, object_key, content_type, size_bytes, uploaded_by)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, bucket, object_key, content_type, size_bytes, uploaded_by, created_at`
	var m models.MediaObject
	err := s.pool.QueryRow(ctx, q, bucket, objectKey, contentType, sizeBytes, uploadedBy).
		Scan(&m.ID, &m.Bucket, &m.ObjectKey, &m.ContentType, &m.SizeBytes, &m.UploadedBy, &m.CreatedAt)
	if err != nil {
		return models.MediaObject{}, fmt.Errorf("store: create media object: %w", err)
	}
	return m, nil
}

func (s *Store) GetMediaObject(ctx context.Context, id string) (models.MediaObject, error) {
	const q = `SELECT id, bucket, object_key, content_type, size_bytes, uploaded_by, created_at FROM media_objects WHERE id = $1`
	var m models.MediaObject
	err := s.pool.QueryRow(ctx, q, id).Scan(&m.ID, &m.Bucket, &m.ObjectKey, &m.ContentType, &m.SizeBytes, &m.UploadedBy, &m.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return models.MediaObject{}, ErrNotFound
	}
	if err != nil {
		return models.MediaObject{}, fmt.Errorf("store: get media object: %w", err)
	}
	return m, nil
}

func (s *Store) DeleteMediaObject(ctx context.Context, id string) error {
	if _, err := s.pool.Exec(ctx, `DELETE FROM media_objects WHERE id = $1`, id); err != nil {
		return fmt.Errorf("store: delete media object: %w", err)
	}
	return nil
}

// CreateMediaMessage is CreateTextMessage's counterpart for FR2.1/2.2:
// kind is "image" or "video", body is left null, media_id points at the
// already-created media_objects row.
func (s *Store) CreateMediaMessage(ctx context.Context, roomID, senderID, kind, mediaID string) (models.Message, error) {
	const q = `
		INSERT INTO messages (room_id, sender_id, kind, media_id) VALUES ($1, $2, $3, $4)
		RETURNING id, room_id, sender_id, kind, body, media_id, created_at, edited_at`
	return scanMessage(s.pool.QueryRow(ctx, q, roomID, senderID, kind, mediaID))
}

func (s *Store) GetMessage(ctx context.Context, id string) (models.Message, error) {
	const q = `SELECT id, room_id, sender_id, kind, body, media_id, created_at, edited_at FROM messages WHERE id = $1`
	return scanMessage(s.pool.QueryRow(ctx, q, id))
}

// GetMessageByMediaID finds the message a media object belongs to — used
// before deleting the media object (which cascades to delete this message
// row, see migration 0002) so the caller can still broadcast which room and
// message just disappeared.
func (s *Store) GetMessageByMediaID(ctx context.Context, mediaID string) (models.Message, error) {
	const q = `SELECT id, room_id, sender_id, kind, body, media_id, created_at, edited_at FROM messages WHERE media_id = $1`
	return scanMessage(s.pool.QueryRow(ctx, q, mediaID))
}

// AddReaction is idempotent: reacting twice with the same emoji is a no-op,
// not an error (message_reactions' primary key is (message_id, user_id, emoji)).
func (s *Store) AddReaction(ctx context.Context, messageID, userID, emoji string) error {
	const q = `INSERT INTO message_reactions (message_id, user_id, emoji) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`
	if _, err := s.pool.Exec(ctx, q, messageID, userID, emoji); err != nil {
		return fmt.Errorf("store: add reaction: %w", err)
	}
	return nil
}

func (s *Store) RemoveReaction(ctx context.Context, messageID, userID, emoji string) error {
	const q = `DELETE FROM message_reactions WHERE message_id = $1 AND user_id = $2 AND emoji = $3`
	if _, err := s.pool.Exec(ctx, q, messageID, userID, emoji); err != nil {
		return fmt.Errorf("store: remove reaction: %w", err)
	}
	return nil
}

// AttachReactions populates each message's Reactions field in place, grouped
// by emoji, with ReactedByMe relative to callerID — one query regardless of
// how many messages, so list/search endpoints stay a fixed two round-trips.
func (s *Store) AttachReactions(ctx context.Context, callerID string, messages []models.Message) error {
	if len(messages) == 0 {
		return nil
	}
	ids := make([]string, len(messages))
	byID := make(map[string]*models.Message, len(messages))
	for i := range messages {
		ids[i] = messages[i].ID
		byID[messages[i].ID] = &messages[i]
	}

	const q = `
		SELECT message_id, emoji, COUNT(*), BOOL_OR(user_id = $1)
		FROM message_reactions
		WHERE message_id = ANY($2)
		GROUP BY message_id, emoji
		ORDER BY message_id, emoji`
	rows, err := s.pool.Query(ctx, q, callerID, ids)
	if err != nil {
		return fmt.Errorf("store: attach reactions: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var messageID, emoji string
		var count int
		var reactedByMe bool
		if err := rows.Scan(&messageID, &emoji, &count, &reactedByMe); err != nil {
			return fmt.Errorf("store: scan reaction summary: %w", err)
		}
		if m, ok := byID[messageID]; ok {
			m.Reactions = append(m.Reactions, models.ReactionSummary{Emoji: emoji, Count: count, ReactedByMe: reactedByMe})
		}
	}
	return rows.Err()
}

func scanMessage(row pgx.Row) (models.Message, error) {
	var m models.Message
	var kind string
	err := row.Scan(&m.ID, &m.RoomID, &m.SenderID, &kind, &m.Body, &m.MediaID, &m.CreatedAt, &m.EditedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return models.Message{}, ErrNotFound
	}
	if err != nil {
		return models.Message{}, fmt.Errorf("store: scan message: %w", err)
	}
	m.Kind = models.MessageKind(kind)
	return m, nil
}

// ListMessages returns up to limit messages in roomID older than before (or
// the most recent ones if before is zero), newest first.
func (s *Store) ListMessages(ctx context.Context, roomID string, before time.Time, limit int) ([]models.Message, error) {
	if before.IsZero() {
		before = time.Now().Add(24 * time.Hour)
	}
	const q = `
		SELECT id, room_id, sender_id, kind, body, media_id, created_at, edited_at
		FROM messages
		WHERE room_id = $1 AND created_at < $2
		ORDER BY created_at DESC
		LIMIT $3`
	rows, err := s.pool.Query(ctx, q, roomID, before, limit)
	if err != nil {
		return nil, fmt.Errorf("store: list messages: %w", err)
	}
	defer rows.Close()

	var messages []models.Message
	for rows.Next() {
		var m models.Message
		var kind string
		if err := rows.Scan(&m.ID, &m.RoomID, &m.SenderID, &kind, &m.Body, &m.MediaID, &m.CreatedAt, &m.EditedAt); err != nil {
			return nil, fmt.Errorf("store: scan message: %w", err)
		}
		m.Kind = models.MessageKind(kind)
		messages = append(messages, m)
	}
	return messages, rows.Err()
}

// SearchMessages implements FR1.8, using the generated body_tsv column.
func (s *Store) SearchMessages(ctx context.Context, roomID, query string) ([]models.Message, error) {
	const q = `
		SELECT id, room_id, sender_id, kind, body, media_id, created_at, edited_at
		FROM messages
		WHERE room_id = $1 AND body_tsv @@ plainto_tsquery('english', $2)
		ORDER BY created_at DESC
		LIMIT 100`
	rows, err := s.pool.Query(ctx, q, roomID, query)
	if err != nil {
		return nil, fmt.Errorf("store: search messages: %w", err)
	}
	defer rows.Close()

	var messages []models.Message
	for rows.Next() {
		m, err := scanMessageRow(rows)
		if err != nil {
			return nil, err
		}
		messages = append(messages, m)
	}
	return messages, rows.Err()
}

func scanMessageRow(rows pgx.Rows) (models.Message, error) {
	var m models.Message
	var kind string
	if err := rows.Scan(&m.ID, &m.RoomID, &m.SenderID, &kind, &m.Body, &m.MediaID, &m.CreatedAt, &m.EditedAt); err != nil {
		return models.Message{}, fmt.Errorf("store: scan message: %w", err)
	}
	m.Kind = models.MessageKind(kind)
	return m, nil
}
