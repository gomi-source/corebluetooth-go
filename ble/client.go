// Package ble lets a Go program drive macOS CoreBluetooth without cgo.
//
// It works by spawning a small Swift helper process (corebluetoothd, built
// from ../../helper) that owns the actual CBCentralManager, and talking to
// it over a Unix domain socket using a line-delimited JSON-RPC 2.0
// protocol (see ../../PROTOCOL.md). Every call in this package is a plain
// net.Conn round trip - no cgo, no linking against CoreBluetooth.
package ble

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

// Options configures Start.
type Options struct {
	// HelperPath is the path to the corebluetoothd binary. If empty, Start
	// looks for a "corebluetoothd" binary next to the running executable,
	// then on $PATH.
	HelperPath string
	// SocketDir overrides where the Unix socket is created. Defaults to
	// os.TempDir().
	SocketDir string
	// StartTimeout bounds how long Start waits for the helper to report
	// ready and for the socket to accept connections. Defaults to 10s.
	StartTimeout time.Duration
	// Stderr, if set, receives the helper process's stderr. Useful for
	// diagnosing CoreBluetooth permission / power-state issues.
	Stderr io.Writer
}

// Client is a connection to one running corebluetoothd helper process.
type Client struct {
	cmd        *exec.Cmd
	conn       *conn
	socketPath string

	discoveries   chan DiscoveredPeripheral
	notifications chan CharacteristicUpdate
	disconnects   chan Disconnection
	stateChanges  chan State
	errors        chan error
}

// Start spawns the corebluetoothd helper, waits for it to become ready,
// and connects to it. The returned Client owns the child process; call
// Close when done to terminate it and clean up the socket file.
func Start(ctx context.Context, opts Options) (*Client, error) {
	if runtime.GOOS != "darwin" {
		return nil, fmt.Errorf("corebluetoothd: CoreBluetooth is only available on macOS (GOOS=%s)", runtime.GOOS)
	}

	helperPath, err := resolveHelperPath(opts.HelperPath)
	if err != nil {
		return nil, err
	}

	socketDir := opts.SocketDir
	if socketDir == "" {
		socketDir = os.TempDir()
	}
	socketPath := filepath.Join(socketDir, fmt.Sprintf("corebluetoothd-%d.sock", os.Getpid()))
	_ = os.Remove(socketPath) // best-effort cleanup of a stale socket from a previous crashed run

	startTimeout := opts.StartTimeout
	if startTimeout <= 0 {
		startTimeout = 10 * time.Second
	}

	cmd := exec.Command(helperPath,
		"--socket", socketPath,
		"--parent-pid", fmt.Sprintf("%d", os.Getpid()),
	)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("corebluetoothd: creating stdout pipe: %w", err)
	}
	if opts.Stderr != nil {
		cmd.Stderr = opts.Stderr
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("corebluetoothd: starting helper at %q: %w", helperPath, err)
	}

	if err := waitForReady(stdout, startTimeout); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, err
	}

	dialCtx, cancel := context.WithTimeout(ctx, startTimeout)
	defer cancel()
	nc, err := dialWithRetry(dialCtx, socketPath)
	if err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, err
	}

	c := &Client{
		cmd:           cmd,
		socketPath:    socketPath,
		discoveries:   make(chan DiscoveredPeripheral, 256),
		notifications: make(chan CharacteristicUpdate, 256),
		disconnects:   make(chan Disconnection, 32),
		stateChanges:  make(chan State, 16),
		errors:        make(chan error, 32),
	}
	c.conn = newConn(nc, c.handleNotification, c.handleReadError)
	return c, nil
}

// waitForReady reads the helper's stdout until it prints the "READY ..."
// line written by main.swift, then keeps draining stdout in the
// background so the child process never blocks on a full pipe.
func waitForReady(stdout io.ReadCloser, timeout time.Duration) error {
	ready := make(chan error, 1)
	scanner := bufio.NewScanner(stdout)

	go func() {
		for scanner.Scan() {
			if strings.HasPrefix(scanner.Text(), "READY") {
				ready <- nil
				for scanner.Scan() {
					// drain
				}
				// Nothing left to report to: Start has already returned
				// successfully by the time we get here, and this
				// goroutine's only remaining job was to keep draining
				// stdout so the helper never blocks on a full pipe. A
				// non-nil scanner.Err() here just means that stopped
				// (helper exited, pipe closed), which is expected.
				return
			}
		}
		if err := scanner.Err(); err != nil {
			ready <- fmt.Errorf("corebluetoothd: reading helper stdout: %w", err)
			return
		}
		ready <- fmt.Errorf("corebluetoothd: helper exited before signaling ready")
	}()

	select {
	case err := <-ready:
		return err
	case <-time.After(timeout):
		return fmt.Errorf("corebluetoothd: timed out waiting for helper to become ready")
	}
}

func dialWithRetry(ctx context.Context, path string) (net.Conn, error) {
	var lastErr error
	var dialer net.Dialer
	for {
		nc, err := dialer.DialContext(ctx, "unix", path)
		if err == nil {
			return nc, nil
		}
		lastErr = err
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("corebluetoothd: connecting to %s: %w (last dial error: %v)", path, ctx.Err(), lastErr)
		case <-time.After(20 * time.Millisecond):
		}
	}
}

// bundledHelperRelPath is where `make helper` packages the built binary:
// a minimal .app bundle, not a bare Mach-O file. This isn't cosmetic -
// modern macOS ties CoreBluetooth's privacy authorization to a bundle
// identity read from Info.plist, and a bare, un-bundled binary gets
// silently SIGKILLed the moment it touches CBCentralManager instead of
// just being denied. See helper/Info.plist and README.md.
var bundledHelperRelPath = filepath.Join("corebluetoothd.app", "Contents", "MacOS", "corebluetoothd")

func resolveHelperPath(explicit string) (string, error) {
	if explicit != "" {
		if _, err := os.Stat(explicit); err != nil {
			return "", fmt.Errorf("corebluetoothd: helper not found at %q: %w", explicit, err)
		}
		return explicit, nil
	}
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		if bundled := filepath.Join(dir, bundledHelperRelPath); fileExists(bundled) {
			return bundled, nil
		}
		// Fall back to a bare binary next to the Go executable. This will
		// run, but macOS will kill it as soon as it touches CoreBluetooth -
		// kept only so a custom packaging setup that already handles bundle
		// identity another way (e.g. embeds this in its own .app) still
		// works via a plain sibling binary.
		if bare := filepath.Join(dir, "corebluetoothd"); fileExists(bare) {
			return bare, nil
		}
	}
	// exec.LookPath only searches $PATH for a bare name (a name containing
	// a slash is used as-is, relative to the cwd, which isn't useful here),
	// so only the bare fallback binary can meaningfully live on $PATH.
	if p, err := exec.LookPath("corebluetoothd"); err == nil {
		return p, nil
	}
	return "", errors.New("corebluetoothd: helper not found; build it with `make helper` (see helper/), which packages it " +
		"as corebluetoothd.app - place that bundle next to your Go binary, put it on $PATH, or set ble.Options.HelperPath " +
		"to .../corebluetoothd.app/Contents/MacOS/corebluetoothd")
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// handleNotification decodes a JSON-RPC notification pushed by the helper
// and routes it onto the appropriate typed channel. See PROTOCOL.md for
// the full event list.
func (c *Client) handleNotification(method string, params json.RawMessage) {
	switch method {
	case "event.peripheralDiscovered":
		var p DiscoveredPeripheral
		if err := json.Unmarshal(params, &p); err == nil {
			trySend(c.discoveries, p)
		}

	case "event.characteristicValueUpdated":
		var u CharacteristicUpdate
		if err := json.Unmarshal(params, &u); err == nil {
			trySend(c.notifications, u)
		}

	case "event.peripheralDisconnected":
		var d struct {
			PeripheralID string  `json:"peripheralId"`
			ErrorMessage *string `json:"errorMessage"`
		}
		if err := json.Unmarshal(params, &d); err == nil {
			var e error
			if d.ErrorMessage != nil {
				e = errors.New(*d.ErrorMessage)
			}
			trySend(c.disconnects, Disconnection{PeripheralID: d.PeripheralID, Err: e})
		}

	case "event.stateChanged":
		var s struct {
			State State `json:"state"`
		}
		if err := json.Unmarshal(params, &s); err == nil {
			trySend(c.stateChanges, s.State)
		}

	case "event.error":
		var e struct {
			Message string `json:"message"`
		}
		if err := json.Unmarshal(params, &e); err == nil {
			trySend(c.errors, errors.New(e.Message))
		}

	// event.peripheralConnected / event.peripheralConnectFailed are
	// intentionally not surfaced here: Connect() already resolves (with
	// the same success/error information) from the matching RPC response.
	default:
	}
}

func (c *Client) handleReadError(err error) {
	if err != nil && err != io.EOF {
		trySend(c.errors, fmt.Errorf("corebluetoothd: connection lost: %w", err))
	}
}

// trySend delivers v on ch without blocking. If the consumer isn't keeping
// up and the buffer is full, the event is dropped rather than blocking the
// single reader goroutine that also resolves pending RPC calls - blocking
// there would deadlock every in-flight call.
func trySend[T any](ch chan T, v T) {
	select {
	case ch <- v:
	default:
	}
}

// Discoveries delivers a value for every advertisement CoreBluetooth
// reports while a scan (StartScan) is active.
func (c *Client) Discoveries() <-chan DiscoveredPeripheral { return c.discoveries }

// Notifications delivers a value whenever a characteristic subscribed via
// SetNotify pushes a new value.
func (c *Client) Notifications() <-chan CharacteristicUpdate { return c.notifications }

// Disconnections delivers a value whenever a peripheral disconnects,
// whether requested (via Disconnect) or not.
func (c *Client) Disconnections() <-chan Disconnection { return c.disconnects }

// StateChanges delivers the adapter's CBManagerState whenever it changes
// (e.g. the user toggles Bluetooth off, or an authorization prompt is
// resolved).
func (c *Client) StateChanges() <-chan State { return c.stateChanges }

// Errors delivers asynchronous errors that aren't tied to any single
// pending call (e.g. a characteristic update that arrived with an error,
// or the helper connection being lost).
func (c *Client) Errors() <-chan error { return c.errors }

// Close terminates the helper process and removes the socket file. The
// Client must not be used afterwards.
func (c *Client) Close() error {
	closeErr := c.conn.nc.Close()

	if c.cmd.Process != nil {
		_ = c.cmd.Process.Signal(syscall.SIGTERM)
		done := make(chan struct{})
		go func() {
			_ = c.cmd.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			_ = c.cmd.Process.Kill()
			<-done
		}
	}

	_ = os.Remove(c.socketPath)
	return closeErr
}
