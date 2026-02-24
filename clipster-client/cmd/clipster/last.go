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
	rootCmd.AddCommand(lastCmd)
}

var lastCmd = &cobra.Command{
	Use:   "last",
	Short: "Print the most recent clipboard entry",
	Run: func(cmd *cobra.Command, args []string) {
		if ipc.IsDaemonRunning() {
			client, err := ipc.Dial()
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error connecting to daemon: %v\n", err)
				return
			}
			defer client.Close()

			entry, err := client.Last()
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error: %v\n", err)
				return
			}
			fmt.Println(format.EntryDetail(
				entry.ContentType, entry.Content,
				entry.SourceName, entry.SourceConfidence, entry.CreatedAt,
			))
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

		entry, err := reader.Latest()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			return
		}
		if entry == nil {
			fmt.Println("History is empty.")
			return
		}
		fmt.Println(format.EntryDetail(
			entry.ContentType, entry.Content,
			entry.SourceName.String, entry.SourceConfidence, entry.CreatedAt,
		))
	},
}
