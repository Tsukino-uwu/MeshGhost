// Package driver is the core's side of the driver link: a loopback TCP listener that accepts ONE
// driver at a time — the small piece inside an emulator or game that carries out commands — and
// turns its newline-delimited JSON into request/response calls and a buffer of events.
//
// It is game-blind: it never reads a payload, only routes it. What a driver can do is whatever
// its hello says, and every name in a payload (a mode, a map, an event kind) is opaque here.
//
// The wire (protocol 1), one JSON object per line, at most MaxLineBytes:
//
//	driver -> core  {"type":"hello","payload":Hello}                 first line, within HelloTimeout
//	core -> driver  {"type":"welcome","payload":{"protocol":1}}      or {"type":"reject","payload":{"reason":"..."}}, then close
//	core -> driver  {"id":N,"type":"<verb>","payload":{...}}         a request
//	driver -> core  {"id":N,"type":"result","payload":{...}}         or {"id":N,"type":"error","payload":{"message":"..."}}
//	driver -> core  {"type":"event","payload":{"kind":"...",...}}    unsolicited, buffered by the hub
//
// A hello's "persisting", and a cheat's answer carrying the same field, list the cheats still in effect
// in the game (a noclip left on): the only payload field the core reads, so a run segment begun while
// one is on is not labelled walked.
package driver

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

// Protocol is the link version a driver must say in its hello.
const Protocol = 1

// MaxLineBytes caps one line in either direction, the same cap the MeshGhost bridge uses.
const MaxLineBytes = 64 * 1024

// HelloTimeout is how long a new connection has to send its hello.
const HelloTimeout = 5 * time.Second

// EventBuffer is how many of the newest events the hub keeps.
const EventBuffer = 512

// Hello is what a driver says about itself on connect.
type Hello struct {
	Protocol       int      `json:"protocol"`
	Host           string   `json:"host"`
	Game           string   `json:"game"`
	Variant        string   `json:"variant,omitempty"`
	Build          string   `json:"build,omitempty"`
	Capabilities   []string `json:"capabilities"`
	ProtectedSlots []int    `json:"protected_slots,omitempty"`
	// Persisting lists the cheat kinds in effect when the driver connected (package comment).
	Persisting Kinds `json:"persisting,omitempty"`
}

// Kinds is a list of cheat kinds as a driver sends it. A Lua driver's JSON cannot tell an empty array from an
// empty object, so {} reads as no kinds, the same as [].
type Kinds []string

// UnmarshalJSON takes an array of strings, or an empty object.
func (k *Kinds) UnmarshalJSON(b []byte) error {
	if len(b) > 0 && b[0] == '{' {
		var m map[string]json.RawMessage
		if err := json.Unmarshal(b, &m); err != nil {
			return err
		}
		if len(m) != 0 {
			return fmt.Errorf("a list of cheat kinds is an array, got an object with %d keys", len(m))
		}
		*k = nil
		return nil
	}
	var s []string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	*k = s
	return nil
}

// Has reports whether the driver announced a capability.
func (h Hello) Has(capability string) bool {
	for _, c := range h.Capabilities {
		if c == capability {
			return true
		}
	}
	return false
}

// Event is one unsolicited driver message, numbered by the hub in arrival order.
type Event struct {
	Seq     uint64          `json:"seq"`
	At      time.Time       `json:"at"`
	Payload json.RawMessage `json:"payload"`
}

// ErrNoDriver is returned by Call when no driver is connected.
var ErrNoDriver = errors.New("no driver is connected")

// ErrDisconnected is returned by Call when the driver went away before answering.
var ErrDisconnected = errors.New("the driver disconnected before answering")

type envelope struct {
	ID      uint64          `json:"id,omitempty"`
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload,omitempty"`
}

type reply struct {
	payload json.RawMessage
	err     error
}

type conn struct {
	nc      net.Conn
	hello   Hello
	gen     uint64
	writeMu sync.Mutex
	done    chan struct{}
}

// Hub accepts driver connections on a loopback address and serves one at a time.
type Hub struct {
	ln  net.Listener
	log *log.Logger

	mu      sync.Mutex
	cur     *conn
	nextID  uint64
	pending map[uint64]chan reply
	events  []Event
	nextSeq uint64
	gen     uint64 // counts accepted drivers, so a caller can tell a reconnect from the same driver
}

// Listen binds addr, which must be a loopback address: a driver is a local process, and nothing
// off this machine may reach it.
func Listen(addr string, logger *log.Logger) (*Hub, error) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, fmt.Errorf("listen address %q: %w", addr, err)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return nil, fmt.Errorf("listen address %q is not a loopback IP; the driver link is local only", addr)
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	if logger == nil {
		logger = log.New(io.Discard, "", 0)
	}
	return &Hub{ln: ln, log: logger, pending: map[uint64]chan reply{}}, nil
}

// Addr is the address the hub is listening on.
func (h *Hub) Addr() net.Addr { return h.ln.Addr() }

// Close stops accepting and drops the current driver.
func (h *Hub) Close() error {
	err := h.ln.Close()
	h.mu.Lock()
	c := h.cur
	h.mu.Unlock()
	if c != nil {
		c.nc.Close()
	}
	return err
}

// Serve accepts drivers until the listener closes or ctx ends.
func (h *Hub) Serve(ctx context.Context) error {
	go func() {
		<-ctx.Done()
		h.Close()
	}()
	for {
		nc, err := h.ln.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go h.handle(nc)
	}
}

// Current returns the connected driver's hello.
func (h *Hub) Current() (Hello, bool) {
	hello, _, ok := h.CurrentConnection()
	return hello, ok
}

// CurrentConnection returns the connected driver's hello and its generation: every driver the hub
// accepts gets the next number, so the same number means the same connection.
func (h *Hub) CurrentConnection() (Hello, uint64, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.cur == nil {
		return Hello{}, 0, false
	}
	return h.cur.hello, h.cur.gen, true
}

// EventsSince returns buffered events with Seq > since, oldest first, and the newest Seq seen.
func (h *Hub) EventsSince(since uint64) ([]Event, uint64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []Event
	for _, e := range h.events {
		if e.Seq > since {
			out = append(out, e)
		}
	}
	return out, h.nextSeq
}

// Call sends a request of type verb to the driver and waits for its answer, ctx's end, or the
// driver leaving. A driver's own error comes back as an error carrying its message.
func (h *Hub) Call(ctx context.Context, verb string, payload any) (json.RawMessage, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("encode %s payload: %w", verb, err)
	}
	h.mu.Lock()
	c := h.cur
	if c == nil {
		h.mu.Unlock()
		return nil, ErrNoDriver
	}
	h.nextID++
	id := h.nextID
	ch := make(chan reply, 1)
	h.pending[id] = ch
	h.mu.Unlock()

	defer func() {
		h.mu.Lock()
		delete(h.pending, id)
		h.mu.Unlock()
	}()

	if err := c.send(envelope{ID: id, Type: verb, Payload: body}); err != nil {
		return nil, fmt.Errorf("send %s: %w", verb, err)
	}
	select {
	case r := <-ch:
		return r.payload, r.err
	case <-c.done:
		return nil, ErrDisconnected
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (c *conn) send(e envelope) error {
	line, err := json.Marshal(e)
	if err != nil {
		return err
	}
	if len(line)+1 > MaxLineBytes {
		return fmt.Errorf("line of %d bytes is over the %d-byte cap", len(line)+1, MaxLineBytes)
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_, err = c.nc.Write(append(line, '\n'))
	return err
}

func (h *Hub) handle(nc net.Conn) {
	if tc, ok := nc.(*net.TCPConn); ok {
		// Small lines, one per command or event: never wait on Nagle.
		tc.SetNoDelay(true)
	}
	sc := bufio.NewScanner(nc)
	sc.Buffer(make([]byte, 0, 4096), MaxLineBytes)

	nc.SetReadDeadline(time.Now().Add(HelloTimeout))
	if !sc.Scan() {
		h.log.Printf("driver %s: no hello: %v", nc.RemoteAddr(), sc.Err())
		nc.Close()
		return
	}
	nc.SetReadDeadline(time.Time{})

	c := &conn{nc: nc, done: make(chan struct{})}
	var first envelope
	if err := json.Unmarshal(sc.Bytes(), &first); err != nil || first.Type != "hello" {
		h.reject(c, "the first line must be a hello")
		return
	}
	if err := json.Unmarshal(first.Payload, &c.hello); err != nil {
		h.reject(c, "the hello payload does not parse: "+err.Error())
		return
	}
	if c.hello.Protocol != Protocol {
		h.reject(c, fmt.Sprintf("protocol %d is not supported; this core speaks %d", c.hello.Protocol, Protocol))
		return
	}
	if c.hello.Host == "" || c.hello.Game == "" {
		h.reject(c, "a hello must name its host and game")
		return
	}

	h.mu.Lock()
	if h.cur != nil {
		h.mu.Unlock()
		h.reject(c, "busy: this core already has a driver")
		return
	}
	h.gen++
	c.gen = h.gen
	h.cur = c
	h.mu.Unlock()

	welcome, _ := json.Marshal(map[string]int{"protocol": Protocol})
	if err := c.send(envelope{Type: "welcome", Payload: welcome}); err != nil {
		h.drop(c, err)
		return
	}
	h.log.Printf("driver connected: host=%s game=%s variant=%s build=%s capabilities=%v",
		c.hello.Host, c.hello.Game, c.hello.Variant, c.hello.Build, c.hello.Capabilities)

	for sc.Scan() {
		var e envelope
		if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
			h.log.Printf("driver: dropping a line that does not parse: %v", err)
			continue
		}
		switch e.Type {
		case "result", "error":
			h.deliver(e)
		case "event":
			h.record(e.Payload)
		default:
			h.log.Printf("driver: ignoring a line of type %q", e.Type)
		}
	}
	h.drop(c, sc.Err())
}

func (h *Hub) reject(c *conn, reason string) {
	body, _ := json.Marshal(map[string]string{"reason": reason})
	c.send(envelope{Type: "reject", Payload: body})
	h.log.Printf("driver %s rejected: %s", c.nc.RemoteAddr(), reason)
	c.nc.Close()
}

func (h *Hub) deliver(e envelope) {
	h.mu.Lock()
	ch, ok := h.pending[e.ID]
	h.mu.Unlock()
	if !ok {
		h.log.Printf("driver: an answer to id %d nobody is waiting for", e.ID)
		return
	}
	if e.Type == "error" {
		var msg struct {
			Message string `json:"message"`
		}
		json.Unmarshal(e.Payload, &msg)
		if msg.Message == "" {
			msg.Message = "the driver reported an error without a message"
		}
		ch <- reply{err: errors.New(msg.Message)}
		return
	}
	ch <- reply{payload: e.Payload}
}

func (h *Hub) record(payload json.RawMessage) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.nextSeq++
	h.events = append(h.events, Event{Seq: h.nextSeq, At: time.Now(), Payload: append(json.RawMessage(nil), payload...)})
	if len(h.events) > EventBuffer {
		h.events = append(h.events[:0], h.events[len(h.events)-EventBuffer:]...)
	}
}

func (h *Hub) drop(c *conn, err error) {
	c.nc.Close()
	h.mu.Lock()
	if h.cur == c {
		h.cur = nil
	}
	h.mu.Unlock()
	close(c.done)
	if err != nil {
		h.log.Printf("driver disconnected: %v", err)
	} else {
		h.log.Printf("driver disconnected")
	}
}
