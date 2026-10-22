package api

import (
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"testing"

	"roost/server/internal/models"
)

func TestSameAvatar(t *testing.T) {
	upload := func(contentType string, size int64) *multipart.FileHeader {
		h := textproto.MIMEHeader{}
		h.Set("Content-Type", contentType)
		return &multipart.FileHeader{Header: h, Size: size}
	}
	current := models.MediaObject{ContentType: "image/jpeg", SizeBytes: 19273}

	cases := []struct {
		name   string
		upload *multipart.FileHeader
		want   bool
	}{
		{"identical type and size", upload("image/jpeg", 19273), true},
		{"different size", upload("image/jpeg", 19274), false},
		{"different type, same size", upload("image/png", 19273), false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := sameAvatar(current, tc.upload); got != tc.want {
				t.Errorf("got %v, want %v", got, tc.want)
			}
		})
	}
}

func TestHandleBotAvatar_NoUserInContextIsForbidden(t *testing.T) {
	rec := httptest.NewRecorder()
	(&Server{}).handleBotAvatar(rec, httptest.NewRequest(http.MethodPost, "/bot/avatar", nil))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rec.Code)
	}
}
