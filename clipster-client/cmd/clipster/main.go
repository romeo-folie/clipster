package main

import (
	"fmt"
	"os"

	"github.com/romeo-folie/clipster/cli/internal/db"
	"github.com/romeo-folie/clipster/cli/internal/format"
	"github.com/romeo-folie/clipster/cli/internal/ipc"
	"github.com/spf13/cobra"
)

var rootCmd = &cobra.Command{
	Use:   "clipster",
	Short: "Clipster CLI — terminal clipboard manager",
	Long: `Clipster is a terminal-native clipboard manager for macOS.
It connects to the clipsterd daemon or reads directly from history.db.`,
	Run: func(cmd *cobra.Command, args []string) {
		// Default behavior: list entries (TUI in Phase 2)
		// For Phase 1, just run list command logic
		runList(cmd, args)
	},
}

func main() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// runList implements the `clipster list` logic (also default)
func runList(cmd *cobra.Command, args []string) {
	// Try daemon first
	if ipc.IsDaemonRunning() {
		client, err := ipc.Dial()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error connecting to daemon: %v\n", err)
			return
		}
		defer client.Close()

		entries, err := client.List(20, 0) // Default limit 20
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error listing entries: %v\n", err)
			return
		}

		for i, e := range entries {
			fmt.Println(format.EntryLine(i+1, e.ContentType, e.Preview, e.SourceName, e.CreatedAt, e.IsPinned))
		}
		return
	}

	// Fallback to SQLite
	fmt.Fprintln(os.Stderr, format.FallbackBanner())
	reader, err := db.Open()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error opening database: %v\n", err)
		return
	}
	defer reader.Close()

	entries, err := reader.List(20, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading database: %v\n", err)
		return
	}

	for i, e := range entries {
		fmt.Println(format.EntryLine(i+1, e.ContentType, e.Preview.String, e.SourceName.String, e.CreatedAt, e.IsPinned))
	}
}
