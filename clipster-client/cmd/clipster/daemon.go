package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/romeo-folie/clipster/cli/internal/ipc"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(daemonCmd)
	daemonCmd.AddCommand(daemonStatusCmd)
	daemonCmd.AddCommand(daemonStartCmd)
	daemonCmd.AddCommand(daemonStopCmd)
	daemonCmd.AddCommand(daemonRestartCmd)
}

var daemonCmd = &cobra.Command{
	Use:   "daemon",
	Short: "Manage the clipsterd daemon",
}

// ─── status ──────────────────────────────────────────────────────────────────

var daemonStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show daemon status",
	Run: func(cmd *cobra.Command, args []string) {
		if !ipc.IsDaemonRunning() {
			fmt.Println("clipsterd: not running")
			return
		}

		client, err := ipc.Dial()
		if err != nil {
			fmt.Println("clipsterd: not running (socket exists but connect failed)")
			return
		}
		defer client.Close()

		status, err := client.DaemonStatus()
		if err != nil {
			fmt.Printf("clipsterd: running (PID unknown — %v)\n", err)
			return
		}

		uptime := uptimeFromLaunchctl()
		fmt.Printf("clipsterd: running\n  PID:     %d\n  Version: %s\n  Uptime:  %s\n",
			status.PID, status.Version, uptime)
	},
}

// ─── start ───────────────────────────────────────────────────────────────────

var daemonStartCmd = &cobra.Command{
	Use:   "start",
	Short: "Start the clipsterd daemon",
	Run: func(cmd *cobra.Command, args []string) {
		if ipc.IsDaemonRunning() {
			fmt.Println("clipsterd is already running.")
			return
		}

		plistPath := launchAgentPlist()
		uid := strconv.Itoa(os.Getuid())

		out, err := exec.Command("launchctl", "bootstrap", "gui/"+uid, plistPath).CombinedOutput()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to start daemon: %v\n%s\n", err, out)
			return
		}

		// Wait up to 5s for socket to appear
		for i := 0; i < 10; i++ {
			time.Sleep(500 * time.Millisecond)
			if ipc.IsDaemonRunning() {
				fmt.Println("clipsterd started.")
				return
			}
		}
		fmt.Fprintln(os.Stderr, "Daemon started but socket not ready within 5s — check: tail /tmp/clipsterd.log")
	},
}

// ─── stop ────────────────────────────────────────────────────────────────────

var daemonStopCmd = &cobra.Command{
	Use:   "stop",
	Short: "Stop the clipsterd daemon",
	Run: func(cmd *cobra.Command, args []string) {
		plistPath := launchAgentPlist()
		uid := strconv.Itoa(os.Getuid())

		out, err := exec.Command("launchctl", "bootout", "gui/"+uid, plistPath).CombinedOutput()
		if err != nil {
			// bootout can fail if already stopped — treat as non-fatal
			fmt.Fprintf(os.Stderr, "Warning: %v\n%s\n", err, out)
		}

		// Wait up to 3s for socket to disappear
		for i := 0; i < 6; i++ {
			time.Sleep(500 * time.Millisecond)
			if !ipc.IsDaemonRunning() {
				fmt.Println("clipsterd stopped.")
				return
			}
		}
		fmt.Println("clipsterd stop requested.")
	},
}

// ─── restart ─────────────────────────────────────────────────────────────────

var daemonRestartCmd = &cobra.Command{
	Use:   "restart",
	Short: "Restart the clipsterd daemon",
	Run: func(cmd *cobra.Command, args []string) {
		daemonStopCmd.Run(cmd, args)
		time.Sleep(500 * time.Millisecond)
		daemonStartCmd.Run(cmd, args)
	},
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

func launchAgentPlist() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", "com.clipster.daemon.plist")
}

func uptimeFromLaunchctl() string {
	out, err := exec.Command("launchctl", "list", "com.clipster.daemon").Output()
	if err != nil {
		return "unknown"
	}
	// Look for "TimeOut" or parse the PID for uptime — launchctl list doesn't give uptime directly.
	// Fall back to reporting the PID from launchctl.
	for _, line := range strings.Split(string(out), "\n") {
		if strings.Contains(line, "PID") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				return fmt.Sprintf("PID %s (uptime not available via launchctl)", parts[1])
			}
		}
	}
	return "running"
}
