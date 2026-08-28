package relay

// Split out of online.go on 2026-08-25, where leases, escrow, late-join
// snapshots and session resumption were four independent subsystems sharing one
// 1,115-line file. relay/world.go had already set the precedent for one
// subsystem per file; these four simply had not followed it yet.
//
// **The locking discipline in online.go's header governs this file too, and it
// is the only subtle thing here.** In short: r.mu guards the room's maps and
// every handler computes its outgoing messages under it and delivers them AFTER
// unlocking; r.sendMu is held across BOTH stamp and deliver so the total order
// assigned is the order actually sent. Lock order is always sendMu then mu.
// Read online.go's header before changing anything in this file.

import (
	"crypto/rand"
	"encoding/hex"
	"log"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// ---------------------------------------------------------------------------
// Session resumption
// ---------------------------------------------------------------------------

// suspendedSession is a dropped client's identity, held for
// protocol.DefaultResumeGrace in case it comes back.
//
// **Stable identity is one of the two genuinely new subsystems**
// agent_docs/beyond-cosmetic.md §5 names (the other, persistence, is
// deliberately not built): player_id is a bare counter that resets on relay
// restart, and before this there was no session resumption at all — the
// contract said so outright. Everything here is in memory and dies with the
// process, which is the honest boundary: this survives a network blip, not a
// relay restart.
type suspendedSession struct {
	token    string
	playerID string
	room     *Room
	// timer is the grace countdown, set only while suspended.
	timer *time.Timer
	// suspended distinguishes an identity whose connection has dropped from
	// one that is still live.
	//
	// A session is registered when its token is ISSUED, not when the client
	// drops, and that is the fix for the case that matters. Registering only
	// on disconnect means a resume works solely when the relay noticed the
	// drop FIRST — and on quic it routinely does not, because a hard-killed
	// peer sends no close frame and the connection sits there until quic's own
	// idle timeout (measured 2026-08-17: ~17s, against an immediate RST on
	// tcp). A client that reconnects inside that window presented a token
	// matching nothing, got a fresh player_id, and left its old ghost standing
	// until the timeout — strictly worse than not having resumption at all,
	// and precisely the blip resumption exists for.
	suspended bool
}

// newResumeToken mints an unguessable session token. crypto/rand, not the
// player_id counter: this is the one value in the relay that must be
// unguessable rather than merely unique, because anyone holding it can take
// over the session it names — including its outstanding escrows.
func newResumeToken() (string, error) {
	b := make([]byte, protocol.ResumeTokenBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// resumeGrace resolves how long a dropped identity is held.
func (s *Server) resumeGrace() time.Duration {
	if s.ResumeGrace > 0 {
		return s.ResumeGrace
	}
	return protocol.DefaultResumeGrace
}

// suspend parks a dropped client's identity instead of removing it from the
// room, and arms the grace timer that gives up on it.
//
// The client stays in Room.members, marked suspended: that keeps the roster
// consistent for anyone who joins during the window (they are told about a
// player who is briefly away, rather than never learning of them at all),
// while Room.forward declines to write to it. Removing it and re-adding on
// resume would have needed a Join broadcast that only some members should
// receive, which is not a thing the roster can express.
func (s *Server) suspend(r *Room, c *Client, token string) {
	r.mu.Lock()
	c.suspended = true
	c.Conn = nil
	// The socket behind this queue is gone, so its writer has nothing left to
	// write. A resume builds a fresh Client with a fresh outbox rather than
	// reviving this one, which is what keeps the two connections from ever
	// sharing a writer.
	if c.out != nil {
		c.out.close()
	}
	r.mu.Unlock()

	s.mu.Lock()
	sess := s.suspended[token]
	if sess == nil {
		// The session should already be registered from when its token was
		// issued (registerSession). A missing one means the token was rotated
		// or the identity already left, so there is nothing to hold.
		s.mu.Unlock()
		return
	}
	sess.suspended = true
	// The timer is created and stored under s.mu, not after it. Every other
	// access to sess.timer -- forgetSessionsOf's Stop, takeSession's Stop --
	// is reached from s.mu, so assigning it outside was a genuine unguarded
	// write: a client reconnecting with its token in the same instant the
	// relay notices the old socket died is the routine quic takeover case,
	// not a rare one. resumeGrace takes no lock, so this is safe to hold.
	sess.timer = time.AfterFunc(s.resumeGrace(), func() { s.expireSuspended(token) })
	s.mu.Unlock()
	log.Printf("relay: %s dropped from room %q — holding its identity for %s in case it reconnects",
		c.PlayerID, r.Name, s.resumeGrace())
}

// registerSession records a live identity under the token just issued to it,
// replacing any previous token for the same identity (tokens are single-use
// and rotate on every Welcome).
func (s *Server) registerSession(r *Room, playerID, token, replacing string) {
	if token == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.suspended == nil {
		s.suspended = make(map[string]*suspendedSession)
	}
	if replacing != "" {
		delete(s.suspended, replacing)
	}
	s.suspended[token] = &suspendedSession{token: token, playerID: playerID, room: r}
}

// forgetSessionsOf drops every token belonging to playerID, called when that
// identity really leaves. Without it a long-lived relay accumulates one dead
// entry per departed player, and — worse — a stale token could later resume an
// identity that no longer exists.
func (s *Server) forgetSessionsOf(r *Room, playerID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for token, sess := range s.suspended {
		if sess.room == r && sess.playerID == playerID {
			if sess.timer != nil {
				sess.timer.Stop()
			}
			delete(s.suspended, token)
		}
	}
}

// takeSession removes and returns the session for token, if it is for the room
// the client is asking to rejoin. A token for another room is refused here and
// the caller falls back to a fresh join — reinstating an identity into a room
// it never belonged to would hand its player_id to strangers.
//
// **A session that is still LIVE is returned too, not just a suspended one.**
// That is a takeover, and it is the case that makes resumption work in
// practice rather than only in tests: a client whose connection died without
// the relay noticing (routine on quic, where nothing is sent on a hard kill
// and the connection lingers until the idle timeout) reconnects while the
// relay still believes the old one is fine. Refusing there — the original
// behaviour — handed it a fresh player_id and left its old ghost standing.
// Since only the holder of the token can do this, and the token is
// unguessable, a takeover is always the legitimate owner returning.
//
// Single-use: the token is consumed whether or not the caller goes on to
// succeed, and a fresh one is issued in the new Welcome.
func (s *Server) takeSession(token, roomName, gameID string) *suspendedSession {
	if token == "" {
		return nil
	}
	s.mu.Lock()
	sess := s.suspended[token]
	if sess == nil || sess.room.Name != roomName || sess.room.GameID != gameID {
		s.mu.Unlock()
		return nil
	}
	delete(s.suspended, token)
	s.mu.Unlock()
	if sess.timer != nil {
		sess.timer.Stop()
	}
	return sess
}

// expireSuspended is the grace window running out: the client is not coming
// back, so this becomes an ordinary leave — the room is told, leases are
// freed, in-flight escrows abort, and the server slot is returned.
func (s *Server) expireSuspended(token string) {
	s.mu.Lock()
	sess := s.suspended[token]
	if sess == nil {
		s.mu.Unlock()
		return
	}
	delete(s.suspended, token)
	s.mu.Unlock()

	log.Printf("relay: %s did not reconnect within %s — treating it as a real leave", sess.playerID, s.resumeGrace())
	s.finishLeave(sess.room, sess.playerID)
}

// finishLeave is everything that happens when a player really goes: leases
// freed, live escrows aborted, snapshot forgotten, membership removed, the
// room told, and the server-wide slot released. Shared by the immediate path
// (a client with no resumption) and the grace-expiry path above, so the two
// cannot drift.
func (s *Server) finishLeave(r *Room, playerID string) {
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	r.mu.Lock()
	to := r.memberIDsLocked()
	outs := r.releaseLeasesOfLocked(playerID, to)
	outs = append(outs, r.abortEscrowsOfLocked(playerID)...)
	r.mu.Unlock()
	r.deliver(outs)

	r.forgetState(playerID)
	r.remove(playerID)
	s.forgetSessionsOf(r, playerID)
	s.releaseSlot()

	leave, err := envelope(protocol.TypeLeave, protocol.Leave{PlayerID: playerID})
	if err == nil {
		r.Forward(leave, r.roster())
	}

	// The join line's own comment calls join and leave a pair of lifecycle
	// events -- but only the join was ever printed, so a live session log
	// showed (2026-08-19) seventeen joins and not one departure, and a host
	// reading it could not tell who was still in a room or whether anything
	// was leaking. One line per occurrence, and it belongs HERE rather than at
	// a call site because finishLeave is the single choke point every real
	// departure passes through -- which is the reason this function exists.
	// The two call sites that already print WHY (the resume grace expired, a
	// token could not be minted) still do; this says it actually completed.
	log.Printf("relay: %s left room %q (%d still there)", playerID, r.Name, r.size())

	s.dropIfEmpty(r)
}

// resumeInto reinstates a suspended identity onto a fresh connection. It
// returns the client's new room entry and its next single-use resume token,
// or ok=false if the identity could not be reinstated — in which case the
// caller falls back to an ordinary join, and this has already finished the
// old identity off so its slot and leases are not orphaned.
//
// Nothing is broadcast: the room was never told this player left, so it must
// not now be told it arrived. That is the entire user-visible point — a
// network blip stops costing everyone else a despawn and respawn.
//
// A NEW Client replaces the old map entry rather than the old one being
// mutated in place. That keeps Client's write-once fields (maxReceiveHz,
// transport) genuinely write-once, so a resumed client may arrive on a
// different transport or with a different receive cap without introducing a
// race against allowStateFrom, which reads those fields outside r.mu.
func (s *Server) resumeInto(nd transport.Transport, transportName string, r *Room, sess *suspendedSession, hello protocol.Hello, sendHz int) (*Client, string, bool) {
	newToken, err := newResumeToken()
	if err != nil {
		log.Printf("relay: could not mint a resume token for %s: %v — completing its leave instead", sess.playerID, err)
		s.finishLeave(r, sess.playerID)
		return nil, "", false
	}

	resumed := &Client{
		PlayerID:     sess.playerID,
		Conn:         nd,
		maxReceiveHz: protocol.ClampReceiveHz(hello.MaxReceiveHz),
		ownAreaOnly:  hello.OwnAreaOnly,
		transport:    transportName,
		features:     protocol.NormalizeFeatures(hello.Features),
		// Same window as a fresh join: this Client is published into
		// r.members below and only then sent its Welcome, so without the
		// hold a broadcast in between reaches the socket first. See
		// Client.holdUntilWelcome.
		holdUntilWelcome: true,
	}

	resumed.out = newOutbox(sess.playerID, nd)

	r.mu.Lock()
	prev, ok := r.members[sess.playerID]
	if !ok {
		// The grace window expired between takeSession and here, so the
		// identity is already gone. Joining fresh is correct.
		r.mu.Unlock()
		return nil, "", false
	}
	previousConn := prev.Conn
	// The identity is being taken over by a new connection, so the previous
	// one's writer is finished -- including in the live-takeover case, where
	// the relay never noticed the old socket die (routine on quic).
	if prev.out != nil {
		prev.out.close()
	}
	// The resumed Client is brand new, so its cached area starts empty while
	// the room still remembers this player's real one. See seedLastAreaLocked.
	r.seedLastAreaLocked(resumed)
	r.members[sess.playerID] = resumed
	roster := make([]string, 0, len(r.members))
	for id := range r.members {
		if id != sess.playerID {
			roster = append(roster, id)
		}
	}
	r.mu.Unlock()

	sendEnvelope(nd, protocol.TypeWelcome, protocol.Welcome{
		PlayerID:       sess.playerID,
		Roster:         roster,
		SendHz:         sendHz,
		GhostCollision: s.resolveGhostCollision(),
		Features:       effectiveFeatures(r, resumed),
		ResumeToken:    newToken,
		Resumed:        true,
		ServerTimeMs:   time.Now().UnixMilli(),
	})

	// Welcome is on the wire; release the hold and deliver anything the room
	// produced while this resumption was being wired up.
	r.markWelcomedAndFlush(sess.playerID)

	// Close the connection being taken over, if it was still open. Its
	// OnDisconnect then finds r.members[id] is no longer its own Client and
	// does nothing — the stale-callback guard that already existed for the
	// suspended case covers the live one identically. Closing AFTER the swap
	// is what makes that true, so the order here is load-bearing.
	if previousConn != nil {
		_ = previousConn.Close()
	}

	// Sent after Welcome for the same reason a fresh join's seed is: the
	// client rebuilds its roster from Welcome and drops state for any id it
	// has not been told about.
	r.resumeSnapshot(sess.playerID)

	s.registerSession(r, sess.playerID, newToken, sess.token)

	took := "resumed its session"
	if !sess.suspended {
		// Worth distinguishing in the log: a takeover means the relay never
		// saw the old connection die, which on quic is the normal case and on
		// tcp usually means something odder. Someone reading this log to
		// explain a duplicate ghost needs to know which happened.
		took = "took over its still-open session (the relay had not yet noticed the old connection was gone)"
	}
	log.Printf("relay: %s reconnected to room %q and %s over %s", sess.playerID, r.Name, took, transportName)
	return resumed, newToken, true
}

// resumeSnapshot is everything a reinstated client needs to rebuild the view
// it lost when its connection dropped: every other member's last known state,
// every held lease, and every exchange it is a party to.
func (r *Room) resumeSnapshot(to string) {
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	r.mu.Lock()
	outs := r.stateSnapshotLocked(to)
	outs = append(outs, r.leaseSnapshotLocked(to)...)
	outs = append(outs, r.escrowSnapshotLocked(to)...)
	// A resuming client that is NOT the host has missed every lossy world write
	// sent while it was away, and nothing else will ever resend them — a lossy
	// write is superseded by the next one, not retried.
	outs = append(outs, r.worldSnapshotAllLocked(to)...)
	r.mu.Unlock()
	r.deliver(outs)
}

// joinSnapshot is what a newly-joined client is seeded with: every other
// member's last known state, and the room's whole world.
//
// **It takes sendMu, which the seed it replaced did not.** The old inline block
// in handleConn locked mu, built the state snapshot, unlocked and delivered,
// with no serialization against a concurrent broadcast. State got away with
// that because a stale seed self-corrects within 50ms — the next sample from
// that player overwrites it. A WORLD seed does not: delivered after a
// concurrently-broadcast newer write, it leaves the joiner permanently stale
// with nothing to correct it. Factored into the same shape as resumeSnapshot,
// which already took sendMu for the same reason.
//
// The converse ordering is already safe: a broadcast that wins the race
// finishes first, so a snapshot built afterwards is newer by construction.
func (r *Room) joinSnapshot(to string) {
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	r.mu.Lock()
	outs := r.stateSnapshotLocked(to)
	outs = append(outs, r.worldSnapshotAllLocked(to)...)
	r.mu.Unlock()
	r.deliver(outs)
}
