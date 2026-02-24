package main

import (
	"fmt"
	"os"

	"github.com/romeo-folie/clipster/cli/internal/db"
	"github.com/romeo-folie/clipster/cli/internal/format"
	"github.com/romeo-folie/clipster/cli/internal/ipc"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(pinsCmd)
}

var pinsCmd = &cobra.Command{
	Use:   "pins",
	Short: "List pinned clipboard entries",
	Run: func(cmd *cobra.Command, args []string) {
		if ipc.IsDaemonRunning() {
			client, err := ipc.Dial()
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error connecting to daemon: %v\n", err)
				return
			}
			defer client.Close()

			entries, err := client.Pins()
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: %v\n", err)
				return
			}
			if len(entries) == 0 {
				fmt.Println("No pinned entries.")
				return
			}
			for i, e := range entries {
				fmt.Println(format.EntryLine(i+1, e.ContentType, e.Preview, e.SourceName, e.CreatedAt, true))
			}
			return
		}

		// Fallback
		fmt.Fprintln(os.Stderr, format.FallbackBanner())
		reader, err := db.Open()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			return
		}
		defer reader.Close()

		entries, err := reader.Pins()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			return
		}
		if len(entries) == 0 {
			fmt.Println("No pinned entries.")
			return
		}
		for i, e := range entries {
			fmt.Println(format.EntryLine(i+1, e.ContentType, e.Preview.String, e.SourceName.String, e.CreatedAt, true))
		}
	},
}
