package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"
)

const defaultConfig = `[history]
entry_limit = 500
db_size_cap_mb = 500

[privacy]
suppress_bundles = [
  "com.1password.1password",
  "com.bitwarden.desktop",
  "com.dashlane.dashlane",
  "com.lastpass.LastPass",
]

[daemon]
log_level = "info"
`

var (
	configEdit  bool
	configReset bool
)

var configCmd = &cobra.Command{
	Use:   "config",
	Short: "View or edit Clipster configuration",
	Long: `Display the current Clipster configuration.

  clipster config          — print resolved config + path
  clipster config --edit   — open in $EDITOR (created with defaults if absent)
  clipster config --reset  — overwrite with defaults (after confirmation)`,
	Run: runConfig,
}

func init() {
	configCmd.Flags().BoolVarP(&configEdit, "edit", "e", false, "Open config in $EDITOR")
	configCmd.Flags().BoolVarP(&configReset, "reset", "r", false, "Reset config to defaults")
}

func configPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "clipster", "config.toml")
}

func runConfig(cmd *cobra.Command, args []string) {
	path := configPath()

	if configReset {
		fmt.Printf("Overwrite %s with defaults? [y/N] ", path)
		reader := bufio.NewReader(os.Stdin)
		resp, _ := reader.ReadString('\n')
		if strings.TrimSpace(strings.ToLower(resp)) != "y" {
			fmt.Println("Cancelled.")
			return
		}
		if err := writeDefault(path); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Config reset to defaults: %s\n", path)
		return
	}

	// Ensure config exists with defaults
	if _, err := os.Stat(path); os.IsNotExist(err) {
		if err := writeDefault(path); err != nil {
			fmt.Fprintf(os.Stderr, "Error creating config: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Created default config: %s\n\n", path)
	}

	if configEdit {
		editor := os.Getenv("EDITOR")
		if editor == "" {
			editor = "nano"
		}
		c := exec.Command(editor, path)
		c.Stdin = os.Stdin
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		if err := c.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "Editor error: %v\n", err)
			os.Exit(1)
		}
		return
	}

	// Print config path + contents
	fmt.Printf("Config: %s\n\n", path)
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading config: %v\n", err)
		os.Exit(1)
	}
	fmt.Println(string(data))
}

func writeDefault(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(defaultConfig), 0o644)
}
