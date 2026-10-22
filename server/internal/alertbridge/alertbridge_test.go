package alertbridge

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type fakeSender struct {
	sent []string
	fail func(text string) error
}

func (f *fakeSender) Send(ctx context.Context, text string) error {
	if f.fail != nil {
		if err := f.fail(text); err != nil {
			return err
		}
	}
	f.sent = append(f.sent, text)
	return nil
}

func TestFormatAlert(t *testing.T) {
	cases := []struct {
		name  string
		alert Alert
		want  string
	}{
		{
			name: "critical",
			alert: Alert{Status: "firing", Labels: map[string]string{"alertname": "HighCPU", "severity": "critical"},
				Annotations: map[string]string{"summary": "CPU on node1", "description": "95% for 10m"}},
			want: "🚨 HighCPU\n\nCPU on node1\n\n95% for 10m",
		},
		{
			name:  "warning",
			alert: Alert{Status: "firing", Labels: map[string]string{"alertname": "DiskLow", "severity": "warning"}, Annotations: map[string]string{"summary": "Disk 80%"}},
			want:  "⚠️ DiskLow\n\nDisk 80%",
		},
		{
			name:  "unknown severity, no annotations",
			alert: Alert{Status: "firing", Labels: map[string]string{"alertname": "Odd"}},
			want:  "ℹ️ Odd",
		},
		{
			name:  "resolved ignores severity and annotations",
			alert: Alert{Status: "resolved", Labels: map[string]string{"alertname": "HighCPU", "severity": "critical"}, Annotations: map[string]string{"summary": "x"}},
			want:  "✅ Resolved Alert: HighCPU",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := FormatAlert(tc.alert); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func post(h http.Handler, path, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, path, strings.NewReader(body)))
	return rec
}

const twoAlerts = `{"status":"firing","alerts":[
 {"status":"firing","labels":{"alertname":"A","severity":"critical"},"annotations":{"summary":"a"}},
 {"status":"resolved","labels":{"alertname":"B"}}]}`

func TestAlerts_SendsEachAlert(t *testing.T) {
	sender := &fakeSender{}
	rec := post(Handler{Sender: sender}.Routes(), "/alerts", twoAlerts)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if len(sender.sent) != 2 || sender.sent[1] != "✅ Resolved Alert: B" {
		t.Fatalf("unexpected messages: %q", sender.sent)
	}
}

func TestAlerts_FailedSendAnswers502SoAlertmanagerRetries(t *testing.T) {
	sender := &fakeSender{fail: func(text string) error {
		if strings.Contains(text, "Resolved") {
			return errors.New("roost down")
		}
		return nil
	}}
	rec := post(Handler{Sender: sender}.Routes(), "/alerts", twoAlerts)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("expected 502, got %d", rec.Code)
	}
	if len(sender.sent) != 1 {
		t.Fatalf("the alert that could be sent should still go out, got %q", sender.sent)
	}
}

func TestAlerts_RejectsBadPayload(t *testing.T) {
	sender := &fakeSender{}
	rec := post(Handler{Sender: sender}.Routes(), "/alerts", "not json")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
	if len(sender.sent) != 0 {
		t.Fatalf("nothing should be sent, got %q", sender.sent)
	}
}

func TestAlerts_OnlyPost(t *testing.T) {
	rec := httptest.NewRecorder()
	Handler{Sender: &fakeSender{}}.Routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/alerts", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", rec.Code)
	}
}

func TestWatchdog(t *testing.T) {
	sender := &fakeSender{}
	if rec := post(Handler{Sender: sender}.Routes(), "/watchdog", ""); rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if len(sender.sent) != 1 || !strings.Contains(sender.sent[0], "Watchdog") {
		t.Fatalf("unexpected messages: %q", sender.sent)
	}

	failing := &fakeSender{fail: func(string) error { return errors.New("down") }}
	if rec := post(Handler{Sender: failing}.Routes(), "/watchdog", ""); rec.Code != http.StatusBadGateway {
		t.Fatalf("expected 502 when the send fails, got %d", rec.Code)
	}
}

func TestRoostSender(t *testing.T) {
	var gotPath, gotBody, gotType string
	status := http.StatusCreated
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotType = r.URL.Path, r.Header.Get("Content-Type")
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.WriteHeader(status)
		_, _ = w.Write([]byte("nope"))
	}))
	defer srv.Close()

	sender := RoostSender{BaseURL: srv.URL + "/", Client: srv.Client()}
	if err := sender.Send(context.Background(), "🚨 hi"); err != nil {
		t.Fatalf("send: %v", err)
	}
	if gotPath != "/bot/messages" || gotType != "application/json" {
		t.Fatalf("unexpected request: path=%q type=%q", gotPath, gotType)
	}
	var decoded struct{ Body string }
	if err := json.Unmarshal([]byte(gotBody), &decoded); err != nil || decoded.Body != "🚨 hi" {
		t.Fatalf("unexpected body %q (%v)", gotBody, err)
	}

	status = http.StatusForbidden
	err := sender.Send(context.Background(), "x")
	if err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("expected a 403 error, got %v", err)
	}
}
