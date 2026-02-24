// Package ipc implements the clipster IPC client.
// PRD §7.6 — 4-byte big-endian length prefix + UTF-8 JSON framing.
package ipc

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"
)

const (
	ProtocolVersion = 1
	DialTimeout     = 500 * time.Millisecond
)

// SocketPath returns ~/Library/Application Support/Clipster/clipster.sock.
func SocketPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "Clipster", "clipster.sock")
}

// Command is the client → daemon envelope. PRD §7.6.
type Command struct {
	Version int    `json:"version"`
	ID      string `json:"id"`
	Command string `json:"command"`
	Params  Params `json:"params"`
}

// Params holds optional command parameters.
type Params struct {
	Limit     *int    `json:"limit,omitempty"`
	Offset    *int    `json:"offset,omitempty"`
	EntryID   *string `json:"entry_id,omitempty"`
	Transform *string `json:"transform,omitempty"`
}

// Response is the daemon → client envelope. PRD §7.6.
type Response struct {
	ProtocolVersion int              `json:"protocol_version"`
	ID              string           `json:"id"`
	OK              bool             `json:"ok"`
	Data            *json.RawMessage `json:"data"`
	Error           *string          `json:"error"`
}

// Entry is a history entry DTO matching the daemon's IPCEntry.
type Entry struct {
	ID               string `json:"id"`
	ContentType      string `json:"content_type"`
	Content          string `json:"content"`
	Preview          string `json:"preview"`
	SourceBundle     string `json:"source_bundle"`
	SourceName       string `json:"source_name"`
	SourceConfidence string `json:"source_confidence"`
	CreatedAt        int64  `json:"created_at"`
	IsPinned         bool   `json:"is_pinned"`
}

// DaemonStatus is returned by daemon_status.
type DaemonStatus struct {
	Running bool   `json:"running"`
	PID     int32  `json:"pid"`
	Version string `json:"version"`
}

// Client is a single-use IPC client connection.
type Client struct {
	conn net.Conn
}

// Dial connects to the IPC socket. Returns an error if the socket is unavailable.
// Callers should check IsDaemonRunning() before sending commands that require the daemon.
func Dial() (*Client, error) {
	conn, err := net.DialTimeout("unix", SocketPath(), DialTimeout)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	return &Client{conn: conn}, nil
}

// IsDaemonRunning checks whether the socket file exists and accepts connections.
func IsDaemonRunning() bool {
	c, err := Dial()
	if err != nil {
		return false
	}
	c.Close()
	return true
}

// Close closes the connection.
func (c *Client) Close() {
	c.conn.Close()
}

// Send sends a command and returns the parsed response.
func (c *Client) Send(cmd Command) (*Response, error) {
	body, err := json.Marshal(cmd)
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}

	// 4-byte big-endian length prefix
	frame := make([]byte, 4+len(body))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(body)))
	copy(frame[4:], body)

	if _, err := c.conn.Write(frame); err != nil {
		return nil, fmt.Errorf("write: %w", err)
	}

	// Read response length
	lenBuf := make([]byte, 4)
	if _, err := io.ReadFull(c.conn, lenBuf); err != nil {
		return nil, fmt.Errorf("read length: %w", err)
	}
	responseLen := binary.BigEndian.Uint32(lenBuf)
	if responseLen > 16*1024*1024 { // 16 MB sanity cap
		return nil, fmt.Errorf("response too large: %d bytes", responseLen)
	}

	bodyBuf := make([]byte, responseLen)
	if _, err := io.ReadFull(c.conn, bodyBuf); err != nil {
		return nil, fmt.Errorf("read body: %w", err)
	}

	var resp Response
	if err := json.Unmarshal(bodyBuf, &resp); err != nil {
		return nil, fmt.Errorf("unmarshal: %w", err)
	}

	if !resp.OK {
		errMsg := "unknown error"
		if resp.Error != nil {
			errMsg = *resp.Error
		}
		return &resp, fmt.Errorf("daemon error: %s", errMsg)
	}

	return &resp, nil
}

// List sends a list command and returns the history entries.
func (c *Client) List(limit, offset int) ([]Entry, error) {
	cmd := Command{
		Version: ProtocolVersion,
		Command: "list",
		Params:  Params{Limit: &limit, Offset: &offset},
	}
	resp, err := c.Send(cmd)
	if err != nil {
		return nil, err
	}
	var data struct {
		Entries []Entry `json:"entries"`
	}
	if err := json.Unmarshal(*resp.Data, &data); err != nil {
		return nil, fmt.Errorf("parse entries: %w", err)
	}
	return data.Entries, nil
}

// Pins sends a pins command and returns pinned entries.
func (c *Client) Pins() ([]Entry, error) {
	cmd := Command{Version: ProtocolVersion, Command: "pins"}
	resp, err := c.Send(cmd)
	if err != nil {
		return nil, err
	}
	var data struct {
		Entries []Entry `json:"entries"`
	}
	if err := json.Unmarshal(*resp.Data, &data); err != nil {
		return nil, fmt.Errorf("parse pins: %w", err)
	}
	return data.Entries, nil
}

// Last sends a last command and returns the most recent entry.
func (c *Client) Last() (*Entry, error) {
	cmd := Command{Version: ProtocolVersion, Command: "last"}
	resp, err := c.Send(cmd)
	if err != nil {
		return nil, err
	}
	var data struct {
		Entry Entry `json:"entry"`
	}
	if err := json.Unmarshal(*resp.Data, &data); err != nil {
		return nil, fmt.Errorf("parse entry: %w", err)
	}
	return &data.Entry, nil
}

// DaemonStatus sends a daemon_status command.
func (c *Client) DaemonStatus() (*DaemonStatus, error) {
	cmd := Command{Version: ProtocolVersion, Command: "daemon_status"}
	resp, err := c.Send(cmd)
	if err != nil {
		return nil, err
	}
	var status DaemonStatus
	if err := json.Unmarshal(*resp.Data, &status); err != nil {
		return nil, fmt.Errorf("parse status: %w", err)
	}
	return &status, nil
}

// Pin sends a pin command for the given entry ID.
func (c *Client) Pin(entryID string) error {
	cmd := Command{
		Version: ProtocolVersion,
		Command: "pin",
		Params:  Params{EntryID: &entryID},
	}
	_, err := c.Send(cmd)
	return err
}

// Unpin sends an unpin command for the given entry ID.
func (c *Client) Unpin(entryID string) error {
	cmd := Command{
		Version: ProtocolVersion,
		Command: "unpin",
		Params:  Params{EntryID: &entryID},
	}
	_, err := c.Send(cmd)
	return err
}

// Delete sends a delete command for the given entry ID.
func (c *Client) Delete(entryID string) error {
	cmd := Command{
		Version: ProtocolVersion,
		Command: "delete",
		Params:  Params{EntryID: &entryID},
	}
	_, err := c.Send(cmd)
	return err
}

// Transform applies a named transform to an entry and returns the result.
func (c *Client) Transform(entryID, transform string) (string, error) {
	cmd := Command{
		Version: ProtocolVersion,
		Command: "transform",
		Params:  Params{EntryID: &entryID, Transform: &transform},
	}
	resp, err := c.Send(cmd)
	if err != nil {
		return "", err
	}
	var data struct {
		Result string `json:"result"`
	}
	if err := json.Unmarshal(*resp.Data, &data); err != nil {
		return "", fmt.Errorf("parse transform result: %w", err)
	}
	return data.Result, nil
}

// Clear sends a clear command to delete all non-pinned history entries.
// Returns the count of deleted entries.
func (c *Client) Clear() (int, error) {
	cmd := Command{Version: ProtocolVersion, Command: "clear"}
	resp, err := c.Send(cmd)
	if err != nil {
		return 0, err
	}
	var data struct {
		Deleted int `json:"deleted"`
	}
	if err := json.Unmarshal(*resp.Data, &data); err != nil {
		return 0, fmt.Errorf("parse clear result: %w", err)
	}
	return data.Deleted, nil
}
