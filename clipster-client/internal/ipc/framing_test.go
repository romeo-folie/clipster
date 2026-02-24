package ipc

import (
	"encoding/binary"
	"encoding/json"
	"testing"
	"time"
)

// framePack manually builds a framed message for testing.
func framePack(t *testing.T, payload any) []byte {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	frame := make([]byte, 4+len(body))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(body)))
	copy(frame[4:], body)
	return frame
}

func TestDialTimeout(t *testing.T) {
	// Dial to a non-existent socket must fail within the timeout window.
	start := nowMs()
	_, err := Dial()
	elapsed := nowMs() - start
	if err == nil {
		t.Skip("clipsterd appears to be running — skipping timeout test")
	}
	// Should fail quickly (within 2x DialTimeout for OS scheduling slack)
	maxMs := int64(DialTimeout.Milliseconds()) * 2
	if elapsed > maxMs {
		t.Errorf("Dial took %dms, expected ≤%dms", elapsed, maxMs)
	}
}

func TestIsDaemonRunningFalseWhenNoSocket(t *testing.T) {
	// If daemon is not running this must return false.
	// If it IS running, skip rather than fail.
	if IsDaemonRunning() {
		t.Skip("clipsterd is running — skipping IsDaemonRunning=false test")
	}
}

func TestCommandMarshal(t *testing.T) {
	cmd := Command{
		Version: ProtocolVersion,
		ID:      "test-id",
		Command: "list",
		Params:  Params{Limit: ptr(20), Offset: ptr(0)},
	}
	data, err := json.Marshal(cmd)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out["command"] != "list" {
		t.Errorf("got command=%v, want list", out["command"])
	}
	if int(out["version"].(float64)) != ProtocolVersion {
		t.Errorf("got version=%v, want %d", out["version"], ProtocolVersion)
	}
}

func TestResponseUnmarshal(t *testing.T) {
	errMsg := "not_found"
	raw := json.RawMessage(`{}`)
	resp := Response{
		ProtocolVersion: 1,
		ID:              "abc",
		OK:              false,
		Data:            &raw,
		Error:           &errMsg,
	}
	data, _ := json.Marshal(resp)

	var got Response
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.OK {
		t.Error("expected OK=false")
	}
	if *got.Error != errMsg {
		t.Errorf("got error=%q, want %q", *got.Error, errMsg)
	}
}

func TestFrameRoundtrip(t *testing.T) {
	type msg struct{ Hello string }
	frame := framePack(t, msg{Hello: "world"})

	// Length prefix must equal body length
	bodyLen := int(binary.BigEndian.Uint32(frame[:4]))
	if bodyLen != len(frame)-4 {
		t.Errorf("length prefix %d != body length %d", bodyLen, len(frame)-4)
	}

	// Body must unmarshal correctly
	var out msg
	if err := json.Unmarshal(frame[4:], &out); err != nil {
		t.Fatalf("unmarshal body: %v", err)
	}
	if out.Hello != "world" {
		t.Errorf("got %q, want %q", out.Hello, "world")
	}
}

// Helpers

func ptr[T any](v T) *T { return &v }

func nowMs() int64 {
	return time.Now().UnixMilli()
}
