package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/romeo-folie/clipster/cli/internal/db"
	"github.com/romeo-folie/clipster/cli/internal/format"
	"github.com/romeo-folie/clipster/cli/internal/ipc"
	"github.com/romeo-folie/clipster/cli/internal/tui"
	"github.com/spf13/cobra"
)

var rootCmd = &cobra.Command{
	Use:   "clipster",
	Short: "Clipster CLI — terminal clipboard manager",
	Long: `Clipster is a terminal-native clipboard manager for macOS.

Run without arguments to open the interactive TUI.
Connects to the clipsterd daemon or reads directly from history.db in fallback mode.`,
	Run: func(cmd *cobra.Command, args []string) {
		launchTUI()
	},
}

func main() {
	rootCmd.AddCommand(listCmd, lastCmd, pinsCmd, clearCmd, configCmd, daemonCmd)
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// launchTUI opens the Bubble Tea TUI. Falls back to read-only mode if daemon is offline.
func launchTUI() {
	var client ipc.HistoryClient
	fallback := false

	if ipc.IsDaemonRunning() {
		c, err := ipc.Dial()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error connecting to daemon: %v\n", err)
			os.Exit(1)
		}
		client = c
	} else {
		fallback = true
		var err error
		client, err = ipc.NewFallbackClient()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error opening history database: %v\n", err)
			os.Exit(1)
		}
	}
	defer client.Close()

	m := tui.New(client, fallback)
	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "TUI error: %v\n", err)
		os.Exit(1)
	}
}

// listCmd — plain text list (non-TUI).
var listCmd = &cobra.Command{
	Use:   "list",
	Short: "List clipboard history (plain text)",
	Run:   runList,
}

func runList(cmd *cobra.Command, args []string) {
	if ipc.IsDaemonRunning() {
		client, err := ipc.Dial()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			return
		}
		defer client.Close()
		entries, err := client.List(20, 0)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			return
		}
		for i, e := range entries {
			fmt.Println(format.EntryLine(i+1, e.ContentType, e.Preview, e.SourceName, e.CreatedAt, e.IsPinned))
		}
		return
	}

	fmt.Fprintln(os.Stderr, format.FallbackBanner())
	reader, err := db.Open()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		return
	}
	defer reader.Close()
	entries, err := reader.List(20, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		return
	}
	for i, e := range entries {
		fmt.Println(format.EntryLine(i+1, e.ContentType, e.Preview.String, e.SourceName.String, e.CreatedAt, e.IsPinned))
	}
}
