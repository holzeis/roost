package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/disintegration/imaging"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"roost/server/internal/cryptobox"
	"roost/server/internal/linkpreview"
	"roost/server/internal/models"
	"roost/server/internal/push"
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
	mediaObj, ok := s.storeAvatarUpload(w, r, u.ID)
	if !ok {
		return
	}
	updated, err := s.Store.UpdateUserProfile(r.Context(), u.ID, u.DisplayName, &mediaObj.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not update profile")
		return
	}
	writeJSON(w, http.StatusOK, updated)
}

// storeAvatarUpload reads a multipart "file" image from the request, stores
// it (with the smaller preview) and records it as a media object uploaded by
// uploaderID — the part a user's profile picture and a group's picture have
// in common. On failure it has already written the error response.
func (s *Server) storeAvatarUpload(w http.ResponseWriter, r *http.Request, uploaderID string) (models.MediaObject, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, maxMediaUploadBytes)
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		writeError(w, http.StatusBadRequest, "upload too large or malformed")
		return models.MediaObject{}, false
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "missing file")
		return models.MediaObject{}, false
	}
	defer file.Close()

	// Buffered fully in memory rather than streamed straight to the object store —
	// generating the preview below needs the whole thing to decode anyway.
	// See handleUploadMedia's identical comment.
	data, err := io.ReadAll(file)
	if err != nil {
		writeError(w, http.StatusBadRequest, "could not read upload")
		return models.MediaObject{}, false
	}

	contentType := header.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	objectKey := fmt.Sprintf("avatars/%s%s", uuid.NewString(), filepath.Ext(header.Filename))

	// An avatar is shown small everywhere (InitialAvatar/profile_screen.dart
	// both render it into a fixed-size circle via BoxFit.cover, never at its
	// real dimensions), so the same faster-loading preview handleUploadMedia
	// generates for chat photos applies just as well here.
	width, height, previewObjectKey, err := s.storeMediaWithPreview(r.Context(), objectKey, contentType, data)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not store file")
		return models.MediaObject{}, false
	}

	mediaObj, err := s.Store.CreateMediaObject(
		r.Context(), s.Media.Bucket(), objectKey, contentType, int64(len(data)), uploaderID, width, height, previewObjectKey)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not record uploaded file")
		return models.MediaObject{}, false
	}
	return mediaObj, true
}

// handleSetRoomAvatar lets any member of a group set its picture; everyone
// in the group is told live (room.updated). A 1:1 room has no picture of its
// own — it shows the other person's.
func (s *Server) handleSetRoomAvatar(w http.ResponseWriter, r *http.Request) {
	u, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, u.ID, roomID) {
		return
	}
	room, err := s.Store.GetRoom(r.Context(), roomID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load room")
		return
	}
	if !room.IsGroup {
		writeError(w, http.StatusBadRequest, "only a group has a picture")
		return
	}

	mediaObj, ok := s.storeAvatarUpload(w, r, u.ID)
	if !ok {
		return
	}
	updated, err := s.Store.SetRoomAvatar(r.Context(), roomID, mediaObj.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not update room")
		return
	}
	s.Hub.SendToUsers(updated.Members, ws.Event{Type: "room.updated", Payload: updated})
	writeJSON(w, http.StatusOK, updated)
}

// handleRegisterDevice implements the client half of FR5.1 — a client
// re-registers its push token on every app start (see
// lib/services/push_service.dart), which UpsertDevice treats as an
// idempotent refresh rather than an error.
func (s *Server) handleRegisterDevice(w http.ResponseWriter, r *http.Request) {
	u, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	var body struct {
		Platform  string `json:"platform"`
		PushToken string `json:"pushToken"`
		// TokenType: "fcm" (FR5.2 message notifications) or "voip" (FR5.1
		// call wake) — see models.Device's doc comment. Defaults to "fcm"
		// so an older client that doesn't send it yet still registers
		// something sane.
		TokenType string `json:"tokenType"`
		// PushPublicKey: the device's X25519 public key (base64, 32 bytes)
		// that message-notification previews are encrypted to (FR5.2).
		// Optional: without it the device gets the generic text.
		PushPublicKey *string `json:"pushPublicKey"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if body.PushPublicKey != nil {
		if _, err := cryptobox.ParsePublicKey(*body.PushPublicKey); err != nil {
			writeError(w, http.StatusBadRequest, "pushPublicKey must be a base64 32-byte X25519 public key")
			return
		}
	}
	if body.Platform != "ios" && body.Platform != "android" {
		writeError(w, http.StatusBadRequest, "platform must be ios or android")
		return
	}
	if body.PushToken == "" {
		writeError(w, http.StatusBadRequest, "pushToken is required")
		return
	}
	if body.TokenType == "" {
		body.TokenType = "fcm"
	}
	if body.TokenType != "fcm" && body.TokenType != "voip" {
		writeError(w, http.StatusBadRequest, "tokenType must be fcm or voip")
		return
	}

	device, err := s.Store.UpsertDevice(r.Context(), u.ID, body.Platform, body.PushToken, body.TokenType, body.PushPublicKey)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not register device")
		return
	}
	writeJSON(w, http.StatusOK, device)
}

type contactDTO struct {
	ID            string  `json:"id"`
	DisplayName   string  `json:"displayName"`
	Online        bool    `json:"online"`
	AvatarMediaID *string `json:"avatarMediaId,omitempty"`
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
		contacts = append(contacts, contactDTO{
			ID:            u.ID,
			DisplayName:   u.DisplayName,
			Online:        s.Hub.IsOnline(u.ID),
			AvatarMediaID: u.AvatarMediaID,
		})
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
	if err := s.Store.RoomMuteFor(r.Context(), &room, userID); err != nil {
		writeError(w, http.StatusInternalServerError, "could not load room")
		return
	}
	writeJSON(w, http.StatusOK, room)
}

// groupForMember loads the room named in the URL for a request that only a
// member of a group may make: 403 for a non-member, 400 for a 1:1 room.
func (s *Server) groupForMember(w http.ResponseWriter, r *http.Request) (models.User, models.Room, bool) {
	u, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return models.User{}, models.Room{}, false
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, u.ID, roomID) {
		return models.User{}, models.Room{}, false
	}
	room, err := s.Store.GetRoom(r.Context(), roomID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load room")
		return models.User{}, models.Room{}, false
	}
	if !room.IsGroup {
		writeError(w, http.StatusBadRequest, "only a group can do this")
		return models.User{}, models.Room{}, false
	}
	return u, room, true
}

// maxRoomNameRunes caps a group's name.
const maxRoomNameRunes = 100

// handleRenameRoom lets any member change a group's name; everyone in it is
// told live (room.updated).
func (s *Server) handleRenameRoom(w http.ResponseWriter, r *http.Request) {
	_, room, ok := s.groupForMember(w, r)
	if !ok {
		return
	}
	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	name := strings.TrimSpace(body.Name)
	if name == "" || utf8.RuneCountInString(name) > maxRoomNameRunes {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("a group name is 1 to %d characters", maxRoomNameRunes))
		return
	}
	updated, err := s.Store.RenameRoom(r.Context(), room.ID, name)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not rename room")
		return
	}
	s.Hub.SendToUsers(updated.Members, ws.Event{Type: "room.updated", Payload: updated})
	writeJSON(w, http.StatusOK, updated)
}

// joinNames reads "Bob", "Bob and Carol", "Bob, Carol and Dan".
func joinNames(names []string) string {
	switch len(names) {
	case 0:
		return ""
	case 1:
		return names[0]
	}
	return strings.Join(names[:len(names)-1], ", ") + " and " + names[len(names)-1]
}

// postSystemMessage records a note about a room (someone was added, left) and
// tells memberIDs live. Best effort, like other broadcasts: the change it
// describes has already happened. It never sends a push — the note is not
// news worth waking anyone for.
func (s *Server) postSystemMessage(ctx context.Context, roomID, actorID, body string, memberIDs []string) {
	msg, err := s.Store.CreateSystemMessage(ctx, roomID, actorID, body)
	if err != nil {
		slog.Error("system message failed", "room", roomID, "error", err)
		return
	}
	s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.created", Payload: msg})
}

// handleAddRoomMembers lets any member add people to a group. Everyone in
// it, the newcomers included, is told live (room.updated). People who are
// already in the group are left as they are.
func (s *Server) handleAddRoomMembers(w http.ResponseWriter, r *http.Request) {
	u, room, ok := s.groupForMember(w, r)
	if !ok {
		return
	}
	var body struct {
		UserIDs []string `json:"userIds"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || len(body.UserIDs) == 0 {
		writeError(w, http.StatusBadRequest, "userIds is required")
		return
	}
	seen := map[string]bool{}
	ids := make([]string, 0, len(body.UserIDs))
	for _, id := range body.UserIDs {
		if _, err := uuid.Parse(id); err != nil {
			writeError(w, http.StatusBadRequest, "invalid user id")
			return
		}
		if !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	updated, err := s.Store.AddRoomMembers(r.Context(), room.ID, ids)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "no such user")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not add members")
		return
	}
	s.Hub.SendToUsers(updated.Members, ws.Event{Type: "room.updated", Payload: updated})

	already := map[string]bool{}
	for _, id := range room.Members {
		already[id] = true
	}
	var names []string
	for _, id := range ids {
		if already[id] {
			continue
		}
		if added, err := s.Store.GetUser(r.Context(), id); err == nil {
			names = append(names, added.DisplayName)
		}
	}
	if len(names) > 0 {
		s.postSystemMessage(r.Context(), room.ID, u.ID, u.DisplayName+" added "+joinNames(names), updated.Members)
	}
	writeJSON(w, http.StatusOK, updated)
}

// handleLeaveRoom lets a member leave a group. The rest are told live
// (room.updated), the leaver's other devices likewise (room.removed). Their
// live location shares in the group end, and a group nobody is left in is
// deleted.
func (s *Server) handleLeaveRoom(w http.ResponseWriter, r *http.Request) {
	u, room, ok := s.groupForMember(w, r)
	if !ok {
		return
	}
	ended, err := s.Store.EndActiveLocationSharesInRoom(r.Context(), room.ID, u.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not leave room")
		return
	}
	for _, m := range ended {
		s.Hub.SendToUsers(room.Members, ws.Event{Type: "message.updated", Payload: m})
	}

	left, err := s.Store.RemoveRoomMember(r.Context(), room.ID, u.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not leave room")
		return
	}
	s.Hub.SendToUser(u.ID, ws.Event{Type: "room.removed", Payload: map[string]string{"id": room.ID}})
	if left > 0 {
		if updated, err := s.Store.GetRoom(r.Context(), room.ID); err == nil {
			s.Hub.SendToUsers(updated.Members, ws.Event{Type: "room.updated", Payload: updated})
			s.postSystemMessage(r.Context(), room.ID, u.ID, u.DisplayName+" left", updated.Members)
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleDeleteRoom lets the creator of a group delete it: the group, its
// messages and its media are gone for every member, who are told live
// (room.removed). Everyone else can only leave.
func (s *Server) handleDeleteRoom(w http.ResponseWriter, r *http.Request) {
	u, room, ok := s.groupForMember(w, r)
	if !ok {
		return
	}
	if room.CreatedBy != u.ID {
		writeError(w, http.StatusForbidden, "only the person who created the group can delete it")
		return
	}
	objects, err := s.Store.DeleteRoom(r.Context(), room.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not delete group")
		return
	}
	// Best effort, like deleting a single photo's preview: the database no
	// longer points at these files, so a leftover costs storage, not correctness.
	for _, obj := range objects {
		if err := s.Media.Delete(r.Context(), obj.ObjectKey); err != nil {
			slog.Warn("delete room: could not delete object", "error", err)
		}
		if obj.PreviewObjectKey != nil {
			if err := s.Media.Delete(r.Context(), *obj.PreviewObjectKey); err != nil {
				slog.Warn("delete room: could not delete preview object", "error", err)
			}
		}
	}
	s.Hub.SendToUsers(room.Members, ws.Event{Type: "room.removed", Payload: map[string]string{"id": room.ID}})
	w.WriteHeader(http.StatusNoContent)
}

// roomMuteDurations are the ways a member can mute a room (FR5.3); "always"
// has no end.
var roomMuteDurations = map[string]time.Duration{
	"8h":     8 * time.Hour,
	"1w":     7 * 24 * time.Hour,
	"always": 0,
}

// handlePutRoomMute mutes a room's notifications for the caller only (FR5.3).
// Messages still arrive in the chat — only the push about them is held back.
func (s *Server) handlePutRoomMute(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, userID, roomID) {
		return
	}
	var body struct {
		Duration string `json:"duration"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	d, known := roomMuteDurations[body.Duration]
	if !known {
		writeError(w, http.StatusBadRequest, `duration must be "8h", "1w" or "always"`)
		return
	}
	var until *time.Time
	if d > 0 {
		t := time.Now().Add(d)
		until = &t
	}
	if err := s.Store.SetRoomMute(r.Context(), roomID, userID, d == 0, until); err != nil {
		writeError(w, http.StatusInternalServerError, "could not mute room")
		return
	}
	s.respondRoomForMember(w, r, roomID, userID)
}

// handleDeleteRoomMute turns the caller's mute off.
func (s *Server) handleDeleteRoomMute(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, userID, roomID) {
		return
	}
	if err := s.Store.SetRoomMute(r.Context(), roomID, userID, false, nil); err != nil {
		writeError(w, http.StatusInternalServerError, "could not unmute room")
		return
	}
	s.respondRoomForMember(w, r, roomID, userID)
}

func (s *Server) respondRoomForMember(w http.ResponseWriter, r *http.Request, roomID, userID string) {
	room, err := s.Store.GetRoom(r.Context(), roomID)
	if err == nil {
		err = s.Store.RoomMuteFor(r.Context(), &room, userID)
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load room")
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
	if err := s.Store.AttachMedia(r.Context(), messages); err != nil {
		writeError(w, http.StatusInternalServerError, "could not load media dimensions")
		return
	}
	writeJSON(w, http.StatusOK, messages)
}

func (s *Server) handleCreateMessage(w http.ResponseWriter, r *http.Request) {
	sender, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, sender.ID, roomID) {
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

	msg, err := s.Store.CreateTextMessage(r.Context(), roomID, sender.ID, body.Body, body.ReplyToMessageID, false)
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

	s.deliverMessageEvent(r.Context(), roomID, sender, msg)

	writeJSON(w, http.StatusCreated, msg)
}

// maxAlertBytes caps one alert message; the bridge sends a single alert's
// text, so this is generous.
const maxAlertBytes = 16 << 10

// handleBotMessage lets the alert identity (auth.Identity.Bot) post a text
// message into every group it is a member of — someone adds the "Prometheus"
// contact to a group to choose where alerts go. It takes no room ID, so the
// bot can only ever write where it was invited. With no group yet it answers
// 409, which the bridge turns into a failed delivery so Alertmanager retries
// and the problem is visible.
func (s *Server) handleBotMessage(w http.ResponseWriter, r *http.Request) {
	bot, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	var body struct {
		Body string `json:"body"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxAlertBytes)
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || strings.TrimSpace(body.Body) == "" {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}

	roomIDs, err := s.Store.ListGroupIDsForMember(r.Context(), bot.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not list groups")
		return
	}
	if len(roomIDs) == 0 {
		writeError(w, http.StatusConflict, "not in any group: add Prometheus to a group to receive alerts")
		return
	}
	for _, roomID := range roomIDs {
		msg, err := s.Store.CreateTextMessage(r.Context(), roomID, bot.ID, body.Body, nil, false)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "could not create message")
			return
		}
		s.deliverMessageEvent(r.Context(), roomID, bot, msg)
	}

	writeJSON(w, http.StatusCreated, map[string]int{"groups": len(roomIDs)})
}

// handleBotAvatar lets the alert identity set its own profile picture. The
// bridge offers its image on every start, so an upload identical to the
// current picture (same type and size) is a no-op rather than a new media
// object each restart; a different image replaces it.
func (s *Server) handleBotAvatar(w http.ResponseWriter, r *http.Request) {
	bot, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	if bot.AvatarMediaID != nil {
		r.Body = http.MaxBytesReader(w, r.Body, maxMediaUploadBytes)
		if err := r.ParseMultipartForm(32 << 20); err != nil {
			writeError(w, http.StatusBadRequest, "upload too large or malformed")
			return
		}
		_, header, err := r.FormFile("file")
		if err != nil {
			writeError(w, http.StatusBadRequest, "missing file")
			return
		}
		// A lookup failure just falls through to replacing the picture.
		if current, err := s.Store.GetMediaObject(r.Context(), *bot.AvatarMediaID); err == nil && sameAvatar(current, header) {
			w.WriteHeader(http.StatusNoContent)
			return
		}
	}
	s.handleUploadAvatar(w, r)
}

// sameAvatar reports whether an upload is the picture already stored: same
// content type and byte size, which is how the bridge's fixed image is told
// apart from a new one without hashing or storing anything extra.
func sameAvatar(current models.MediaObject, upload *multipart.FileHeader) bool {
	return current.ContentType == upload.Header.Get("Content-Type") && current.SizeBytes == upload.Size
}

// validReplyTarget checks that replyToMessageID exists and belongs to
// roomID — replying across rooms would let a client reference another
// room's message it may not even be a member of.
func (s *Server) validReplyTarget(w http.ResponseWriter, r *http.Request, roomID, replyToMessageID string) bool {
	original, err := s.liveMessage(r.Context(), replyToMessageID)
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
	if original.Kind == models.MessageKindSystem {
		writeError(w, http.StatusBadRequest, "this message can't be replied to")
		return false
	}
	return true
}

// maxMediaUploadBytes caps a single image/video upload — generous for phone
// photos/video clips on a home network, not a hard product requirement.
const maxMediaUploadBytes = 200 << 20 // 200 MiB

// previewJPEGQuality is deliberately aggressive: this is only ever the
// inline chat-bubble preview (and avatars), displayed small, with the
// untouched original a tap away in the full-screen viewer — so a noticeably
// smaller/faster download matters far more here than looking pixel-perfect
// at bubble size.
const previewJPEGQuality = 55

// previewMaxSide caps the preview's long side. A chat bubble shows a photo
// at most ~300 points wide, about 900 pixels on a 3x phone screen, so this
// stays sharp there while a 12 MP camera photo's preview drops from the
// full 4032x3024 (slow to encode here and to download and decode on every
// phone) to 1024x768.
const previewMaxSide = 1024

// generateImagePreview decodes an uploaded image and re-encodes it as a
// smaller, lower-quality JPEG, scaled down to at most previewMaxSide on its
// long side (FR2.*). width and height are the original's (upright) pixel
// size, which clients use for its aspect ratio. Returns ok=false for anything it
// can't decode: an unsupported format (WebP, HEIC/HEIF — Go's standard
// library only reads JPEG/PNG/GIF), or a corrupt upload. The caller treats
// that as "no preview" and falls back to serving the original for both
// purposes — this never fails the upload itself.
//
// Decoded via imaging.Decode with AutoOrientation, not the bare stdlib
// image.Decode: a phone photo's pixel data is very often stored in the
// camera sensor's own orientation, correct only once a viewer applies the
// image's EXIF Orientation tag — which the original upload still carries
// (untouched bytes, so the full-screen viewer displays it correctly), but
// which jpeg.Encode below has no way to write back out, since re-encoding
// produces a brand new JPEG with no EXIF at all. Baking the correction into
// the pixels themselves here — before that tag is lost — is what makes the
// preview (what an avatar and every inline chat photo actually render)
// come out right-side up instead of however the sensor happened to be
// held. bounds below reflects the corrected (possibly width/height-swapped
// for a 90°/270° correction) orientation, exactly matching what the
// preview image itself now looks like.
func generateImagePreview(data []byte) (preview []byte, width, height int, ok bool) {
	img, err := imaging.Decode(bytes.NewReader(data), imaging.AutoOrientation(true))
	if err != nil {
		return nil, 0, 0, false
	}
	bounds := img.Bounds()
	if bounds.Dx() > previewMaxSide || bounds.Dy() > previewMaxSide {
		img = imaging.Fit(img, previewMaxSide, previewMaxSide, imaging.Linear)
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: previewJPEGQuality}); err != nil {
		return nil, 0, 0, false
	}
	return buf.Bytes(), bounds.Dx(), bounds.Dy(), true
}

// storeMediaWithPreview stores data (the exact bytes uploaded) at objectKey,
// and, if it decodes as an image, also stores a smaller/lower-quality
// preview alongside it — shared by handleUploadMedia and handleUploadAvatar,
// which otherwise duplicate this exact sequence. Only a failure to store the
// original is fatal; a preview that can't be generated or stored is
// silently skipped (see generateImagePreview's own doc comment) rather than
// failing the whole upload over what's just a nice-to-have.
func (s *Server) storeMediaWithPreview(ctx context.Context, objectKey, contentType string, data []byte) (
	width, height *int, previewObjectKey *string, err error,
) {
	if err := s.Media.Put(ctx, objectKey, bytes.NewReader(data), int64(len(data)), contentType); err != nil {
		return nil, nil, nil, fmt.Errorf("store original: %w", err)
	}
	if preview, w, h, ok := generateImagePreview(data); ok {
		previewKey := objectKey + ".preview.jpg"
		if putErr := s.Media.Put(ctx, previewKey, bytes.NewReader(preview), int64(len(preview)), "image/jpeg"); putErr == nil {
			previewObjectKey = &previewKey
			width, height = &w, &h
		} else {
			slog.Warn("store media: could not store preview, falling back to original", "error", putErr)
		}
	}
	return width, height, previewObjectKey, nil
}

// handleUploadMedia implements FR2.1/2.2: the client posts the file plus a
// "kind" field (image|video) as multipart form data, and gets back the chat
// message that was created for it — one request creates both the object store
// object and the message referencing it, so there's never a message
// pointing at bytes that don't exist (upload happens before either DB row).
func (s *Server) handleUploadMedia(w http.ResponseWriter, r *http.Request) {
	sender, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	userID := sender.ID
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
	// FR2.6: an optional caption, same as WhatsApp/iMessage's own attach
	// flow — absent means no caption, same as before this existed.
	var caption *string
	if v := r.FormValue("caption"); v != "" {
		caption = &v
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, http.StatusBadRequest, "missing file")
		return
	}
	defer file.Close()

	// Buffered fully in memory rather than streamed straight to the object store:
	// generating the preview below needs the whole thing to decode anyway,
	// and maxMediaUploadBytes already caps this at 200MiB.
	data, err := io.ReadAll(file)
	if err != nil {
		writeError(w, http.StatusBadRequest, "could not read upload")
		return
	}

	contentType := header.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	objectKey := fmt.Sprintf("%s/%s%s", roomID, uuid.NewString(), filepath.Ext(header.Filename))

	// generateImagePreview (inside storeMediaWithPreview) simply can't
	// decode video bytes as an image, so this naturally no-ops for a video
	// upload without needing to special-case kind here.
	width, height, previewObjectKey, err := s.storeMediaWithPreview(r.Context(), objectKey, contentType, data)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not store file")
		return
	}

	mediaObj, err := s.Store.CreateMediaObject(
		r.Context(), s.Media.Bucket(), objectKey, contentType, int64(len(data)), userID, width, height, previewObjectKey)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not record uploaded file")
		return
	}

	msg, err := s.Store.CreateMediaMessage(r.Context(), roomID, userID, kind, mediaObj.ID, caption, replyToMessageID, false)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create message")
		return
	}
	if width != nil && height != nil {
		msg.Media = &models.MediaInfo{Width: *width, Height: *height}
	}
	if replyToMessageID != nil {
		messages := []models.Message{msg}
		if err := s.Store.AttachReplyPreviews(r.Context(), messages); err == nil {
			msg = messages[0]
		}
	}

	s.deliverMessageEvent(r.Context(), roomID, sender, msg)

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
	if errors.Is(err, store.ErrNotFound) {
		// Not attached to a message via media_id directly — check whether
		// it's an ended location share's snapshot instead (attached via
		// location_shares.snapshot_media_id, a different column) before
		// falling through to "open to any authenticated user" below, which
		// is only actually correct for an avatar (no owning message at
		// all). A location snapshot reveals a real past location and must
		// stay scoped to the room it was shared in.
		message, err = s.Store.GetMessageByLocationSnapshotMediaID(r.Context(), mediaID)
	}
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusInternalServerError, "could not look up the message for this media")
		return
	}
	if err == nil && !s.requireMembership(w, r, userID, message.RoomID) {
		return
	}

	// FR2.*: the inline chat-bubble preview asks for ?variant=preview to
	// get the smaller, lower-quality re-encode instead of the full-quality
	// original — falls through to serving the original when there isn't
	// one (video, an undecodable image format, or a message uploaded
	// before this existed). No Range/seek support needed here: it's always
	// small enough to fetch in one shot, unlike video.
	if r.URL.Query().Get("variant") == "preview" && obj.PreviewObjectKey != nil {
		reader, err := s.Media.Get(r.Context(), *obj.PreviewObjectKey)
		if err != nil {
			writeError(w, http.StatusNotFound, "media not found")
			return
		}
		defer reader.Close()
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Type", "image/jpeg")
		w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
		_, _ = io.Copy(w, reader)
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
// so this also broadcasts message.deleted to the room. Once someone has
// seen it, the message stays as a "Deleted message" placeholder instead
// (FR1.15 — see handleDeleteMessage).
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

	seen, err := s.Store.HasBeenSeen(r.Context(), message.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up the message for this media")
		return
	}

	if err := s.Media.Delete(r.Context(), obj.ObjectKey); err != nil {
		writeError(w, http.StatusInternalServerError, "could not delete file")
		return
	}
	if obj.PreviewObjectKey != nil {
		// Best-effort: an orphaned preview object left behind in the object store costs
		// storage, not correctness (nothing else can ever reference it once
		// the media_objects row below is gone) — not worth failing the
		// whole delete over.
		if err := s.Media.Delete(r.Context(), *obj.PreviewObjectKey); err != nil {
			slog.Warn("delete media: could not delete preview object", "error", err)
		}
	}
	// Already seen: keep the message as a placeholder, detaching it from
	// the media first so deleting the media object below doesn't cascade
	// the message row away with it (migration 0002).
	if seen {
		if _, err := s.Store.SoftDeleteMessage(r.Context(), message.ID); err != nil {
			writeError(w, http.StatusInternalServerError, "could not delete message")
			return
		}
	}
	if err := s.Store.DeleteMediaObject(r.Context(), mediaID); err != nil {
		writeError(w, http.StatusInternalServerError, "could not delete media record")
		return
	}

	s.broadcastMessageDeletion(r.Context(), message, seen)
	w.WriteHeader(http.StatusNoContent)
}

// handleDeleteMessage implements FR1.15 for every kind except image/video —
// those go through handleDeleteMedia instead, since deleting the underlying
// file (not just the row) is that endpoint's job. A message someone other
// than the sender has already seen becomes a "Deleted message" placeholder
// (Store.SoftDeleteMessage); one nobody has seen yet is removed entirely.
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
	if message.DeletedAt != nil {
		w.WriteHeader(http.StatusNoContent) // already a placeholder
		return
	}
	if message.Kind == models.MessageKindSystem {
		writeError(w, http.StatusBadRequest, "this message can't be deleted")
		return
	}
	if message.Kind == models.MessageKindImage || message.Kind == models.MessageKindVideo {
		writeError(w, http.StatusBadRequest, "delete this message's media instead, via DELETE /api/media/:id")
		return
	}

	seen, err := s.Store.HasBeenSeen(r.Context(), messageID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up message")
		return
	}
	if seen {
		if _, err := s.Store.SoftDeleteMessage(r.Context(), messageID); err != nil {
			writeError(w, http.StatusInternalServerError, "could not delete message")
			return
		}
	} else if err := s.Store.DeleteMessage(r.Context(), messageID); err != nil {
		writeError(w, http.StatusInternalServerError, "could not delete message")
		return
	}

	s.broadcastMessageDeletion(r.Context(), message, seen)
	w.WriteHeader(http.StatusNoContent)
}

// liveMessage is Store.GetMessage for acting on a message — reacting,
// editing, forwarding, replying, updating a location share: a
// placeholder-deleted message (FR1.15) reports as not found, since there's
// nothing left to act on.
func (s *Server) liveMessage(ctx context.Context, id string) (models.Message, error) {
	message, err := s.Store.GetMessage(ctx, id)
	if err == nil && message.DeletedAt != nil {
		return models.Message{}, store.ErrNotFound
	}
	return message, err
}

// broadcastMessageDeletion tells message's room it was deleted (FR1.15): a
// message.updated carrying the placeholder when it had already been seen
// (softDeleted), otherwise message.deleted so clients drop it entirely.
func (s *Server) broadcastMessageDeletion(ctx context.Context, message models.Message, softDeleted bool) {
	memberIDs, err := s.Store.ListRoomMemberIDs(ctx, message.RoomID)
	if err != nil {
		return
	}
	if !softDeleted {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.deleted", Payload: map[string]string{
			"messageId": message.ID, "roomId": message.RoomID,
		}})
		return
	}
	placeholder, err := s.Store.GetMessage(ctx, message.ID)
	if err != nil {
		slog.Error("delete: reload placeholder failed", "message", message.ID, "error", err)
		return
	}
	messages := []models.Message{placeholder}
	if err := s.Store.AttachReplyPreviews(ctx, messages); err != nil {
		slog.Error("delete: attach reply preview failed", "message", message.ID, "error", err)
	}
	s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.updated", Payload: messages[0]})
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
	if err := s.Store.AttachMedia(r.Context(), messages); err != nil {
		writeError(w, http.StatusInternalServerError, "could not load media dimensions")
		return
	}
	writeJSON(w, http.StatusOK, messages)
}

// messageRoomForReaction fetches the message and verifies the caller is a
// member of its room, returning the room ID on success. Shared by add/remove
// since both need the same authorization check before touching a reaction.
func (s *Server) messageRoomForReaction(w http.ResponseWriter, r *http.Request, userID, messageID string) (roomID string, ok bool) {
	message, err := s.liveMessage(r.Context(), messageID)
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
	if message.Kind == models.MessageKindSystem {
		writeError(w, http.StatusBadRequest, "this message can't be reacted to")
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

	message, err := s.liveMessage(r.Context(), messageID)
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
// than share media, a forwarded image/video gets its own object-store object (a
// server-side copy) and its own media_objects row, so deleting either copy
// never affects the other.
func (s *Server) handleForwardMessage(w http.ResponseWriter, r *http.Request) {
	sender, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	userID := sender.ID
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

	original, err := s.liveMessage(r.Context(), messageID)
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
		forwarded, err = s.Store.CreateMediaMessage(r.Context(), body.RoomID, userID, string(original.Kind), mediaID, original.Body, nil, true)
		if err == nil {
			messages := []models.Message{forwarded}
			if attachErr := s.Store.AttachMedia(r.Context(), messages); attachErr == nil {
				forwarded = messages[0]
			}
		}
	default:
		writeError(w, http.StatusBadRequest, "this message type can't be forwarded")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not forward message")
		return
	}

	s.deliverMessageEvent(r.Context(), body.RoomID, sender, forwarded)
	writeJSON(w, http.StatusCreated, forwarded)
}

// duplicateMedia copies an existing media object's bytes — and its preview,
// if it has one — to new keys in the object store, and records a new, independent
// media_objects row for it, returning the new object's ID. A failed preview
// copy is best-effort: the forwarded copy just falls back to serving its
// own original for the inline preview too, same as any message whose
// preview was never generated in the first place.
func (s *Server) duplicateMedia(ctx context.Context, sourceMediaID, dstRoomID, uploadedBy string) (string, error) {
	src, err := s.Store.GetMediaObject(ctx, sourceMediaID)
	if err != nil {
		return "", fmt.Errorf("look up source media: %w", err)
	}
	dstKey := fmt.Sprintf("%s/%s%s", dstRoomID, uuid.NewString(), filepath.Ext(src.ObjectKey))
	if err := s.Media.Copy(ctx, src.ObjectKey, dstKey); err != nil {
		return "", fmt.Errorf("copy object: %w", err)
	}

	var previewKey *string
	if src.PreviewObjectKey != nil {
		dstPreviewKey := dstKey + ".preview.jpg"
		if err := s.Media.Copy(ctx, *src.PreviewObjectKey, dstPreviewKey); err == nil {
			previewKey = &dstPreviewKey
		} else {
			slog.Warn("duplicate media: could not copy preview, forwarded copy will fall back to original", "error", err)
		}
	}

	dst, err := s.Store.CreateMediaObject(
		ctx, s.Media.Bucket(), dstKey, src.ContentType, src.SizeBytes, uploadedBy, src.Width, src.Height, previewKey)
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
	sender, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	userID := sender.ID
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

	// One live share per person per room: end any earlier one first, so a
	// share the app lost track of can't linger with a frozen position.
	ended, err := s.Store.EndActiveLocationSharesInRoom(r.Context(), roomID, userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create location share")
		return
	}
	if len(ended) > 0 {
		if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), roomID); err == nil {
			for _, m := range ended {
				s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.updated", Payload: m})
			}
		}
	}

	msg, err := s.Store.CreateLocationMessage(r.Context(), roomID, userID, body.Lat, body.Lng, ttl)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create location share")
		return
	}

	s.deliverMessageEvent(r.Context(), roomID, sender, msg)
	writeJSON(w, http.StatusCreated, msg)
}

// handleListMyLocationShares returns the caller's live location shares
// across all rooms, so the app can resume tracking them after a restart
// (it only tracks while running).
func (s *Server) handleListMyLocationShares(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	shares, err := s.Store.ListActiveLocationShares(r.Context(), userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not list location shares")
		return
	}
	writeJSON(w, http.StatusOK, shares)
}

// locationShareForUpdate fetches messageID, verifies it's an active
// location share belonging to userID, and returns it — shared by
// handleUpdateLocation and handleEndLocationShare, mirroring how
// messageRoomForReaction centralizes the lookup+authorization for reactions.
func (s *Server) locationShareForUpdate(w http.ResponseWriter, r *http.Request, userID, messageID string) (models.Message, bool) {
	message, err := s.liveMessage(r.Context(), messageID)
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

// handleLocationSnapshot implements the ended-share preview half of FR3.7:
// lazily fetches a static map image for messageID's last known position,
// server-side (internal/staticmap), the first time any client actually asks
// to view it — never eagerly, since most ended shares are never revisited,
// and there's no background sweep for TTL expiry to hook into anyway (it's
// a pure now-vs-expiresAt comparison at read time, see LocationShare.Active).
// Idempotent: a share that already has a snapshot just returns it
// unchanged, so a second room member's device (or the same device asking
// twice) never re-fetches or re-bills. Any room member may call this, not
// just the sender — everyone in the room needs to view an ended share's
// preview, unlike handleUpdateLocation/handleEndLocationShare which are
// sender-only.
func (s *Server) handleLocationSnapshot(w http.ResponseWriter, r *http.Request) {
	userID, ok := currentUser(w, r)
	if !ok {
		return
	}
	messageID := chi.URLParam(r, "messageID")
	message, err := s.liveMessage(r.Context(), messageID)
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
	if message.Kind != models.MessageKindLocation {
		writeError(w, http.StatusBadRequest, "not a location share")
		return
	}

	share, err := s.Store.GetLocationShare(r.Context(), messageID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not look up location share")
		return
	}
	if share.Active(time.Now()) {
		writeError(w, http.StatusConflict, "share is still active")
		return
	}

	if share.SnapshotMediaID == nil {
		data, contentType, err := s.StaticMap.Fetch(r.Context(), share.Lat, share.Lng)
		if err != nil {
			slog.Warn("location snapshot: fetch failed", "message", messageID, "error", err)
			writeError(w, http.StatusServiceUnavailable, "could not fetch map snapshot")
			return
		}
		objectKey := "location-snapshots/" + messageID
		if err := s.Media.Put(r.Context(), objectKey, bytes.NewReader(data), int64(len(data)), contentType); err != nil {
			writeError(w, http.StatusInternalServerError, "could not store map snapshot")
			return
		}
		mediaObj, err := s.Store.CreateMediaObject(
			r.Context(), s.Media.Bucket(), objectKey, contentType, int64(len(data)), message.SenderID, nil, nil, nil)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "could not record map snapshot")
			return
		}
		share, err = s.Store.SetLocationSnapshot(r.Context(), messageID, mediaObj.ID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "could not save map snapshot")
			return
		}
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
//
// The caller's own client still needs this event too, even though it
// already has msg from this handler's HTTP response and uses that to jump
// straight to the call screen: chat_providers.dart's MessagesController
// never mutates its message list except in response to a WS event (see
// deliverMessageEvent's doc comment for the same reasoning on ordinary
// messages), so skipping the echo here left the call message entirely
// absent from the caller's own local list — meaning a later message.updated
// (the call being finalized as missed/declined/ended) had no matching id to
// update and was silently dropped, only surfacing after the next full
// history refetch. The caller gets no push fallback for it, though — see
// deliverMessageEvent, which never pushes a sender about their own message
// either.
//
// FR5.1: a member (other than the caller) not currently reachable over the
// WebSocket (backgrounded or fully closed app) gets a push call-wake
// fallback instead, to every device they've registered (see
// handleRegisterDevice). Best-effort — a delivery failure here never fails
// the API response, since push is a fallback path, not the primary one.
func (s *Server) handleStartCall(w http.ResponseWriter, r *http.Request) {
	caller, ok := session.UserFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	roomID := chi.URLParam(r, "roomID")
	if !s.requireMembership(w, r, caller.ID, roomID) {
		return
	}

	msg, err := s.Store.CreateCall(r.Context(), roomID, caller.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not start call")
		return
	}

	s.Hub.SendToUser(caller.ID, ws.Event{Type: "message.created", Payload: msg})
	s.deliverToRoom(r.Context(), roomID, caller.ID, ws.Event{Type: "message.created", Payload: msg},
		func(ctx context.Context, memberID string) {
			var callID string
			if msg.Call != nil {
				callID = msg.Call.ID
			}
			s.pushCallWake(ctx, memberID, push.CallWakePayload{
				RoomID:     roomID,
				MessageID:  msg.ID,
				CallID:     callID,
				CallerID:   caller.ID,
				CallerName: caller.DisplayName,
			})
		})
	writeJSON(w, http.StatusCreated, msg)
}

// deliverToRoom sends ev to every member of roomID except excludeUserID (the
// caller) over the WebSocket, calling onOffline for anyone not currently
// reachable that way — FR5.1's "WS, else push fallback" pattern for
// handleStartCall specifically, whose caller needs neither the WS echo nor
// a push about the call it just started (see deliverMessageEvent's doc
// comment for why FR5.2 doesn't reuse this as-is). A failure to list
// members is logged and otherwise swallowed — delivery is always
// best-effort, never something that fails the API response that created
// the message/call in the first place.
func (s *Server) deliverToRoom(
	ctx context.Context, roomID, excludeUserID string, ev ws.Event, onOffline func(ctx context.Context, memberID string),
) {
	memberIDs, err := s.Store.ListRoomMemberIDs(ctx, roomID)
	if err != nil {
		slog.Error("deliver: list room members failed", "room", roomID, "error", err)
		return
	}
	for _, memberID := range memberIDs {
		if memberID == excludeUserID {
			continue
		}
		if s.Hub.SendToUser(memberID, ev) {
			continue
		}
		onOffline(ctx, memberID)
	}
}

// deliverMessageEvent implements FR5.2's WS-first, push-fallback delivery
// for a genuinely new message (text, media, location, or forward — not
// reactions/edits/receipts, which aren't "new messages"). Deliberately does
// NOT reuse deliverToRoom, despite the similar shape: a message's sender
// needs its own message.created event echoed back — the client has no
// local optimistic append of its own, so the WS broadcast back to the
// sender's own socket is the only way it ever renders the message it just
// sent (see chat_providers.dart's send()) — and handleStartCall's caller
// needs the same echo for the same reason (see that handler's own doc
// comment), just via a direct extra send rather than this function, since
// it still wants deliverToRoom's per-member push-wake fallback for
// everyone else. The sender is still never sent a *push* about their own
// message, though — there's no reason to notify someone about something
// they did themselves. senderName is display-only, for the notification's
// title —
// see push.MessagePayload's own doc comment on why the body never carries
// the actual message content.
func (s *Server) deliverMessageEvent(ctx context.Context, roomID string, sender models.User, msg models.Message) {
	memberIDs, err := s.Store.ListRoomMemberIDs(ctx, roomID)
	if err != nil {
		slog.Error("deliver: list room members failed", "room", roomID, "error", err)
		return
	}
	// FR5.3: a member who muted the room still gets the message, just no push.
	muted, err := s.Store.MutedMemberIDs(ctx, roomID)
	if err != nil {
		slog.Error("deliver: list muted members failed", "room", roomID, "error", err)
	}
	ev := ws.Event{Type: "message.created", Payload: msg}
	for _, memberID := range memberIDs {
		if s.Hub.SendToUser(memberID, ev) {
			continue
		}
		if memberID == sender.ID || muted[memberID] {
			continue
		}
		s.pushMessageNotification(ctx, memberID, push.MessagePayload{
			RoomID:              roomID,
			MessageID:           msg.ID,
			SenderID:            sender.ID,
			SenderName:          sender.DisplayName,
			SenderAvatarMediaID: sender.AvatarMediaID,
			Preview:             previewForMessage(msg),
		})
	}
}

// previewForMessage is what a new-message notification says about msg —
// the counterpart of the app's messagePreviewLabel
// (app/lib/features/chat/reply_preview.dart): the text itself, a
// photo/video's caption, or a label for other kinds. Only ever sent
// encrypted (see push.MessagePayload).
func previewForMessage(msg models.Message) string {
	body := ""
	if msg.Body != nil {
		body = *msg.Body
	}
	switch msg.Kind {
	case models.MessageKindImage:
		if body != "" {
			return "📷 " + body
		}
		return "📷 Photo"
	case models.MessageKindVideo:
		if body != "" {
			return "🎥 " + body
		}
		return "🎥 Video"
	case models.MessageKindLocation:
		return "📍 Live location"
	default:
		return body
	}
}

// pushCallWake sends the FR5.1 call-wake push to every device memberID has
// registered — only ever the VoIP-token row on iOS (a device's "fcm" row is
// for message notifications only, and can't receive VoIP-type pushes at
// all; Android's single row is always usable, since its one FCM token
// covers both purposes). Delivery failures are logged and otherwise
// ignored — see handleStartCall's own doc comment for why.
func (s *Server) pushCallWake(ctx context.Context, userID string, payload push.CallWakePayload) {
	devices, err := s.Store.ListDevicesForUser(ctx, userID)
	if err != nil {
		slog.Error("push: list devices failed", "user", userID, "error", err)
		return
	}
	for _, d := range devices {
		if d.Platform == "ios" && d.TokenType != "voip" {
			continue
		}
		if err := s.Push.SendCallWake(ctx, d.PushToken, d.Platform, payload); err != nil {
			slog.Error("push: call wake failed", "user", userID, "device", d.ID, "platform", d.Platform, "error", err)
		}
	}
}

// pushMessageNotification sends the FR5.2 message-notification push to
// every "fcm" device memberID has registered (both platforms — see
// models.Device) — skips a device's "voip" row, which can't receive a
// plain alert-type push. Delivery failures are logged and otherwise
// ignored, same as pushCallWake.
func (s *Server) pushMessageNotification(ctx context.Context, userID string, payload push.MessagePayload) {
	devices, err := s.Store.ListDevicesForUser(ctx, userID)
	if err != nil {
		slog.Error("push: list devices failed", "user", userID, "error", err)
		return
	}
	for _, d := range devices {
		if d.TokenType != "fcm" {
			continue
		}
		if err := s.Push.SendMessageNotification(ctx, d.PushToken, d.Platform, d.PushPublicKey, payload); err != nil {
			slog.Error("push: message notification failed", "user", userID, "device", d.ID, "platform", d.Platform, "error", err)
		}
	}
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

// handleLeaveCall implements FR4.5's end/hang-up, for the caller giving up
// on an unanswered call and for anyone hanging up mid-call alike. When that
// ends the call (see Store.LeaveCall for when it does), the room is told.
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

	// Optional: the caller's app sends noAnswer when its ring timeout gave
	// up, so the call ends as missed even if someone accepted it but never
	// connected (see Store.LeaveCall). An empty body is an ordinary hang-up.
	var body struct {
		NoAnswer bool `json:"noAnswer"`
	}
	if r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeError(w, http.StatusBadRequest, "invalid body")
			return
		}
	}

	updated, finalized, err := s.Store.LeaveCall(r.Context(), callID, userID, body.NoAnswer)
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
