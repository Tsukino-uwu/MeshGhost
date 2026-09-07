package relay

// Regressions for the 2026-09-08 review pass over the relay: a Welcome bound
// that was computed on unescaped bytes, three defects in the resume path, an
// unbounded escrow table, counters that reported traffic that was never sent,
// and a world dispatch that failed open.
//
// Each test here was confirmed to FAIL with its own fix neutralised, one at a
// time — the standing rule in agent_docs/testing.md, and the reason
// TestBigRoomWelcomeStaysUnderLineLimit did not catch the first of them: it
// passed against the broken code because its fixture used a name that JSON
// does not escape.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// maximalEscapedName is the worst legitimate nametag: MaxDisplayNameRunes of a
// character protocol.SanitizeDisplayName keeps (graphic ASCII) and encoding/json
// escapes to six bytes with HTML escaping on, which is the setting every marshal
// in this package uses. An ampersand renders as a six-byte unicode escape, so this
// is 24 runes in hand and 144 bytes on the wire.
func maximalEscapedName() string { return strings.Repeat("&", protocol.MaxDisplayNameRunes) }

// TestAWelcomeIsBoundedByItsSerializedSize is C1 from the 2026-09-07 review.
//
// The 2026-09-01 cap was a member COUNT (32), sized by an arithmetic that
// counted the bytes in hand: "a nametag entry is ~60 with a maximal name". With
// the escaping above an entry is ~173, so a full Welcome measured 6183 B against
// protocol.MaxLineBytes 4096 and the joining core's scanner died with "token too
// long" — the 2026-09-01 incident, reopened at a fifth of the player count.
//
// The assertion is on the SERIALIZED size, which is the thing that was wrong:
// no count can be checked against an arithmetic nobody re-derives.
func TestAWelcomeIsBoundedByItsSerializedSize(t *testing.T) {
	const members = 64
	roster := make([]string, 0, members)
	names := make(map[string]protocol.Nametag, members)
	for i := 0; i < members; i++ {
		id := fmt.Sprintf("p%d", i+1)
		roster = append(roster, id)
		names[id] = protocol.Nametag{Name: maximalEscapedName(), Color: "#FFAA00"}
	}

	welcome, overflow := boundWelcomeRoster(protocol.Welcome{
		PlayerID:     "p99",
		SendHz:       20,
		Features:     allFeatures,
		ResumeToken:  strings.Repeat("a", protocol.ResumeTokenBytes*2),
		ServerTimeMs: time.Now().UnixMilli(),
	}, roster, names)

	if got := welcomeLineBytes(welcome); got > protocol.MaxLineBytes {
		t.Fatalf("welcome is %d bytes, over protocol.MaxLineBytes=%d — this is the line the "+
			"joining core's scanner kills the connection over", got, protocol.MaxLineBytes)
	}
	if len(welcome.Roster)+len(overflow) != members {
		t.Fatalf("roster of %d + overflow of %d != %d members; nobody may be silently dropped",
			len(welcome.Roster), len(overflow), members)
	}
	if len(overflow) == 0 {
		t.Fatal("nothing overflowed at 64 maximal names, so this fixture no longer exercises the bound")
	}
	// The nametags must follow the roster exactly: a name for an id the client
	// was not told about is a map entry it can never use, and an id in the
	// roster with its name left behind is the F4 failure in another place.
	if len(welcome.Nametags) != len(welcome.Roster) {
		t.Fatalf("welcome lists %d members and %d nametags", len(welcome.Roster), len(welcome.Nametags))
	}
	for _, id := range overflow {
		if _, ok := welcome.Nametags[id]; ok {
			t.Fatalf("overflow member %q still has its nametag in the Welcome", id)
		}
	}

	// The measurement the old comment got wrong, pinned so the next person to
	// change the sizing sees the real numbers rather than re-deriving them. The
	// review measured 3927 B at 20 members, 4115 B at 21 and 6183 B at the cap
	// of 32 against the shipped Welcome's own fixed fields; this fixture's are
	// slightly smaller, so its crossing sits a member or two later -- which is
	// exactly why the assertion below is on the bound and not on a count.
	full := func(n int) int {
		w, _ := boundWelcomeRoster(protocol.Welcome{PlayerID: "p99", SendHz: 20}, roster[:n], names)
		w.Roster = roster[:n]
		w.Nametags = make(map[string]protocol.Nametag, n)
		for _, id := range roster[:n] {
			w.Nametags[id] = names[id]
		}
		return welcomeLineBytes(w)
	}
	if full(32) <= protocol.MaxLineBytes {
		t.Fatalf("an unbounded Welcome at the old cap of 32 measures %d bytes, which now fits %d — "+
			"the escaping this test exists for has changed", full(32), protocol.MaxLineBytes)
	}
	t.Logf("unbounded welcome bytes with this fixture: 20 members = %d, 21 = %d, 32 = %d (protocol.MaxLineBytes = %d)",
		full(20), full(21), full(32), protocol.MaxLineBytes)
}

// TestAJoinerWithEscapedNamesInTheRoomIsNotKilledByItsOwnWelcome is C1 through
// the real server, read the way a real core reads it: a raw scanner capped at
// exactly protocol.MaxLineBytes, so this test dies exactly the way a real core
// died. TestBigRoomWelcomeStaysUnderLineLimit is the same shape with an
// UNESCAPED fixture, which is the whole reason it stayed green through this
// defect -- 120 of its names come to 2151 B where 32 of these come to over 6000.
func TestAJoinerWithEscapedNamesInTheRoomIsNotKilledByItsOwnWelcome(t *testing.T) {
	srv := NewServer()
	srv.MaxClients = 64
	addr := startServerWith(t, srv)

	const members = 40
	for i := 0; i < members; i++ {
		c := dialTestClient(t, addr, "faketest", "escapedroom", maximalEscapedName())
		defer c.conn.Close()
		c.expectWelcome(timeout)
	}

	raw, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("raw dial: %v", err)
	}
	defer raw.Close()
	hello, _ := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: mustMarshal(t, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "faketest",
		Room:            "escapedroom",
	})})
	if _, err := raw.Write(append(hello, '\n')); err != nil {
		t.Fatalf("raw hello: %v", err)
	}

	// Every member must still be learned -- through the Welcome or through the
	// Joins that carry the overflow. A bound that silently forgot members would
	// pass a size assertion and fail on screen.
	known := map[string]bool{}
	sc := bufio.NewScanner(raw)
	sc.Buffer(make([]byte, 4096), protocol.MaxLineBytes)
	_ = raw.SetReadDeadline(time.Now().Add(5 * time.Second))
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) > protocol.MaxLineBytes {
			t.Fatalf("relay sent a %d-byte line, over protocol.MaxLineBytes=%d", len(line), protocol.MaxLineBytes)
		}
		var env protocol.Envelope
		if err := json.Unmarshal(line, &env); err != nil {
			t.Fatalf("unparseable line from relay: %v", err)
		}
		switch env.Type {
		case protocol.TypeWelcome:
			var w protocol.Welcome
			if err := json.Unmarshal(env.Payload, &w); err != nil {
				t.Fatalf("unmarshal welcome: %v", err)
			}
			for _, id := range w.Roster {
				known[id] = true
			}
		case protocol.TypeJoin:
			var j protocol.Join
			if err := json.Unmarshal(env.Payload, &j); err != nil {
				t.Fatalf("unmarshal join: %v", err)
			}
			known[j.PlayerID] = true
		}
		if len(known) >= members {
			return
		}
	}
	t.Fatalf("connection ended before all %d members were learned (got %d): %v -- the scanner kill "+
		"an oversized Welcome causes, at %d named members rather than 150",
		members, len(known), sc.Err(), members)
}

// TestAResumeWelcomeIsBoundedLikeAJoinWelcome is F14, and it is the reason F4
// could not be fixed on its own: the resume path built its roster with no bound
// at all, and the only thing keeping it under protocol.MaxLineBytes was that it
// also dropped every nametag. Giving it the names back without the bound would
// have moved the "token too long" kill from the join path onto the resume path,
// where it is worse -- a client that is disconnected by its own resume Welcome
// reconnects with the token that Welcome carried and does it again.
func TestAResumeWelcomeIsBoundedLikeAJoinWelcome(t *testing.T) {
	srv := NewServer()
	srv.MaxClients = 64
	addr := startServerWith(t, srv)

	alice := dialFeatureClient(t, addr, "resumeroom", "alice", allFeatures)
	wa := alice.expectWelcome(timeout)
	if wa.ResumeToken == "" {
		t.Fatal("welcome carried no resume token despite resume.v1")
	}

	const members = 40
	for i := 0; i < members; i++ {
		c := dialFeatureClient(t, addr, "resumeroom", maximalEscapedName(), allFeatures)
		defer c.conn.Close()
		c.expectWelcome(timeout)
	}
	alice.conn.Close()

	// Read back the way a real core reads: a scanner at exactly the core's own
	// line limit, so an oversized resume Welcome kills this connection here.
	raw, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("raw dial: %v", err)
	}
	defer raw.Close()
	hello, _ := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: mustMarshal(t, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "emerald",
		Room:            "resumeroom",
		DisplayName:     "alice",
		Features:        allFeatures,
		ResumeToken:     wa.ResumeToken,
	})})
	if _, err := raw.Write(append(hello, '\n')); err != nil {
		t.Fatalf("raw hello: %v", err)
	}

	sc := bufio.NewScanner(raw)
	sc.Buffer(make([]byte, 4096), protocol.MaxLineBytes)
	_ = raw.SetReadDeadline(time.Now().Add(5 * time.Second))
	known := map[string]bool{}
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) > protocol.MaxLineBytes {
			t.Fatalf("relay sent a %d-byte line on the resume path, over protocol.MaxLineBytes=%d",
				len(line), protocol.MaxLineBytes)
		}
		var env protocol.Envelope
		if err := json.Unmarshal(line, &env); err != nil {
			t.Fatalf("unparseable line from relay: %v", err)
		}
		switch env.Type {
		case protocol.TypeWelcome:
			var w protocol.Welcome
			if err := json.Unmarshal(env.Payload, &w); err != nil {
				t.Fatalf("unmarshal welcome: %v", err)
			}
			if !w.Resumed {
				t.Fatalf("welcome did not report a resumption: %+v", w)
			}
			for _, id := range w.Roster {
				known[id] = true
			}
		case protocol.TypeJoin:
			var j protocol.Join
			if err := json.Unmarshal(env.Payload, &j); err != nil {
				t.Fatalf("unmarshal join: %v", err)
			}
			known[j.PlayerID] = true
		}
		if len(known) >= members {
			return // every other member learned, and no line over the limit
		}
	}
	t.Fatalf("the resumed connection ended after learning %d of %d members: %v",
		len(known), members, sc.Err())
}

// TestAResumeThatFindsNoMemberDoesNotLeakItsOutbox is F1.
//
// newOutbox starts its writer goroutine, and resumeInto built one BEFORE
// checking that the identity is still in the room — so the early return parked
// that goroutine on its signal channel forever, holding the transport with it.
// The window is not theoretical: finishLeave calls r.remove before
// forgetSessionsOf, so a resume landing between those two lines finds a valid
// session for a member that has already gone.
func TestAResumeThatFindsNoMemberDoesNotLeakItsOutbox(t *testing.T) {
	s := NewServer()
	r := newRoom("emerald", "", "room1", allFeatures)

	// Settle first, so ordinary lazily-started runtime goroutines are not
	// counted as the leak (leak_test.go's own reasoning).
	waitForGoroutines(0, 200*time.Millisecond)
	baseline := runtime.NumGoroutine()

	const attempts = 20
	for i := 0; i < attempts; i++ {
		sess := &suspendedSession{token: fmt.Sprintf("t%d", i), playerID: "gone", room: r}
		if _, _, ok := s.resumeInto(&recordingTransport{}, "tcp", r, sess, protocol.Hello{}, 20); ok {
			t.Fatal("resumed an identity that is not in the room")
		}
	}

	if got := waitForGoroutines(baseline+1, 2*time.Second); got > baseline+1 {
		t.Fatalf("%d goroutines after %d failed resumes, baseline %d — each leaked outbox writer "+
			"parks forever holding its transport", got, attempts, baseline)
	}
}

// stalledTransport never completes a write until it is released, which is how a
// peer that has stopped reading looks to the relay. closes counts Close calls:
// forwardLine closes a connection whose outbox refused a reliable line.
type stalledTransport struct {
	mu      sync.Mutex
	release chan struct{}
	got     [][]byte
	closes  int
}

func newStalledTransport() *stalledTransport {
	return &stalledTransport{release: make(chan struct{})}
}

func (st *stalledTransport) Send(payload []byte) error {
	<-st.release
	st.mu.Lock()
	st.got = append(st.got, append([]byte(nil), payload...))
	st.mu.Unlock()
	return nil
}
func (st *stalledTransport) SendUnreliable(payload []byte) error { return st.Send(payload) }
func (st *stalledTransport) OnReceive(func([]byte))              {}
func (st *stalledTransport) OnDisconnect(func(error))            {}
func (st *stalledTransport) OnError(func(error))                 {}
func (st *stalledTransport) Close() error {
	st.mu.Lock()
	st.closes++
	st.mu.Unlock()
	return nil
}

func (st *stalledTransport) closed() int {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.closes
}

// TestAResumeSnapshotCannotDisconnectTheClientItIsFor is F2.
//
// The snapshot emitted one reliable line per lease (up to
// protocol.MaxLeasesPerRoom, 256), per world authority, per escrow and per
// member, into an outbox that holds 256 and disconnects on a reliable line
// arriving at a full queue. So one member holding many leases made ANOTHER
// player's resume disconnect — and the client retries with the token from that
// same Welcome, which is a loop nothing breaks out of.
func TestAResumeSnapshotCannotDisconnectTheClientItIsFor(t *testing.T) {
	r := newRoom("emerald", "", "room1", allFeatures)

	stalled := newStalledTransport()
	me := &Client{
		PlayerID: "me",
		Conn:     stalled,
		features: protocol.NormalizeFeatures(allFeatures),
	}
	me.out = newOutbox("me", stalled)
	defer me.out.close()
	r.tryAdd(me)

	// One member holding the room's whole lease table, plus enough other
	// members with a state seed to put the total well past the queue.
	r.mu.Lock()
	r.leases = make(map[string]*lease, protocol.MaxLeasesPerRoom)
	for i := 0; i < protocol.MaxLeasesPerRoom; i++ {
		r.leases[fmt.Sprintf("k%d", i)] = &lease{holder: "hog", expiresAt: time.Now().Add(time.Minute)}
	}
	r.mu.Unlock()
	for i := 0; i < 100; i++ {
		id := fmt.Sprintf("peer%d", i)
		r.tryAdd(&Client{PlayerID: id, Conn: &recordingTransport{}})
		r.recordState(id, protocol.State{PlayerID: id, AreaID: "town"})
	}

	r.resumeSnapshot("me")

	if n := stalled.closed(); n != 0 {
		t.Fatalf("the resumed client's connection was closed %d time(s) by its own snapshot — "+
			"a burst the RELAY produced must never be read as a peer that stopped reading", n)
	}

	// Released only now, so the queue depth above was the real one.
	close(stalled.release)
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		stalled.mu.Lock()
		n := len(stalled.got)
		stalled.mu.Unlock()
		if n >= maxSnapshotLines {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	stalled.mu.Lock()
	delivered := len(stalled.got)
	stalled.mu.Unlock()
	if delivered > maxSnapshotLines {
		t.Fatalf("snapshot delivered %d lines, over maxSnapshotLines=%d", delivered, maxSnapshotLines)
	}
	if delivered != maxSnapshotLines {
		t.Fatalf("snapshot delivered %d lines, want the full budget of %d", delivered, maxSnapshotLines)
	}
}

// TestResumeKeepsEveryNametagInBothDirections is F4: the resumed Client was
// built without a nametag and its Welcome omitted Nametags, so a named player
// who blipped went nameless to every LATER joiner for the rest of the session,
// and got their own roster back with everybody's name stripped.
func TestResumeKeepsEveryNametagInBothDirections(t *testing.T) {
	addr := startServerWith(t, &Server{
		rooms:      make(map[string]*Room),
		MaxClients: DefaultMaxClients,
	})

	alice := dialFeatureClient(t, addr, "room1", "alice", allFeatures)
	wa := alice.expectWelcome(timeout)
	bob := dialFeatureClient(t, addr, "room1", "bob", allFeatures)
	defer bob.conn.Close()
	bob.expectWelcome(timeout)

	alice.conn.Close()
	back := dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     "alice",
		Features:        allFeatures,
		ResumeToken:     wa.ResumeToken,
	})
	defer back.conn.Close()

	w := back.expectWelcome(timeout)
	if !w.Resumed {
		t.Fatalf("welcome did not report a resumption: %+v", w)
	}
	// Direction one: the resumer's own roster.
	if tag, ok := w.Nametags[bob.playerIDIn(w.Roster)]; !ok || tag.Name != "bob" {
		t.Fatalf("resumed welcome nametags = %v for roster %v, want bob's name — a resumed player "+
			"must not come back to a room of anonymous ids", w.Nametags, w.Roster)
	}

	// Direction two: everyone who joins AFTER the blip.
	carol := dialFeatureClient(t, addr, "room1", "carol", allFeatures)
	defer carol.conn.Close()
	wc := carol.expectWelcome(timeout)
	if tag, ok := wc.Nametags[wa.PlayerID]; !ok || tag.Name != "alice" {
		t.Fatalf("a joiner after the blip sees nametags %v, want alice's name against %q",
			wc.Nametags, wa.PlayerID)
	}
}

// playerIDIn returns the one id in roster that is not tc's own. Both tests
// above have exactly two members, so this needs nothing cleverer.
func (tc *testClient) playerIDIn(roster []string) string {
	tc.t.Helper()
	if len(roster) != 1 {
		tc.t.Fatalf("roster = %v, want exactly one other member", roster)
	}
	return roster[0]
}

// TestTheEscrowTableIsBoundedAndItsCheckIsCounted is F3.
//
// escrowTableFullLocked counted only LIVE exchanges — correct, and the
// 2026-09-02 fix — but terminal records are retained for
// protocol.EscrowRetention (60s) and nothing bounded the map at all, so its
// size was inbound rate times retention (~3,600 entries at the flood cap) and
// the whole of it was scanned on every open, under r.mu.
func TestTheEscrowTableIsBoundedAndItsCheckIsCounted(t *testing.T) {
	r := newRoom("emerald", "", "room1", allFeatures)
	for _, id := range []string{"a", "b"} {
		r.tryAdd(&Client{PlayerID: id, Conn: &recordingTransport{}})
	}

	// Far more open-and-abort cycles than the table may hold.
	const cycles = 4 * maxEscrowRecordsPerRoom
	for i := 0; i < cycles; i++ {
		id := fmt.Sprintf("dead%d", i)
		r.handleEscrow("a", protocol.Escrow{Op: protocol.EscrowOpen, ID: id, With: "b"})
		r.handleEscrow("a", protocol.Escrow{Op: protocol.EscrowAbort, ID: id})
	}
	r.mu.Lock()
	size, live := len(r.escrows), r.escrowsLive
	r.mu.Unlock()
	if size > maxEscrowRecordsPerRoom {
		t.Fatalf("escrow table holds %d records after %d aborted exchanges, over the %d bound — "+
			"terminal records are retained for %s and were bounded by nothing but inbound rate",
			size, cycles, maxEscrowRecordsPerRoom, protocol.EscrowRetention)
	}
	if live != 0 {
		t.Fatalf("live escrow count = %d after aborting every one, want 0", live)
	}

	// The 2026-09-02 property still holds: retained records never refuse an
	// open. Evicting the oldest terminal record is what keeps both true at once.
	r.handleEscrow("b", protocol.Escrow{Op: protocol.EscrowOpen, ID: "fresh", With: "a"})
	r.mu.Lock()
	e := r.escrows["fresh"]
	r.mu.Unlock()
	if e == nil || e.phase != protocol.EscrowPhaseOpen {
		t.Fatalf("an open against a full table of terminal records got %+v, want an open exchange", e)
	}

	// And the per-opener count is maintained rather than rescanned: eight live
	// exchanges is the cap, the ninth is refused, and aborting one frees a slot.
	for i := 0; i < protocol.MaxLiveEscrowsPerMember; i++ {
		r.handleEscrow("a", protocol.Escrow{Op: protocol.EscrowOpen, ID: fmt.Sprintf("live%d", i), With: "b"})
	}
	r.handleEscrow("a", protocol.Escrow{Op: protocol.EscrowOpen, ID: "toomany", With: "b"})
	r.mu.Lock()
	tooMany := r.escrows["toomany"]
	r.mu.Unlock()
	if tooMany != nil && tooMany.phase == protocol.EscrowPhaseOpen {
		t.Fatalf("opener held %d live exchanges and the next was still granted",
			protocol.MaxLiveEscrowsPerMember)
	}
	r.handleEscrow("a", protocol.Escrow{Op: protocol.EscrowAbort, ID: "live0"})
	r.handleEscrow("a", protocol.Escrow{Op: protocol.EscrowOpen, ID: "afterabort", With: "b"})
	r.mu.Lock()
	after := r.escrows["afterabort"]
	r.mu.Unlock()
	if after == nil || after.phase != protocol.EscrowPhaseOpen {
		t.Fatalf("aborting a live exchange did not free the opener's slot: %+v", after)
	}
}

// TestForwardedCountersCountOnlyWhatTheGateAllowed is F13.
//
// Recipients and PayloadBytes were recorded from the PRE-gate member set, while
// the per-recipient receive-rate gate runs afterwards and only its result
// reaches forwardLine — so a room where anybody set max_receive_hz_per_player
// reported traffic that was never sent. introspect.go's own header calls that
// "the kind of confidently wrong number a debugging aid must never produce".
func TestForwardedCountersCountOnlyWhatTheGateAllowed(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	r.tryAdd(&Client{PlayerID: "a", Conn: &recordingTransport{}})
	// 10 Hz: one state per 100ms from any one sender.
	r.tryAdd(&Client{PlayerID: "b", Conn: &recordingTransport{}, maxReceiveHz: 10})

	const payload = 100
	now := time.Now()
	if got := r.stateRecipients("a", "", "", payload, now); len(got) != 1 {
		t.Fatalf("first state went to %v, want b", got)
	}
	// Same instant, so the gate refuses the second.
	if got := r.stateRecipients("a", "", "", payload, now); len(got) != 0 {
		t.Fatalf("second state in the same instant went to %v, want nobody", got)
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	if r.stateRecipientsOut != 1 {
		t.Fatalf("recipients = %d, want 1 — the second state was gated and never sent",
			r.stateRecipientsOut)
	}
	if r.stateBytesForwarded != payload {
		t.Fatalf("forwarded bytes = %d, want %d", r.stateBytesForwarded, payload)
	}
	if r.statesIn != 2 {
		t.Fatalf("statesIn = %d, want 2 — both arrived, whatever became of them", r.statesIn)
	}
}

// TestAnUnknownWorldOpIsNotTreatedAsASet is F20: the entity cap and the
// create-must-be-reliable rule both tested Op == WorldSet while the default arm
// stored anything that was not a drop, so both bounds rested on
// protocol.ValidateWorld in another package rather than on this switch.
func TestAnUnknownWorldOpIsNotTreatedAsASet(t *testing.T) {
	r := newRoom("emerald", "", "room1", []string{protocol.FeatureLeaseV1, protocol.FeatureWorldV1})
	writer := &recordingTransport{}
	r.tryAdd(&Client{PlayerID: "host", Conn: writer})
	peer := &recordingTransport{}
	r.tryAdd(&Client{PlayerID: "peer", Conn: peer})

	r.mu.Lock()
	r.leases = map[string]*lease{"sim": {holder: "host", expiresAt: time.Now().Add(time.Minute)}}
	r.mu.Unlock()

	r.handleWorld("host", protocol.World{
		Op: protocol.WorldOp("nonsense"), Authority: "sim", Key: "e0",
		Blob: json.RawMessage(`{"gen":1}`), Reliable: true,
	})

	r.mu.Lock()
	stored := len(r.world)
	r.mu.Unlock()
	if stored != 0 {
		t.Fatalf("an op this relay does not know wrote %d world key(s) — the entity cap and the "+
			"create-must-be-reliable rule both test Op == WorldSet and neither saw this", stored)
	}
	if got := peer.received(t); len(got) != 0 {
		t.Fatalf("an unknown op was broadcast to the room as %q", got[0].Type)
	}

	// The two real ops still work, so this did not close the door on everything.
	r.handleWorld("host", protocol.World{
		Op: protocol.WorldSet, Authority: "sim", Key: "e0",
		Blob: json.RawMessage(`{"gen":1}`), Reliable: true,
	})
	r.mu.Lock()
	stored = len(r.world)
	r.mu.Unlock()
	if stored != 1 {
		t.Fatalf("a real set stored %d keys, want 1", stored)
	}
}
