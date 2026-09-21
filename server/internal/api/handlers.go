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
	"strings"
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

// handleUploadAvatar sets the caller's own profile picture. Unlike
// handleUploadMedia (room-scoped, and always creates a chat message as a
// side effect), this is user-scoped and touches no room or message at all —
// it creates a media_objects row the same way, then points the caller's own
// avatar_media_id at it directly. Reuses the current display name from
// session (rather than accepting one in the body) so this can't overwrite
// it — UpdateUserProfile sets both columns unconditionally.
func (s *Server) handleUploadAvatar(w http.ResponseWriter, r *http.Request) {
	u, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxMediaUploadBytes)
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		writeError(w, http.StatusBadRequest, "upload too large or malformed")
		return
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
	objectKey := fmt.Sprintf("avatars/%s%s", uuid.NewString(), filepath.Ext(header.Filename))

	if err := s.Media.Put(r.Context(), objectKey, file, header.Size, contentType); err != nil {
		writeError(w, http.StatusInternalServerError, "could not store file")
		return
	}

	mediaObj, err := s.Store.CreateMediaObject(r.Context(), s.Media.Bucket(), objectKey, contentType, header.Size, u.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not record uploaded file")
		return
	}

	updated, err := s.Store.UpdateUserProfile(r.Context(), u.ID, u.DisplayName, &mediaObj.ID)
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
	if err := s.Store.AttachStatus(r.Context(), messages); err != nil {
		writeError(w, http.StatusInternalServerError, "could not load message status")
		return
	}
	if err := s.Store.AttachLocations(r.Context(), messages); err != nil {
		writeError(w, http.StatusInternalServerError, "could not load location shares")
		return
	}
	if err := s.Store.AttachCalls(r.Context(), messages); err != nil {
		writeError(w, http.StatusInternalServerError, "could not load calls")
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

// safeInlineMediaContentTypes are the content types handleGetMedia will
// ever echo back verbatim — the client-supplied Content-Type on upload
// (handleUploadMedia) is stored as-is and otherwise untrusted, so serving
// it back unfiltered would let an uploader store arbitrary bytes under an
// arbitrary Content-Type (e.g. text/html, or image/svg+xml, which browsers
// execute embedded <script> in) and have it render as active content for
// anyone who opens the media URL directly — a stored-XSS path. Deliberately
// excludes image/svg+xml for that reason. Anything not on this list is
// still served (FR2.4 never rejects/deletes an upload), just as a forced
// download instead of inline-renderable content.
var safeInlineMediaContentTypes = map[string]bool{
	"image/jpeg":       true,
	"image/png":        true,
	"image/gif":        true,
	"image/webp":       true,
	"image/heic":       true,
	"image/heif":       true,
	"video/mp4":        true,
	"video/quicktime":  true,
	"video/webm":       true,
	"video/x-matroska": true,
	"video/3gpp":       true,
}

// handleGetMedia streams a media object's bytes back, for both inline
// display and download (FR2.3). Requires the caller to be a member of the
// room the media's message belongs to — forwarded media is always a
// duplicated, independent copy with its own message (FR1.11), never shared
// by reference across rooms, so a media object always belongs to exactly
// one room and this check is unambiguous. The exception is a profile
// picture (handleUploadAvatar): it has no owning message at all, so there's
// no room to scope it to — any authenticated user may fetch one, same as
// any other user's display name is already visible to every other user on
// this private, single-tailnet instance.
func (s *Server) handleGetMedia(w http.ResponseWriter, r *http.Request) {
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

	message, err := s.Store.GetMessageByMediaID(r.Context(), mediaID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusInternalServerError, "could not look up the message for this media")
		return
	}
	if err == nil && !s.requireMembership(w, r, userID, message.RoomID) {
		return
	}

	w.Header().Set("X-Content-Type-Options", "nosniff") // belt-and-braces: never let a browser re-sniff this into something more dangerous than what's set below
	if safeInlineMediaContentTypes[obj.ContentType] {
		w.Header().Set("Content-Type", obj.ContentType)
	} else {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", "attachment")
	}
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable") // FR2.4: media never changes once uploaded
	w.Header().Set("Accept-Ranges", "bytes")

	// Video playback needs Range support to work at all, not just to seek —
	// see GetRange's own doc comment. A plain GET (no Range header) is
	// served in full, as before.
	rangeHeader := r.Header.Get("Range")
	if rangeHeader == "" {
		reader, err := s.Media.Get(r.Context(), obj.ObjectKey)
		if err != nil {
			writeError(w, http.StatusNotFound, "media not found")
			return
		}
		defer reader.Close()
		w.Header().Set("Content-Length", strconv.FormatInt(obj.SizeBytes, 10))
		_, _ = io.Copy(w, reader)
		return
	}

	start, end, ok := parseByteRange(rangeHeader, obj.SizeBytes)
	if !ok {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", obj.SizeBytes))
		writeError(w, http.StatusRequestedRangeNotSatisfiable, "invalid range")
		return
	}
	reader, err := s.Media.GetRange(r.Context(), obj.ObjectKey, start, end)
	if err != nil {
		writeError(w, http.StatusNotFound, "media not found")
		return
	}
	defer reader.Close()
	w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, obj.SizeBytes))
	w.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
	w.WriteHeader(http.StatusPartialContent)
	_, _ = io.Copy(w, reader)
}

// parseByteRange parses a single-range "Range: bytes=..." header value
// (RFC 7233 §3.1) against an object of the given total size, resolving the
// open-ended and suffix forms (bytes=500-, bytes=-500) to a concrete
// inclusive [start, end]. Multiple comma-separated ranges aren't supported —
// no video player actually sends those for a simple seek.
func parseByteRange(header string, size int64) (start, end int64, ok bool) {
	const prefix = "bytes="
	if !strings.HasPrefix(header, prefix) {
		return 0, 0, false
	}
	spec := strings.TrimPrefix(header, prefix)
	if strings.Contains(spec, ",") {
		return 0, 0, false
	}
	parts := strings.SplitN(spec, "-", 2)
	if len(parts) != 2 {
		return 0, 0, false
	}
	if parts[0] == "" {
		// Suffix range: bytes=-N, the last N bytes.
		n, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil || n <= 0 {
			return 0, 0, false
		}
		if n > size {
			n = size
		}
		return size - n, size - 1, true
	}
	start, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || start < 0 || start >= size {
		return 0, 0, false
	}
	if parts[1] == "" {
		return start, size - 1, true
	}
	end, err = strconv.ParseInt(parts[1], 10, 64)
	if err != nil || end < start {
		return 0, 0, false
	}
	if end >= size {
		end = size - 1
	}
	return start, end, true
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

// handleDeleteMessage implements FR1.15 for every kind except image/video —
// those go through handleDeleteMedia instead, since deleting the underlying
// file (not just the row) is that endpoint's job.
func (s *Server) handleDeleteMessage(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	messageID := chi.URLParam(r, "messageID")

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
		writeError(w, http.StatusForbidden, "only the sender can delete this message")
		return
	}
	if message.Kind == models.MessageKindImage || message.Kind == models.MessageKindVideo {
		writeError(w, http.StatusBadRequest, "delete this message's media instead, via DELETE /api/media/:id")
		return
	}

	if err := s.Store.DeleteMessage(r.Context(), messageID); err != nil {
		writeError(w, http.StatusInternalServerError, "could not delete message")
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
	if err := s.Store.AttachStatus(r.Context(), messages); err != nil {
		writeError(w, http.StatusInternalServerError, "could not load message status")
		return
	}
	if err := s.Store.AttachLocations(r.Context(), messages); err != nil {
		writeError(w, http.StatusInternalServerError, "could not load location shares")
		return
	}
	if err := s.Store.AttachCalls(r.Context(), messages); err != nil {
		writeError(w, http.StatusInternalServerError, "could not load calls")
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

// maxReceiptAckBatch caps how many message ids a single ack call can cover —
// generous for a client catching up after being offline, not a hard limit.
const maxReceiptAckBatch = 200

// handleAckReceipts implements FR1.5/FR1.6: the client reports that it has
// received ("delivered") or actually displayed ("seen") a batch of messages
// in roomID. Only the caller's own receipt is written; the resulting status
// (visible to the messages' senders) is recomputed and broadcast only for
// messages whose status actually changed, so an ack that doesn't move a
// message past what every other member has already reached is silent.
func (s *Server) handleAckReceipts(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, userID, roomID) {
		return
	}

	var body struct {
		MessageIDs []string `json:"messageIds"`
		Status     string   `json:"status"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if len(body.MessageIDs) == 0 || len(body.MessageIDs) > maxReceiptAckBatch {
		writeError(w, http.StatusBadRequest, "messageIds must have between 1 and 200 entries")
		return
	}
	var seen bool
	switch models.MessageStatus(body.Status) {
	case models.MessageStatusDelivered:
		seen = false
	case models.MessageStatusSeen:
		seen = true
	default:
		writeError(w, http.StatusBadRequest, `status must be "delivered" or "seen"`)
		return
	}

	// A caller only belongs to roomID, but body.MessageIDs is otherwise
	// unverified — filter to just the IDs that really belong to this room
	// before anything else touches them, so a real message ID from a room
	// this caller isn't in can't leak that room's receipt state back to
	// them (see FilterMessageIDsInRoom's doc comment).
	messageIDs, err := s.Store.FilterMessageIDsInRoom(r.Context(), roomID, body.MessageIDs)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not validate message ids")
		return
	}
	if len(messageIDs) == 0 {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if err := s.Store.MarkReceipts(r.Context(), roomID, userID, messageIDs, seen); err != nil {
		writeError(w, http.StatusInternalServerError, "could not record receipts")
		return
	}

	messages := make([]models.Message, len(messageIDs))
	for i, id := range messageIDs {
		messages[i] = models.Message{ID: id, RoomID: roomID}
	}
	if err := s.Store.AttachStatus(r.Context(), messages); err != nil {
		writeError(w, http.StatusInternalServerError, "could not recompute message status")
		return
	}

	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), roomID); err == nil {
		for _, m := range messages {
			if m.Status == models.MessageStatusSent {
				continue
			}
			s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.status", Payload: map[string]string{
				"messageId": m.ID, "roomId": roomID, "status": string(m.Status),
			}})
		}
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

// handleShareLocation implements FR3.1/FR3.2: starts a live location share
// as a new message of kind 'location'. ttlSeconds is the sender-chosen
// duration from FR3.2's small preset set; validated server-side so a client
// can't request an effectively-unbounded share.
func (s *Server) handleShareLocation(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, userID, roomID) {
		return
	}

	var body struct {
		Lat        float64 `json:"lat"`
		Lng        float64 `json:"lng"`
		TTLSeconds int     `json:"ttlSeconds"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if !models.ValidCoordinate(body.Lat, body.Lng) {
		writeError(w, http.StatusBadRequest, "invalid coordinates")
		return
	}
	ttl := time.Duration(body.TTLSeconds) * time.Second
	if !models.ValidShareTTL(ttl) {
		writeError(w, http.StatusBadRequest, "ttlSeconds is out of range")
		return
	}

	msg, err := s.Store.CreateLocationMessage(r.Context(), roomID, userID, body.Lat, body.Lng, ttl)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create location share")
		return
	}

	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), roomID); err == nil {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.created", Payload: msg})
	}
	writeJSON(w, http.StatusCreated, msg)
}

// locationShareForUpdate fetches messageID, verifies it's an active
// location share belonging to userID, and returns it — shared by
// handleUpdateLocation and handleEndLocationShare, mirroring how
// messageRoomForReaction centralizes the lookup+authorization for reactions.
func (s *Server) locationShareForUpdate(w http.ResponseWriter, r *http.Request, userID, messageID string) (models.Message, bool) {
	message, err := s.Store.GetMessage(r.Context(), messageID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "message not found")
		return models.Message{}, false
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up message")
		return models.Message{}, false
	}
	if !s.requireMembership(w, r, userID, message.RoomID) {
		return models.Message{}, false
	}
	if message.SenderID != userID {
		writeError(w, http.StatusForbidden, "only the sender can update this share")
		return models.Message{}, false
	}
	if message.Kind != models.MessageKindLocation {
		writeError(w, http.StatusBadRequest, "not a location share")
		return models.Message{}, false
	}

	share, err := s.Store.GetLocationShare(r.Context(), messageID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up location share")
		return models.Message{}, false
	}
	if !share.Active(time.Now()) {
		writeError(w, http.StatusForbidden, "this share is no longer active")
		return models.Message{}, false
	}
	return message, true
}

// handleUpdateLocation implements FR3.3: the sender's device posts its
// latest position while a share is active.
func (s *Server) handleUpdateLocation(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	messageID := chi.URLParam(r, "messageID")
	message, ok := s.locationShareForUpdate(w, r, userID, messageID)
	if !ok {
		return
	}

	var body struct {
		Lat float64 `json:"lat"`
		Lng float64 `json:"lng"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if !models.ValidCoordinate(body.Lat, body.Lng) {
		writeError(w, http.StatusBadRequest, "invalid coordinates")
		return
	}

	share, err := s.Store.UpdateLocationPosition(r.Context(), messageID, body.Lat, body.Lng)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not update location")
		return
	}
	message.Location = &share

	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), message.RoomID); err == nil {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.updated", Payload: message})
	}
	writeJSON(w, http.StatusOK, message)
}

// handleEndLocationShare implements FR3.5: the sender ends their share
// early, before its TTL elapses.
func (s *Server) handleEndLocationShare(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	messageID := chi.URLParam(r, "messageID")
	message, ok := s.locationShareForUpdate(w, r, userID, messageID)
	if !ok {
		return
	}

	share, err := s.Store.EndLocationShare(r.Context(), messageID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not end location share")
		return
	}
	message.Location = &share

	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), message.RoomID); err == nil {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.updated", Payload: message})
	}
	writeJSON(w, http.StatusOK, message)
}

// handleStartCall implements FR4.1/FR4.2: begins a call in roomID, ringing
// every other member. Reuses the existing message.created event — a call
// is just another message, so the callee's incoming-call detector
// (client-side) and the room's normal history both pick this up with no
// new WebSocket plumbing.
func (s *Server) handleStartCall(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, userID, roomID) {
		return
	}

	msg, err := s.Store.CreateCall(r.Context(), roomID, userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not start call")
		return
	}

	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), roomID); err == nil {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.created", Payload: msg})
	}
	writeJSON(w, http.StatusCreated, msg)
}

// callForAction fetches callID and verifies the caller is a member of its
// room — shared by accept/decline/leave, mirroring how
// locationShareForUpdate centralizes lookup+authorization for location shares.
func (s *Server) callForAction(w http.ResponseWriter, r *http.Request, userID, callID string) (models.Call, bool) {
	call, err := s.Store.GetCall(r.Context(), callID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "call not found")
		return models.Call{}, false
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up call")
		return models.Call{}, false
	}
	if !s.requireMembership(w, r, userID, call.RoomID) {
		return models.Call{}, false
	}
	return call, true
}

// handleAcceptCall implements FR4.5: the callee joins. No broadcast here —
// LiveKit's own room-join event is what every other participant actually
// observes in real time; the chat message's status doesn't change on
// accept (it stays "ringing" until the call ends either way — see
// LeaveCall/DeclineCall).
func (s *Server) handleAcceptCall(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	callID := chi.URLParam(r, "callID")
	call, ok := s.callForAction(w, r, userID, callID)
	if !ok {
		return
	}
	if call.Status != models.CallStatusRinging {
		writeError(w, http.StatusForbidden, "this call has already ended")
		return
	}
	if err := s.Store.JoinCall(r.Context(), callID, userID); err != nil {
		writeError(w, http.StatusInternalServerError, "could not join call")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleDeclineCall implements FR4.5. In a 1:1 room, declining ends the
// call immediately — there's nobody left to answer. In a group room it's a
// no-op at the call-record level: other invitees may still pick up.
func (s *Server) handleDeclineCall(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	callID := chi.URLParam(r, "callID")
	call, ok := s.callForAction(w, r, userID, callID)
	if !ok {
		return
	}
	if call.Status != models.CallStatusRinging {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	room, err := s.Store.GetRoom(r.Context(), call.RoomID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up room")
		return
	}
	if room.IsGroup {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	updated, err := s.Store.DeclineCall(r.Context(), callID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not decline call")
		return
	}
	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), call.RoomID); err == nil {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.updated", Payload: updated})
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleLeaveCall implements FR4.5's end/hang-up. Works the same way for
// the original caller giving up on an unanswered call and for any
// participant hanging up mid-call.
func (s *Server) handleLeaveCall(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	callID := chi.URLParam(r, "callID")
	call, ok := s.callForAction(w, r, userID, callID)
	if !ok {
		return
	}

	updated, finalized, err := s.Store.LeaveCall(r.Context(), callID, userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not leave call")
		return
	}
	if finalized {
		if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), call.RoomID); err == nil {
			s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.updated", Payload: updated})
		}
	}
	w.WriteHeader(http.StatusNoContent)
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
