// Package models holds the domain types shared across the store and API layers.
package models

import "time"

type User struct {
	ID            string    `json:"id"`
	TailscaleID   string    `json:"-"`
	DisplayName   string    `json:"displayName"`
	AvatarMediaID *string   `json:"avatarMediaId,omitempty"`
	CreatedAt     time.Time `json:"createdAt"`
	UpdatedAt     time.Time `json:"updatedAt"`
}

type Room struct {
	ID        string    `json:"id"`
	Name      *string   `json:"name,omitempty"`
	IsGroup   bool      `json:"isGroup"`
	CreatedBy string    `json:"createdBy"`
	CreatedAt time.Time `json:"createdAt"`
	Members   []string  `json:"members,omitempty"`

	// Populated by ListRoomsForUser for the room list UI; absent (all nil)
	// for a room with no messages yet.
	LastMessageBody *string      `json:"lastMessageBody,omitempty"`
	LastMessageKind *MessageKind `json:"lastMessageKind,omitempty"`
	LastMessageAt   *time.Time   `json:"lastMessageAt,omitempty"`
}

type MessageKind string

const (
	MessageKindText     MessageKind = "text"
	MessageKindImage    MessageKind = "image"
	MessageKindVideo    MessageKind = "video"
	MessageKindLocation MessageKind = "location"
	MessageKindCall     MessageKind = "call"
)

type Message struct {
	ID        string            `json:"id"`
	RoomID    string            `json:"roomId"`
	SenderID  string            `json:"senderId"`
	Kind      MessageKind       `json:"kind"`
	Body      *string           `json:"body,omitempty"`
	MediaID   *string           `json:"mediaId,omitempty"`
	CreatedAt time.Time         `json:"createdAt"`
	EditedAt  *time.Time        `json:"editedAt,omitempty"`
	Reactions []ReactionSummary `json:"reactions,omitempty"`

	// ReplyToMessageID is set when this message is a reply (FR1.10). ReplyTo
	// is a lightweight snapshot of the quoted message, populated alongside it
	// so clients can render the quote without a second round trip; both are
	// absent if this isn't a reply, and ReplyTo alone is absent if the
	// original was later deleted (the FK is ON DELETE SET NULL).
	ReplyToMessageID *string         `json:"replyToMessageId,omitempty"`
	ReplyTo          *MessageSnippet `json:"replyTo,omitempty"`
	// Forwarded marks a message created via the forward action (FR1.11).
	Forwarded bool `json:"forwarded,omitempty"`
}

// MessageSnippet is a trimmed preview of another message, embedded in a
// reply (FR1.10). Body is truncated by the store so a reply to a long text
// message doesn't carry the whole thing around a second time.
type MessageSnippet struct {
	ID       string      `json:"id"`
	SenderID string      `json:"senderId"`
	Kind     MessageKind `json:"kind"`
	Body     *string     `json:"body,omitempty"`
}

// ReactionSummary groups message_reactions rows by emoji for one message
// (FR1.9): how many people reacted with this emoji, and whether the
// requesting user is one of them (so the client can render it toggled-on).
type ReactionSummary struct {
	Emoji       string `json:"emoji"`
	Count       int    `json:"count"`
	ReactedByMe bool   `json:"reactedByMe"`
}

// LinkPreview is fetched server-side for a URL found in a text message
// (FR1.14) — see internal/linkpreview. It's the second documented exception
// to "no open ports"/self-hosted (see docs/architecture-overview.md): the
// chat server makes one outbound HTTPS fetch to the linked site to read its
// Open Graph metadata, never accepting a connection from it.
type LinkPreview struct {
	URL         string `json:"url"`
	Title       string `json:"title,omitempty"`
	Description string `json:"description,omitempty"`
	ImageURL    string `json:"imageUrl,omitempty"`
	SiteName    string `json:"siteName,omitempty"`
}

// MediaObject is a pointer to one uploaded file's bytes in MinIO (FR2.*).
type MediaObject struct {
	ID          string    `json:"id"`
	Bucket      string    `json:"-"`
	ObjectKey   string    `json:"-"`
	ContentType string    `json:"contentType"`
	SizeBytes   int64     `json:"sizeBytes"`
	UploadedBy  string    `json:"uploadedBy"`
	CreatedAt   time.Time `json:"createdAt"`
}

// LocationShare is the FR3.* subtype attached to a Kind == MessageKindLocation message.
// The TTL is enforced by comparing ExpiresAt at read time; there is no deletion job.
type LocationShare struct {
	MessageID string     `json:"messageId"`
	Lat       float64    `json:"lat"`
	Lng       float64    `json:"lng"`
	ExpiresAt time.Time  `json:"expiresAt"`
	EndedAt   *time.Time `json:"endedAt,omitempty"`
}

func (l LocationShare) Active(now time.Time) bool {
	if l.EndedAt != nil && !l.EndedAt.After(now) {
		return false
	}
	return now.Before(l.ExpiresAt)
}

type Device struct {
	ID         string    `json:"id"`
	UserID     string    `json:"userId"`
	Platform   string    `json:"platform"` // "ios" | "android"
	PushToken  string    `json:"-"`
	LastSeenAt time.Time `json:"lastSeenAt"`
}

type CallStatus string

const (
	CallStatusRinging   CallStatus = "ringing"
	CallStatusCompleted CallStatus = "completed"
	CallStatusMissed    CallStatus = "missed"
	CallStatusDeclined  CallStatus = "declined"
)

type Call struct {
	ID        string     `json:"id"`
	RoomID    string     `json:"roomId"`
	StartedBy string     `json:"startedBy"`
	Status    CallStatus `json:"status"`
	StartedAt time.Time  `json:"startedAt"`
	EndedAt   *time.Time `json:"endedAt,omitempty"`
}
