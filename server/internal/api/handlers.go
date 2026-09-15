package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"roost/server/internal/linkpreview"
	"roost/server/internal/models"
	"roost/server/internal/session"
	"roost/server/internal/store"
	"roost/server/internal/ws"
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func currentUser(w http.ResponseWriter, r *http.Request) (userID string, ok bool) {
	u, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return "", false
	}
	return u.ID, true
}

func (s *Server) handleGetMe(w http.ResponseWriter, r *http.Request) {
	u, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	writeJSON(w, http.StatusOK, u)
}

func (s *Server) handleUpdateMe(w http.ResponseWriter, r *http.Request) {
	u, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	var body struct {
		DisplayName   string  `json:"displayName"`
		AvatarMediaID *string `json:"avatarMediaId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	updated, err := s.Store.UpdateUserProfile(r.Context(), u.ID, body.DisplayName, body.AvatarMediaID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not update profile")
		return
	}
	writeJSON(w, http.StatusOK, updated)
}

type contactDTO struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	Online      bool   `json:"online"`
}

// handleListUsers backs the Contacts/New group screens (FR6.3): everyone
// who has ever connected, minus the caller, with a live online flag sourced
// from the WebSocket hub (FR6.5).
func (s *Server) handleListUsers(w http.ResponseWriter, r *http.Request) {
	me, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	users, err := s.Store.ListUsers(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not list users")
		return
	}
	contacts := make([]contactDTO, 0, len(users))
	for _, u := range users {
		if u.ID == me.ID {
			continue
		}
		contacts = append(contacts, contactDTO{ID: u.ID, DisplayName: u.DisplayName, Online: s.Hub.IsOnline(u.ID)})
	}
	writeJSON(w, http.StatusOK, contacts)
}

func (s *Server) handleListRooms(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	rooms, err := s.Store.ListRoomsForUser(r.Context(), userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not list rooms")
		return
	}
	writeJSON(w, http.StatusOK, rooms)
}

func (s *Server) handleCreateRoom(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	var body struct {
		Name      *string  `json:"name"`
		IsGroup   bool     `json:"isGroup"`
		MemberIDs []string `json:"memberIds"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}

	if !body.IsGroup && len(body.MemberIDs) == 1 {
		if existing, err := s.Store.FindDirectRoom(r.Context(), userID, body.MemberIDs[0]); err == nil {
			writeJSON(w, http.StatusOK, existing)
			return
		} else if !errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusInternalServerError, "could not check for an existing conversation")
			return
		}
	}

	room, err := s.Store.CreateRoom(r.Context(), userID, body.Name, body.IsGroup, body.MemberIDs)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create room")
		return
	}
	writeJSON(w, http.StatusCreated, room)
}

func (s *Server) handleGetRoom(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, userID, roomID) {
		return
	}
	room, err := s.Store.GetRoom(r.Context(), roomID)
	if err != nil {
		writeError(w, http.StatusNotFound, "room not found")
		return
	}
	writeJSON(w, http.StatusOK, room)
}

func (s *Server) requireMembership(w http.ResponseWriter, r *http.Request, userID, roomID string) bool {
	isMember, err := s.Store.IsRoomMember(r.Context(), roomID, userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not verify room membership")
		return false
	}
	if !isMember {
		writeError(w, http.StatusForbidden, "not a member of this room")
		return false
	}
	return true
}

func (s *Server) handleListMessages(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, userID, roomID) {
		return
	}

	before := time.Time{}
	if v := r.URL.Query().Get("before"); v != "" {
		parsed, err := time.Parse(time.RFC3339, v)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid before timestamp")
			return
		}
		before = parsed
	}
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 200 {
			limit = n
		}
	}

	messages, err := s.Store.ListMessages(r.Context(), roomID, before, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not list messages")
		return
	}
	if err := s.Store.AttachReactions(r.Context(), userID, messages); err != nil {
		writeError(w, http.StatusInternalServerError, "could not load reactions")
		return
	}
	if err := s.Store.AttachReplyPreviews(r.Context(), messages); err != nil {
		writeError(w, http.StatusInternalServerError, "could not load reply previews")
		return
	}
	writeJSON(w, http.StatusOK, messages)
}

func (s *Server) handleCreateMessage(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, userID, roomID) {
		return
	}

	var body struct {
		Body             string  `json:"body"`
		ReplyToMessageID *string `json:"replyToMessageId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Body == "" {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if body.ReplyToMessageID != nil && !s.validReplyTarget(w, r, roomID, *body.ReplyToMessageID) {
		return
	}

	msg, err := s.Store.CreateTextMessage(r.Context(), roomID, userID, body.Body, body.ReplyToMessageID, false)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create message")
		return
	}
	if body.ReplyToMessageID != nil {
		// Best-effort: on failure the response just omits the reply preview
		// the client would otherwise render inline.
		messages := []models.Message{msg}
		if err := s.Store.AttachReplyPreviews(r.Context(), messages); err == nil {
			msg = messages[0]
		}
	}

	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), roomID); err == nil {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.created", Payload: msg})
	}

	writeJSON(w, http.StatusCreated, msg)
}

// validReplyTarget checks that replyToMessageID exists and belongs to
// roomID — replying across rooms would let a client reference another
// room's message it may not even be a member of.
func (s *Server) validReplyTarget(w http.ResponseWriter, r *http.Request, roomID, replyToMessageID string) bool {
	original, err := s.Store.GetMessage(r.Context(), replyToMessageID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusBadRequest, "reply target not found")
		return false
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up reply target")
		return false
	}
	if original.RoomID != roomID {
		writeError(w, http.StatusBadRequest, "reply target is not in this room")
		return false
	}
	return true
}

// maxMediaUploadBytes caps a single image/video upload — generous for phone
// photos/video clips on a home network, not a hard product requirement.
const maxMediaUploadBytes = 200 << 20 // 200 MiB

// handleUploadMedia implements FR2.1/2.2: the client posts the file plus a
// "kind" field (image|video) as multipart form data, and gets back the chat
// message that was created for it — one request creates both the MinIO
// object and the message referencing it, so there's never a message
// pointing at bytes that don't exist (upload happens before either DB row).
func (s *Server) handleUploadMedia(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, userID, roomID) {
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxMediaUploadBytes)
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		writeError(w, http.StatusBadRequest, "upload too large or malformed")
		return
	}

	kind := r.FormValue("kind")
	if kind != string(models.MessageKindImage) && kind != string(models.MessageKindVideo) {
		writeError(w, http.StatusBadRequest, `kind must be "image" or "video"`)
		return
	}
	var replyToMessageID *string
	if v := r.FormValue("replyToMessageId"); v != "" {
		if !s.validReplyTarget(w, r, roomID, v) {
			return
		}
		replyToMessageID = &v
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "missing file")
		return
	}
	defer file.Close()

	contentType := header.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	objectKey := fmt.Sprintf("%s/%s%s", roomID, uuid.NewString(), filepath.Ext(header.Filename))

	if err := s.Media.Put(r.Context(), objectKey, file, header.Size, contentType); err != nil {
		writeError(w, http.StatusInternalServerError, "could not store file")
		return
	}

	mediaObj, err := s.Store.CreateMediaObject(r.Context(), s.Media.Bucket(), objectKey, contentType, header.Size, userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not record uploaded file")
		return
	}

	msg, err := s.Store.CreateMediaMessage(r.Context(), roomID, userID, kind, mediaObj.ID, replyToMessageID, false)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create message")
		return
	}
	if replyToMessageID != nil {
		messages := []models.Message{msg}
		if err := s.Store.AttachReplyPreviews(r.Context(), messages); err == nil {
			msg = messages[0]
		}
	}

	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), roomID); err == nil {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.created", Payload: msg})
	}

	writeJSON(w, http.StatusCreated, msg)
}

// handleGetMedia streams a media object's bytes back, for both inline
// display and download (FR2.3). Any authenticated (tailnet) user can fetch
// any media object by ID: per "trust follows the network", there's no
// separate per-object ACL to check, consistent with family-scale simplicity
// over building out a full authorization graph for a rarely-guessed UUID.
func (s *Server) handleGetMedia(w http.ResponseWriter, r *http.Request) {
	mediaID := chi.URLParam(r, "mediaID")
	obj, err := s.Store.GetMediaObject(r.Context(), mediaID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "media not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up media")
		return
	}

	reader, err := s.Media.Get(r.Context(), obj.ObjectKey)
	if err != nil {
		writeError(w, http.StatusNotFound, "media not found")
		return
	}
	defer reader.Close()

	w.Header().Set("Content-Type", obj.ContentType)
	w.Header().Set("Content-Length", strconv.FormatInt(obj.SizeBytes, 10))
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable") // FR2.4: media never changes once uploaded
	_, _ = io.Copy(w, reader)
}

// handleDeleteMedia implements FR2.5. Only the uploader may delete their own
// media. Deleting the media object cascades to delete the message it
// belongs to (migration 0002) — the message *was* the shared photo/video —
// so this also broadcasts message.deleted to the room.
func (s *Server) handleDeleteMedia(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	mediaID := chi.URLParam(r, "mediaID")
	obj, err := s.Store.GetMediaObject(r.Context(), mediaID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "media not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up media")
		return
	}
	if obj.UploadedBy != userID {
		writeError(w, http.StatusForbidden, "only the uploader can delete this media")
		return
	}

	message, err := s.Store.GetMessageByMediaID(r.Context(), mediaID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up the message for this media")
		return
	}

	if err := s.Media.Delete(r.Context(), obj.ObjectKey); err != nil {
		writeError(w, http.StatusInternalServerError, "could not delete file")
		return
	}
	if err := s.Store.DeleteMediaObject(r.Context(), mediaID); err != nil {
		writeError(w, http.StatusInternalServerError, "could not delete media record")
		return
	}

	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), message.RoomID); err == nil {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.deleted", Payload: map[string]string{
			"messageId": message.ID, "roomId": message.RoomID,
		}})
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleSearchMessages(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, userID, roomID) {
		return
	}
	query := r.URL.Query().Get("q")
	if query == "" {
		writeError(w, http.StatusBadRequest, "missing query parameter q")
		return
	}
	messages, err := s.Store.SearchMessages(r.Context(), roomID, query)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not search messages")
		return
	}
	if err := s.Store.AttachReactions(r.Context(), userID, messages); err != nil {
		writeError(w, http.StatusInternalServerError, "could not load reactions")
		return
	}
	if err := s.Store.AttachReplyPreviews(r.Context(), messages); err != nil {
		writeError(w, http.StatusInternalServerError, "could not load reply previews")
		return
	}
	writeJSON(w, http.StatusOK, messages)
}

// messageRoomForReaction fetches the message and verifies the caller is a
// member of its room, returning the room ID on success. Shared by add/remove
// since both need the same authorization check before touching a reaction.
func (s *Server) messageRoomForReaction(w http.ResponseWriter, r *http.Request, userID, messageID string) (roomID string, ok bool) {
	message, err := s.Store.GetMessage(r.Context(), messageID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "message not found")
		return "", false
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up message")
		return "", false
	}
	if !s.requireMembership(w, r, userID, message.RoomID) {
		return "", false
	}
	return message.RoomID, true
}

func (s *Server) handleAddReaction(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	messageID := chi.URLParam(r, "messageID")
	emoji := chi.URLParam(r, "emoji")
	roomID, ok := s.messageRoomForReaction(w, r, userID, messageID)
	if !ok {
		return
	}
	if err := s.Store.AddReaction(r.Context(), messageID, userID, emoji); err != nil {
		writeError(w, http.StatusInternalServerError, "could not add reaction")
		return
	}
	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), roomID); err == nil {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "reaction.added", Payload: map[string]string{
			"messageId": messageID, "userId": userID, "emoji": emoji,
		}})
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleRemoveReaction(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	messageID := chi.URLParam(r, "messageID")
	emoji := chi.URLParam(r, "emoji")
	roomID, ok := s.messageRoomForReaction(w, r, userID, messageID)
	if !ok {
		return
	}
	if err := s.Store.RemoveReaction(r.Context(), messageID, userID, emoji); err != nil {
		writeError(w, http.StatusInternalServerError, "could not remove reaction")
		return
	}
	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), roomID); err == nil {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "reaction.removed", Payload: map[string]string{
			"messageId": messageID, "userId": userID, "emoji": emoji,
		}})
	}
	w.WriteHeader(http.StatusNoContent)
}

// editWindow bounds FR1.13: a text message can be edited only within this
// long of being sent, matching the user-facing "not older than 1 minute" rule.
const editWindow = 1 * time.Minute

// handleEditMessage implements FR1.13. Only the sender may edit, only a
// text message can be edited (media messages have no body), and only within
// editWindow of the original send — enforced here rather than in SQL so a
// too-old edit gets a distinct, specific error instead of a generic 404/403.
func (s *Server) handleEditMessage(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	messageID := chi.URLParam(r, "messageID")

	var body struct {
		Body string `json:"body"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Body == "" {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}

	message, err := s.Store.GetMessage(r.Context(), messageID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "message not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up message")
		return
	}
	if !s.requireMembership(w, r, userID, message.RoomID) {
		return
	}
	if message.SenderID != userID {
		writeError(w, http.StatusForbidden, "only the sender can edit this message")
		return
	}
	if message.Kind != models.MessageKindText {
		writeError(w, http.StatusBadRequest, "only text messages can be edited")
		return
	}
	if time.Since(message.CreatedAt) > editWindow {
		writeError(w, http.StatusForbidden, "message is too old to edit")
		return
	}

	updated, err := s.Store.EditMessageBody(r.Context(), messageID, body.Body)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not edit message")
		return
	}

	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), message.RoomID); err == nil {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.updated", Payload: updated})
	}
	writeJSON(w, http.StatusOK, updated)
}

// handleForwardMessage implements FR1.11: re-post a message into another
// room the caller belongs to. Per the product decision to duplicate rather
// than share media, a forwarded image/video gets its own MinIO object (a
// server-side copy) and its own media_objects row, so deleting either copy
// never affects the other.
func (s *Server) handleForwardMessage(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	messageID := chi.URLParam(r, "messageID")

	var body struct {
		RoomID string `json:"roomId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.RoomID == "" {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if !s.requireMembership(w, r, userID, body.RoomID) {
		return
	}

	original, err := s.Store.GetMessage(r.Context(), messageID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "message not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up message")
		return
	}
	// The caller must also belong to the *source* room — otherwise this
	// would let anyone forward a message from a room they can't even read.
	if !s.requireMembership(w, r, userID, original.RoomID) {
		return
	}

	var forwarded models.Message
	switch original.Kind {
	case models.MessageKindText:
		forwarded, err = s.Store.CreateTextMessage(r.Context(), body.RoomID, userID, *original.Body, nil, true)
	case models.MessageKindImage, models.MessageKindVideo:
		var mediaID string
		mediaID, err = s.duplicateMedia(r.Context(), *original.MediaID, body.RoomID, userID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "could not duplicate media")
			return
		}
		forwarded, err = s.Store.CreateMediaMessage(r.Context(), body.RoomID, userID, string(original.Kind), mediaID, nil, true)
	default:
		writeError(w, http.StatusBadRequest, "this message type can't be forwarded")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not forward message")
		return
	}

	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), body.RoomID); err == nil {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.created", Payload: forwarded})
	}
	writeJSON(w, http.StatusCreated, forwarded)
}

// duplicateMedia copies an existing media object's bytes to a new key in
// MinIO and records a new, independent media_objects row for it, returning
// the new object's ID.
func (s *Server) duplicateMedia(ctx context.Context, sourceMediaID, dstRoomID, uploadedBy string) (string, error) {
	src, err := s.Store.GetMediaObject(ctx, sourceMediaID)
	if err != nil {
		return "", fmt.Errorf("look up source media: %w", err)
	}
	dstKey := fmt.Sprintf("%s/%s%s", dstRoomID, uuid.NewString(), filepath.Ext(src.ObjectKey))
	if err := s.Media.Copy(ctx, src.ObjectKey, dstKey); err != nil {
		return "", fmt.Errorf("copy object: %w", err)
	}
	dst, err := s.Store.CreateMediaObject(ctx, s.Media.Bucket(), dstKey, src.ContentType, src.SizeBytes, uploadedBy)
	if err != nil {
		return "", fmt.Errorf("record duplicated media: %w", err)
	}
	return dst.ID, nil
}

// handleLinkPreview implements FR1.14: given a URL a client found in a text
// message, fetch its Open Graph metadata server-side (see internal/linkpreview
// for why this happens on the server, not the client). Any authenticated
// user may call this — there's nothing room-scoped about a URL's metadata.
func (s *Server) handleLinkPreview(w http.ResponseWriter, r *http.Request) {
	if _, ok := currentUser(w, r); !ok {
		return
	}
	target := r.URL.Query().Get("url")
	if target == "" {
		writeError(w, http.StatusBadRequest, "missing query parameter url")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	preview, err := linkpreview.Fetch(ctx, target)
	if err != nil {
		writeError(w, http.StatusNotFound, "no preview available")
		return
	}
	writeJSON(w, http.StatusOK, preview)
}

func (s *Server) handleMintLiveKitToken(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	var body struct {
		RoomID string `json:"roomId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.RoomID == "" {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if !s.requireMembership(w, r, userID, body.RoomID) {
		return
	}
	token, err := s.LiveKit.Token(userID, body.RoomID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not mint token")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"token": token})
}
