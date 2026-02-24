// Package tui implements the Bubble Tea interactive TUI for clipster.
// PRD §7.5 — list view, inline filter, keybindings, type icons, source display.
package tui

import (
	"fmt"
	"os/exec"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/romeo-folie/clipster/cli/internal/ipc"
)

// ─── Modes ───────────────────────────────────────────────────────────────────

type mode int

const (
	modeNormal    mode = iota
	modeFilter         // typing in the filter bar
	modeTransform      // transform panel open
	modeConfirm        // delete confirmation
)

// ─── Messages ────────────────────────────────────────────────────────────────

type entriesLoadedMsg struct{ entries []ipc.Entry }
type errMsg struct{ err error }
type pinnedMsg struct{ entryID string; pinned bool }
type deletedMsg struct{ entryID string }
type transformedMsg struct{ result string }
type copiedMsg struct{}

// ─── Transforms ──────────────────────────────────────────────────────────────

var transforms = []string{
	"uppercase", "lowercase", "trim",
	"snake_case", "camel_case",
	"encode_url", "decode_url",
	"encode_base64", "decode_base64",
	"strip_html", "count_words",
}

// ─── Styles ──────────────────────────────────────────────────────────────────

var (
	styleHeader = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("12")).
			MarginBottom(1)

	styleSelected = lipgloss.NewStyle().
			Background(lipgloss.Color("236")).
			Foreground(lipgloss.Color("15")).
			Bold(true)

	styleDimmed = lipgloss.NewStyle().
			Foreground(lipgloss.Color("243"))

	stylePin = lipgloss.NewStyle().
			Foreground(lipgloss.Color("11")) // yellow

	styleType = lipgloss.NewStyle().
			Foreground(lipgloss.Color("6")) // cyan

	styleSource = lipgloss.NewStyle().
			Foreground(lipgloss.Color("5")) // magenta

	styleFooter = lipgloss.NewStyle().
			Foreground(lipgloss.Color("240")).
			MarginTop(1)

	styleFilter = lipgloss.NewStyle().
			Foreground(lipgloss.Color("10")).
			Bold(true)

	styleError = lipgloss.NewStyle().
			Foreground(lipgloss.Color("9")).
			Bold(true)

	stylePanelBorder = lipgloss.NewStyle().
				Border(lipgloss.RoundedBorder()).
				BorderForeground(lipgloss.Color("12")).
				Padding(0, 1)

	stylePanelSelected = lipgloss.NewStyle().
				Foreground(lipgloss.Color("15")).
				Background(lipgloss.Color("27")).
				Bold(true)
)

// ─── Model ───────────────────────────────────────────────────────────────────

// Model is the Bubble Tea model for the clipster TUI.
type Model struct {
	// Data
	allEntries      []ipc.Entry
	filteredEntries []ipc.Entry
	ipcClient       ipc.HistoryClient
	isFallback      bool

	// Navigation
	cursor   int
	mode     mode
	filter   textinput.Model
	statusMsg string // transient status messages

	// Transform panel
	transformCursor int

	// Confirm (delete)
	confirmEntryID string

	// Terminal size
	width  int
	height int

	// Error state
	loadErr error
}

// New creates a new TUI model and issues an async entries load.
func New(client ipc.HistoryClient, fallback bool) Model {
	fi := textinput.New()
	fi.Placeholder = "filter..."
	fi.CharLimit = 100

	return Model{
		ipcClient:  client,
		isFallback: fallback,
		filter:     fi,
		width:      80,
		height:     24,
	}
}

// ─── Init ────────────────────────────────────────────────────────────────────

func (m Model) Init() tea.Cmd {
	return loadEntries(m.ipcClient)
}

func loadEntries(client ipc.HistoryClient) tea.Cmd {
	return func() tea.Msg {
		entries, err := client.List(200, 0)
		if err != nil {
			return errMsg{err}
		}
		return entriesLoadedMsg{entries}
	}
}

// ─── Update ──────────────────────────────────────────────────────────────────

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case entriesLoadedMsg:
		m.allEntries = msg.entries
		m.applyFilter()
		return m, nil

	case errMsg:
		m.loadErr = msg.err
		return m, nil

	case pinnedMsg:
		// Refresh entries after pin toggle
		m.statusMsg = fmt.Sprintf("✓ entry %s", map[bool]string{true: "pinned", false: "unpinned"}[msg.pinned])
		return m, loadEntries(m.ipcClient)

	case deletedMsg:
		m.statusMsg = "✓ entry deleted"
		return m, loadEntries(m.ipcClient)

	case transformedMsg:
		_ = copyToClipboard(msg.result)
		m.statusMsg = "✓ transform applied and copied"
		m.mode = modeNormal
		return m, nil

	case copiedMsg:
		m.statusMsg = "✓ copied to clipboard"
		return m, nil

	case tea.KeyMsg:
		return m.handleKey(msg)
	}

	// Pass to textinput in filter mode
	if m.mode == modeFilter {
		var cmd tea.Cmd
		m.filter, cmd = m.filter.Update(msg)
		m.applyFilter()
		return m, cmd
	}

	return m, nil
}

func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch m.mode {

	case modeNormal:
		return m.handleNormalKey(msg)

	case modeFilter:
		return m.handleFilterKey(msg)

	case modeTransform:
		return m.handleTransformKey(msg)

	case modeConfirm:
		return m.handleConfirmKey(msg)
	}

	return m, nil
}

func (m Model) handleNormalKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	m.statusMsg = "" // clear on any keypress

	switch msg.String() {
	case "q", "ctrl+c":
		return m, tea.Quit

	case "j", "down":
		if m.cursor < len(m.filteredEntries)-1 {
			m.cursor++
		}

	case "k", "up":
		if m.cursor > 0 {
			m.cursor--
		}

	case "/":
		m.mode = modeFilter
		m.filter.SetValue("")
		m.filter.Focus()

	case "enter":
		if e := m.selected(); e != nil {
			_ = copyToClipboard(e.Content)
			m.statusMsg = "✓ copied"
		}

	case "p":
		if e := m.selected(); e != nil {
			return m, m.togglePin(e)
		}

	case "d":
		if e := m.selected(); e != nil {
			m.mode = modeConfirm
			m.confirmEntryID = e.ID
		}

	case "t":
		if m.selected() != nil {
			m.mode = modeTransform
			m.transformCursor = 0
		}
	}

	return m, nil
}

func (m Model) handleFilterKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "enter", "esc":
		m.mode = modeNormal
		m.filter.Blur()
		if msg.String() == "esc" {
			m.filter.SetValue("")
			m.applyFilter()
		}
		return m, nil
	}

	// Let textinput handle the rest
	var cmd tea.Cmd
	m.filter, cmd = m.filter.Update(msg)
	m.applyFilter()
	return m, cmd
}

func (m Model) handleTransformKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "q":
		m.mode = modeNormal

	case "j", "down":
		if m.transformCursor < len(transforms)-1 {
			m.transformCursor++
		}

	case "k", "up":
		if m.transformCursor > 0 {
			m.transformCursor--
		}

	case "enter":
		if e := m.selected(); e != nil {
			t := transforms[m.transformCursor]
			return m, m.applyTransform(e, t)
		}
	}

	return m, nil
}

func (m Model) handleConfirmKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "d", "y":
		id := m.confirmEntryID
		m.mode = modeNormal
		m.confirmEntryID = ""
		return m, m.deleteEntry(id)

	case "esc", "n":
		m.mode = modeNormal
		m.confirmEntryID = ""
		m.statusMsg = "delete cancelled"
	}

	return m, nil
}

// ─── View ────────────────────────────────────────────────────────────────────

func (m Model) View() string {
	if m.loadErr != nil {
		return styleError.Render("Error loading history: " + m.loadErr.Error()) + "\n\nPress q to quit."
	}

	var sb strings.Builder

	// Header
	filterLabel := ""
	if m.filter.Value() != "" {
		filterLabel = styleFilter.Render(fmt.Sprintf(" (filter: %q)", m.filter.Value()))
	}
	header := fmt.Sprintf("Clipboard History — %d entries%s", len(m.filteredEntries), filterLabel)
	if m.isFallback {
		header += styleDimmed.Render("  ⚠ read-only (daemon offline)")
	}
	sb.WriteString(styleHeader.Render(header) + "\n")

	// Entry list
	visibleStart, visibleEnd := m.visibleRange()
	for i := visibleStart; i < visibleEnd; i++ {
		sb.WriteString(m.renderEntry(i) + "\n")
	}

	// Filter input bar (shown when in filter mode)
	if m.mode == modeFilter {
		sb.WriteString("\n" + styleFilter.Render("Filter: ") + m.filter.View() + "\n")
	}

	// Transform panel overlay
	if m.mode == modeTransform {
		sb.WriteString("\n" + m.renderTransformPanel())
	}

	// Confirm bar
	if m.mode == modeConfirm {
		sb.WriteString("\n" + styleError.Render("Delete this entry? Press d to confirm, Esc to cancel"))
	}

	// Status message
	if m.statusMsg != "" {
		sb.WriteString("\n" + lipgloss.NewStyle().Foreground(lipgloss.Color("10")).Render(m.statusMsg))
	}

	// Footer / keybinding hints
	if m.mode == modeNormal {
		sb.WriteString("\n" + m.renderFooter())
	}

	return sb.String()
}

func (m Model) renderEntry(i int) string {
	e := m.filteredEntries[i]

	pin := "  "
	if e.IsPinned {
		pin = stylePin.Render("📌")
	}

	icon := typeIcon(e.ContentType)
	preview := truncate(e.Preview, 60)
	source := styleDimmed.Render(e.SourceName)
	if e.SourceConfidence == "low" {
		source = styleDimmed.Render("~" + e.SourceName)
	}
	ts := styleSource.Render(relTime(e.CreatedAt))

	line := fmt.Sprintf("%s %s  %-62s  %s  %s", pin, styleType.Render(icon), preview, source, ts)

	if i == m.cursor {
		return styleSelected.Render(line)
	}
	return line
}

func (m Model) renderTransformPanel() string {
	var sb strings.Builder
	sb.WriteString("Apply transform:\n")
	for i, t := range transforms {
		line := fmt.Sprintf("  %s", t)
		if i == m.transformCursor {
			line = stylePanelSelected.Render(fmt.Sprintf("▶ %s", t))
		}
		sb.WriteString(line + "\n")
	}
	sb.WriteString(styleDimmed.Render("\nEnter: apply + copy   Esc: cancel"))
	return stylePanelBorder.Render(sb.String())
}

func (m Model) renderFooter() string {
	hints := []string{
		"j/k navigate", "/ filter", "Enter copy",
		"p pin", "d delete", "t transform", "q quit",
	}
	return styleFooter.Render(strings.Join(hints, "  ·  "))
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

func (m *Model) applyFilter() {
	q := strings.ToLower(m.filter.Value())
	if q == "" {
		m.filteredEntries = m.allEntries
		return
	}
	out := make([]ipc.Entry, 0, len(m.allEntries))
	for _, e := range m.allEntries {
		if strings.Contains(strings.ToLower(e.Preview), q) ||
			strings.Contains(strings.ToLower(e.SourceName), q) ||
			strings.Contains(strings.ToLower(e.ContentType), q) {
			out = append(out, e)
		}
	}
	m.filteredEntries = out
	if m.cursor >= len(m.filteredEntries) {
		m.cursor = max(0, len(m.filteredEntries)-1)
	}
}

func (m Model) selected() *ipc.Entry {
	if len(m.filteredEntries) == 0 || m.cursor >= len(m.filteredEntries) {
		return nil
	}
	e := m.filteredEntries[m.cursor]
	return &e
}

// visibleRange returns the slice window to render, centred on the cursor.
func (m Model) visibleRange() (int, int) {
	available := m.height - 8 // header + footer + margins
	if available < 4 {
		available = 4
	}
	n := len(m.filteredEntries)
	if n == 0 {
		return 0, 0
	}
	start := m.cursor - available/2
	if start < 0 {
		start = 0
	}
	end := start + available
	if end > n {
		end = n
		start = max(0, end-available)
	}
	return start, end
}

func (m Model) togglePin(e *ipc.Entry) tea.Cmd {
	client := m.ipcClient
	id := e.ID
	shouldPin := !e.IsPinned
	return func() tea.Msg {
		if shouldPin {
			if err := client.Pin(id); err != nil {
				return errMsg{err}
			}
		} else {
			if err := client.Unpin(id); err != nil {
				return errMsg{err}
			}
		}
		return pinnedMsg{entryID: id, pinned: shouldPin}
	}
}

func (m Model) deleteEntry(id string) tea.Cmd {
	client := m.ipcClient
	return func() tea.Msg {
		if err := client.Delete(id); err != nil {
			return errMsg{err}
		}
		return deletedMsg{entryID: id}
	}
}

func (m Model) applyTransform(e *ipc.Entry, transform string) tea.Cmd {
	client := m.ipcClient
	id := e.ID
	return func() tea.Msg {
		result, err := client.Transform(id, transform)
		if err != nil {
			return errMsg{err}
		}
		return transformedMsg{result: result}
	}
}

// ─── Utilities ───────────────────────────────────────────────────────────────

func copyToClipboard(text string) error {
	cmd := exec.Command("pbcopy")
	cmd.Stdin = strings.NewReader(text)
	return cmd.Run()
}

func typeIcon(contentType string) string {
	icons := map[string]string{
		"plain-text": "📋",
		"rich-text":  "📝",
		"url":        "🔗",
		"image":      "🖼 ",
		"file":       "📄",
		"code":       "💻",
		"colour":     "🎨",
		"email":      "✉️ ",
		"phone":      "📞",
	}
	if icon, ok := icons[contentType]; ok {
		return icon
	}
	return "📋"
}

func truncate(s string, maxRunes int) string {
	if utf8.RuneCountInString(s) <= maxRunes {
		return s
	}
	runes := []rune(s)
	return string(runes[:maxRunes-1]) + "…"
}

func relTime(ms int64) string {
	t := time.UnixMilli(ms)
	diff := time.Since(t)
	switch {
	case diff < time.Minute:
		return "just now"
	case diff < time.Hour:
		return fmt.Sprintf("%dm ago", int(diff.Minutes()))
	case diff < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(diff.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(diff.Hours()/24))
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
