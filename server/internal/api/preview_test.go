package api

import (
	"testing"

	"roost/server/internal/models"
)

func TestPreviewForMessage(t *testing.T) {
	text := func(s string) *string { return &s }
	cases := []struct {
		msg  models.Message
		want string
	}{
		{models.Message{Kind: models.MessageKindText, Body: text("Dinner's at 7")}, "Dinner's at 7"},
		{models.Message{Kind: models.MessageKindImage}, "📷 Photo"},
		{models.Message{Kind: models.MessageKindImage, Body: text("Sunset")}, "📷 Sunset"},
		{models.Message{Kind: models.MessageKindVideo}, "🎥 Video"},
		{models.Message{Kind: models.MessageKindLocation}, "📍 Live location"},
	}
	for _, c := range cases {
		if got := previewForMessage(c.msg); got != c.want {
			t.Errorf("%s: got %q, want %q", c.msg.Kind, got, c.want)
		}
	}
}
