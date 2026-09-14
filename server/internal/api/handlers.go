package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

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
		Body string `json:"body"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Body == "" {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}

	msg, err := s.Store.CreateTextMessage(r.Context(), roomID, userID, body.Body)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create message")
		return
	}

	if memberIDs, err := s.Store.ListRoomMemberIDs(r.Context(), roomID); err == nil {
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.created", Payload: msg})
	}

	writeJSON(w, http.StatusCreated, msg)
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
	writeJSON(w, http.StatusOK, messages)
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
