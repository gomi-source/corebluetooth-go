package ble

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
)

// rpcRequest / rpcResponse / rpcNotification implement the small
// JSON-RPC 2.0-ish envelope described in PROTOCOL.md: newline-delimited
// JSON, requests carry an id and get a matching response, notifications
// (server -> client only, here) carry no id.

type rpcRequest struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      int64       `json:"id"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.Number     `json:"id"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *rpcError) Error() string {
	return fmt.Sprintf("corebluetoothd: rpc error %d: %s", e.Code, e.Message)
}

type rpcNotification struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

// sniff is used to cheaply decide whether an incoming line is a response
// (has "id") or a notification (has "method", no "id") before doing the
// full decode.
type sniff struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
}

// conn is the low-level JSON-RPC client bound to one Unix socket
// connection to a corebluetoothd process.
type conn struct {
	nc      net.Conn
	writeMu sync.Mutex
	nextID  int64

	pendingMu sync.Mutex
	pending   map[int64]chan rpcResponse

	onNotification func(method string, params json.RawMessage)
	onReadError    func(error)
}

func newConn(nc net.Conn, onNotification func(string, json.RawMessage), onReadError func(error)) *conn {
	c := &conn{
		nc:             nc,
		pending:        make(map[int64]chan rpcResponse),
		onNotification: onNotification,
		onReadError:    onReadError,
	}
	go c.readLoop()
	return c
}

func (c *conn) readLoop() {
	scanner := bufio.NewScanner(c.nc)
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		// Bytes() re-uses its buffer on the next Scan(), so copy before
		// handing it off to anything that might outlive this iteration.
		lineCopy := append([]byte(nil), line...)

		var s sniff
		if err := json.Unmarshal(lineCopy, &s); err != nil {
			continue
		}

		if s.Method != "" && len(s.ID) == 0 {
			var note rpcNotification
			if err := json.Unmarshal(lineCopy, &note); err == nil {
				c.onNotification(note.Method, note.Params)
			}
			continue
		}

		var resp rpcResponse
		if err := json.Unmarshal(lineCopy, &resp); err != nil {
			continue
		}
		id, err := resp.ID.Int64()
		if err != nil {
			continue
		}
		c.pendingMu.Lock()
		ch, ok := c.pending[id]
		if ok {
			delete(c.pending, id)
		}
		c.pendingMu.Unlock()
		if ok {
			ch <- resp
		}
	}

	err := scanner.Err()
	if err == nil {
		err = io.EOF
	}
	c.onReadError(err)

	// Nothing will ever answer these now; fail them so callers blocked in
	// call() don't hang forever.
	c.pendingMu.Lock()
	pending := c.pending
	c.pending = make(map[int64]chan rpcResponse)
	c.pendingMu.Unlock()
	for _, ch := range pending {
		ch <- rpcResponse{Error: &rpcError{Code: -1, Message: fmt.Sprintf("connection closed: %v", err)}}
	}
}

// call sends a request and blocks until a matching response arrives, the
// context is done, or the connection dies. Pass a nil result to ignore the
// response payload (e.g. for calls that only return an empty object).
func (c *conn) call(ctx context.Context, method string, params interface{}, result interface{}) error {
	id := atomic.AddInt64(&c.nextID, 1)
	req := rpcRequest{JSONRPC: "2.0", ID: id, Method: method, Params: params}

	payload, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("corebluetoothd: encoding request: %w", err)
	}
	payload = append(payload, '\n')

	respCh := make(chan rpcResponse, 1)
	c.pendingMu.Lock()
	c.pending[id] = respCh
	c.pendingMu.Unlock()

	c.writeMu.Lock()
	_, writeErr := c.nc.Write(payload)
	c.writeMu.Unlock()
	if writeErr != nil {
		c.pendingMu.Lock()
		delete(c.pending, id)
		c.pendingMu.Unlock()
		return fmt.Errorf("corebluetoothd: writing request: %w", writeErr)
	}

	select {
	case resp := <-respCh:
		if resp.Error != nil {
			return resp.Error
		}
		if result != nil && len(resp.Result) > 0 {
			return json.Unmarshal(resp.Result, result)
		}
		return nil
	case <-ctx.Done():
		c.pendingMu.Lock()
		delete(c.pending, id)
		c.pendingMu.Unlock()
		return ctx.Err()
	}
}
