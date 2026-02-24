package format

import (
	"strings"
	"testing"
	"time"
)

func TestFallbackBanner(t *testing.T) {
	banner := FallbackBanner()
	if !strings.Contains(banner, "clipsterd not running") {
		t.Errorf("expected banner to mention 'clipsterd not running', got: %q", banner)
	}
	if !strings.Contains(banner, "clipster daemon start") {
		t.Errorf("expected banner to mention 'clipster daemon start', got: %q", banner)
	}
}

func TestWriteOnlyError(t *testing.T) {
	msg := WriteOnlyError()
	if !strings.Contains(msg, "clipsterd not running") {
		t.Errorf("expected write-only error to mention daemon, got: %q", msg)
	}
}

func TestContentTypeIconKnownTypes(t *testing.T) {
	types := []string{"plain-text", "rich-text", "image", "url", "file", "code", "colour", "email", "phone"}
	for _, ct := range types {
		icon := ContentTypeIcon(ct)
		if icon == "" || icon == "📋" {
			// 📋 is the fallback — all known types should have a dedicated icon
			t.Errorf("ContentTypeIcon(%q) returned fallback icon", ct)
		}
	}
}

func TestContentTypeIconFallback(t *testing.T) {
	icon := ContentTypeIcon("unknown-type")
	if icon != "📋" {
		t.Errorf("expected fallback icon '📋', got %q", icon)
	}
}

func TestEntryLine(t *testing.T) {
	msNow := time.Now().UnixMilli()
	line := EntryLine(1, "plain-text", "Hello, World!", "Safari", msNow, false)
	if !strings.Contains(line, "1.") {
		t.Error("expected line index")
	}
	if !strings.Contains(line, "Hello") {
		t.Error("expected preview text")
	}
}

func TestEntryLineWithPin(t *testing.T) {
	msNow := time.Now().UnixMilli()
	line := EntryLine(1, "url", "https://example.com", "", msNow, true)
	if !strings.Contains(line, "📌") {
		t.Error("expected pin indicator")
	}
}

func TestEntryDetailContainsContent(t *testing.T) {
	content := "package main\n\nfunc main() {}"
	detail := EntryDetail("code", content, "Xcode", "high", time.Now().UnixMilli())
	// EntryDetail indents multi-line content with "   " — check for key substrings
	// rather than exact match.
	if !strings.Contains(detail, "package main") {
		t.Error("expected content first line in detail output")
	}
	if !strings.Contains(detail, "func main()") {
		t.Error("expected content last line in detail output")
	}
}

func TestEntryDetailLowConfidence(t *testing.T) {
	detail := EntryDetail("plain-text", "text", "Safari", "low", time.Now().UnixMilli())
	if !strings.Contains(detail, "low confidence") {
		t.Error("expected 'low confidence' annotation")
	}
}

func TestEntryDetailTruncatesLongContent(t *testing.T) {
	long := strings.Repeat("a", 600)
	detail := EntryDetail("plain-text", long, "", "high", time.Now().UnixMilli())
	if !strings.Contains(detail, "truncated") {
		t.Error("expected truncation indicator for content > 500 chars")
	}
}

func TestTruncate(t *testing.T) {
	tests := []struct {
		input string
		max   int
		want  string
	}{
		{"hello", 10, "hello"},
		{"hello world", 5, "hell…"},
		{"", 5, ""},
	}
	for _, tc := range tests {
		got := truncate(tc.input, tc.max)
		if got != tc.want {
			t.Errorf("truncate(%q, %d) = %q, want %q", tc.input, tc.max, got, tc.want)
		}
	}
}

func TestRelativeTimeJustNow(t *testing.T) {
	rt := relativeTime(time.Now().UnixMilli())
	if rt != "just now" {
		t.Errorf("expected 'just now', got %q", rt)
	}
}

func TestRelativeTimeMinutesAgo(t *testing.T) {
	ms := time.Now().Add(-5 * time.Minute).UnixMilli()
	rt := relativeTime(ms)
	if !strings.Contains(rt, "m ago") {
		t.Errorf("expected 'm ago', got %q", rt)
	}
}
