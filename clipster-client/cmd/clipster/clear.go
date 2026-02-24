package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"github.com/romeo-folie/clipster/cli/internal/ipc"
	"github.com/spf13/cobra"
)

var clearForce bool

var clearCmd = &cobra.Command{
	Use:   "clear",
	Short: "Clear all non-pinned clipboard history",
	Long: `Clears all non-pinned clipboard history entries.
Pinned entries are preserved. Use --force to skip confirmation.`,
	Run: runClear,
}

func init() {
	clearCmd.Flags().BoolVarP(&clearForce, "force", "f", false, "Skip confirmation prompt")
}

func runClear(cmd *cobra.Command, args []string) {
	if !ipc.IsDaemonRunning() {
		fmt.Fprintln(os.Stderr, "clipsterd not running — this operation requires the daemon.")
		fmt.Fprintln(os.Stderr, "Run: clipster daemon start")
		os.Exit(1)
	}

	if !clearForce {
		fmt.Print("Clear all non-pinned history? This cannot be undone. [y/N] ")
		reader := bufio.NewReader(os.Stdin)
		response, err := reader.ReadString('\n')
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error reading input: %v\n", err)
			os.Exit(1)
		}
		response = strings.TrimSpace(strings.ToLower(response))
		if response != "y" && response != "yes" {
			fmt.Println("Cancelled.")
			return
		}
	}

	client, err := ipc.Dial()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	defer client.Close()

	deleted, err := client.Clear()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Cleared %d entries. Pinned entries preserved.\n", deleted)
}
