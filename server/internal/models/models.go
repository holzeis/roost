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

	// Status is the sender-facing delivery/seen status (FR1.5, FR1.6),
	// computed at read time by the store from message_receipts — see
	// ComputeMessageStatus. Meaningful only for the sender's own messages;
	// clients should ignore it on messages from other users.
	Status MessageStatus `json:"status,omitempty"`

	// Location is the FR3.* subtype row for a Kind == MessageKindLocation
	// message, attached at read time (never stored on the message row
	// itself) — see AttachLocations.
	Location *LocationShare `json:"location,omitempty"`

	// Call is the FR4.* subtype row for a Kind == MessageKindCall message,
	// attached at read time like Location — see AttachCalls.
	Call *Call `json:"call,omitempty"`
}

// MessageStatus is the sender-facing delivery/seen status of a message
// (FR1.5, FR1.6).
type MessageStatus string

const (
	MessageStatusSent      MessageStatus = "sent"
	MessageStatusDelivered MessageStatus = "delivered"
	MessageStatusSeen      MessageStatus = "seen"
)

// ComputeMessageStatus derives a message's overall status from how many of
// its recipients (other room members, i.e. everyone but the sender) have
// delivered/seen it. A message shows "delivered" or "seen" only once *all*
// recipients have reached that state — a group message isn't "delivered"
// just because the first person got it.
func ComputeMessageStatus(recipients, delivered, seen int) MessageStatus {
	if recipients <= 0 {
		return MessageStatusSent
	}
	if seen >= recipients {
		return MessageStatusSeen
	}
	if delivered >= recipients {
		return MessageStatusDelivered
	}
	return MessageStatusSent
}

// MessageSnippet is a trimmed preview of another message, embedded in a
// reply (FR1.10). Body is truncated by the store so a reply to a long text
// message doesn't carry the whole thing around a second time. MediaID lets
// a reply to a photo/video show a thumbnail of it, the same as the reply
// draft bar already can from the full (still-loaded) original message.
type MessageSnippet struct {
	ID       string      `json:"id"`
	SenderID string      `json:"senderId"`
	Kind     MessageKind `json:"kind"`
	Body     *string     `json:"body,omitempty"`
	MediaID  *string     `json:"mediaId,omitempty"`
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

// minShareTTL/maxShareTTL bound FR3.2's "small set of preset durations" (the
// architecture overview's own example is 15 min / 1 hr / "until I arrive")
// — generous enough to cover a long "until I arrive" share without allowing
// an effectively-unbounded one a client could set by mistake or abuse.
const (
	minShareTTL = 1 * time.Minute
	maxShareTTL = 12 * time.Hour
)

// ValidShareTTL reports whether d is a sane duration for a location share's
// TTL (FR3.2).
func ValidShareTTL(d time.Duration) bool {
	return d >= minShareTTL && d <= maxShareTTL
}

// ValidCoordinate reports whether lat/lng are within the valid range for a
// real-world position — a cheap sanity check on client input, not a
// precision/format validator.
func ValidCoordinate(lat, lng float64) bool {
	return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180
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
	MessageID *string    `json:"messageId,omitempty"`
	StartedBy string     `json:"startedBy"`
	Status    CallStatus `json:"status"`
	StartedAt time.Time  `json:"startedAt"`
	EndedAt   *time.Time `json:"endedAt,omitempty"`
}

// CallParticipant tracks one user's attendance in a call (FR4.8's "who was
// on the call", and the basis for FinalizeCallStatus below): JoinedAt is nil
// until they actually join media, LeftAt is nil while they're still in it.
type CallParticipant struct {
	CallID   string     `json:"callId"`
	UserID   string     `json:"userId"`
	JoinedAt *time.Time `json:"joinedAt,omitempty"`
	LeftAt   *time.Time `json:"leftAt,omitempty"`
}

// FinalizeCallStatus decides a call's terminal status once its last active
// participant leaves: "completed" if anyone other than the original caller
// ever joined, "missed" otherwise — the same rule for a 1:1 call nobody
// answered and a group call where every invitee let it ring out.
func FinalizeCallStatus(otherParticipantJoined bool) CallStatus {
	if otherParticipantJoined {
		return CallStatusCompleted
	}
	return CallStatusMissed
}
