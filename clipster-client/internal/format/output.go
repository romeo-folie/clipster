// Package format provides entry formatting for clipster CLI output.
package format

import (
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

// ContentTypeIcon returns a display icon for a content type. PRD §7.5.
func ContentTypeIcon(ct string) string {
	switch ct {
	case "plain-text":
		return "📄"
	case "rich-text":
		return "📝"
	case "image":
		return "🖼"
	case "url":
		return "🔗"
	case "file":
		return "📁"
	case "code":
		return "💻"
	case "colour":
		return "🎨"
	case "email":
		return "✉️"
	case "phone":
		return "📞"
	default:
		return "📋"
	}
}

// FallbackBanner returns the fallback mode warning banner.
// PRD §7.5 — shown when clipsterd is not running.
func FallbackBanner() string {
	return "⚠  clipsterd not running — read-only mode. Run: clipster daemon start"
}

// WriteOnlyError is the message shown when a write command is attempted in fallback mode.
func WriteOnlyError() string {
	return "clipsterd not running — this operation requires the daemon. Run: clipster daemon start"
}

// EntryLine formats a single entry as a compact list line.
// Format: [index] ICON preview  (source | relative_time)
func EntryLine(index int, contentType, preview, sourceName string, createdAt int64, isPinned bool) string {
	icon := ContentTypeIcon(contentType)
	pin := ""
	if isPinned {
		pin = " 📌"
	}

	displayText := truncate(preview, 60)
	ts := relativeTime(createdAt)
	src := ""
	if sourceName != "" {
		src = fmt.Sprintf(" | %s", sourceName)
	}

	return fmt.Sprintf("%3d. %s%s  %-60s  (%s%s)", index, icon, pin, displayText, ts, src)
}

// EntryDetail formats a single entry with full content for `clipster last`.
func EntryDetail(contentType, content, sourceName, sourceConfidence string, createdAt int64) string {
	var b strings.Builder
	icon := ContentTypeIcon(contentType)
	b.WriteString(fmt.Sprintf("%s [%s]  %s\n", icon, contentType, relativeTime(createdAt)))
	if sourceName != "" {
		conf := ""
		if sourceConfidence == "low" {
			conf = " (low confidence)"
		}
		b.WriteString(fmt.Sprintf("   Source: %s%s\n", sourceName, conf))
	}
	b.WriteString("   ─────────────────────────────\n")
	// Truncate very long content for terminal display
	displayContent := content
	if utf8.RuneCountInString(content) > 500 {
		runes := []rune(content)
		displayContent = string(runes[:500]) + "\n   … (truncated)"
	}
	b.WriteString("   " + strings.ReplaceAll(displayContent, "\n", "\n   "))
	return b.String()
}

func truncate(s string, max int) string {
	runes := []rune(s)
	if len(runes) <= max {
		return s
	}
	return string(runes[:max-1]) + "…"
}

func relativeTime(msEpoch int64) string {
	t := time.UnixMilli(msEpoch)
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return t.Format("Jan 2")
	}
}
