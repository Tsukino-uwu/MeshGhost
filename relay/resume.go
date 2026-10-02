package relay

// Session resumption, and the bounded join and resume snapshots. The locking discipline in online.go's header
// governs this file.

import (
	"crypto/rand"
	"encoding/hex"
	"log"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// suspendedSession is a dropped client's identity, held for protocol.DefaultResumeGrace in case it comes back. It
// lives in memory only: it survives a network blip, not a relay restart.
type suspendedSession struct {
	token    string
	playerID string
	room     *Room
	// timer is the grace countdown, set only while suspended.
	timer *time.Timer
	// suspended distinguishes a dropped identity from a live one. A session is registered when its token is issued,
	// not on disconnect: a hard-killed quic peer lingers until the idle timeout, and its reconnect must still match.
	suspended bool
}

// newResumeToken mints an unguessable session token: anyone holding it can take over the session it names,
// outstanding escrows included.
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

// suspend parks a dropped client's identity and arms the grace timer. The client stays in Room.members, marked
// suspended, so a joiner during the window learns of it while Room.forward skips it; removing and re-adding it would
// need a Join only some members should receive.
func (s *Server) suspend(r *Room, c *Client, token string) {
	r.mu.Lock()
	c.suspended = true
	c.Conn = nil
	// A resume builds a fresh Client and outbox, so two connections never share a writer.
	if c.out != nil {
		c.out.close()
	}
	r.mu.Unlock()

	s.mu.Lock()
	sess := s.suspended[token]
	if sess == nil {
		// Registered when its token was issued; missing means the token rotated or the identity already left.
		s.mu.Unlock()
		return
	}
	sess.suspended = true
	// Set under s.mu, which orders it against a racing takeSession or forgetSessionsOf; resumeGrace takes no lock.
	sess.timer = time.AfterFunc(s.resumeGrace(), func() { s.expireSuspended(token) })
	s.mu.Unlock()
	log.Printf("relay: %s dropped from room %q — holding its identity for %s in case it reconnects",
		c.PlayerID, r.Name, s.resumeGrace())
}

// registerSession records a live identity under the token just issued to it, replacing its previous token: tokens
// are single-use and rotate on every Welcome.
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

// forgetSessionsOf drops every token of playerID when that identity really leaves, so a stale token cannot resume an
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

// takeSession removes and returns the session for token if it is for the room the client asks to rejoin; a token for
// another room would hand its player_id to strangers. A live session is returned too: a takeover by a client whose
// old connection died unnoticed, which only the token's owner can do. The token is consumed either way.
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

// expireSuspended is the grace window running out: the client is not coming back, so this becomes an ordinary leave.
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

// finishLeave is everything that happens when a player really goes, shared by the immediate and grace-expiry paths
// so the two cannot drift.
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

	// Logged here, the one place every real departure passes, so a host can tell who is still in a room.
	log.Printf("relay: %s left room %q (%d still there)", playerID, r.Name, r.size())

	s.dropIfEmpty(r)
}

// resumeInto reinstates a suspended identity onto a fresh connection, returning its new Client and next resume token,
// or ok=false, after which the caller joins fresh. Nothing is broadcast: the room was never told the player left. A
// new Client replaces the old entry, keeping the fields allowStateFrom reads outside r.mu write-once.
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
		// From this hello, as a fresh join does: a name is never re-broadcast, so a missing one is lost for good.
		nametag: sanitizedNametag(hello),
		// Published into r.members before its Welcome is sent, as a fresh join is.
		holdUntilWelcome: true,
	}

	resumed.out = newOutbox(sess.playerID, nd)

	r.mu.Lock()
	prev, ok := r.members[sess.playerID]
	if !ok {
		// The identity left after takeSession (finishLeave removes a member before forgetting its session). The
		// outbox's writer is already running, so close it or it leaks with this transport.
		resumed.out.close()
		r.mu.Unlock()
		return nil, "", false
	}
	previousConn := prev.Conn
	// The previous connection's writer is finished, in a live takeover too.
	if prev.out != nil {
		prev.out.close()
	}
	r.seedLastAreaLocked(resumed)
	r.putMemberLocked(resumed)
	roster := make([]string, 0, len(r.members))
	var rosterNames map[string]protocol.Nametag
	for id, m := range r.members {
		if id == sess.playerID {
			continue
		}
		roster = append(roster, id)
		// Captured with the roster in one critical section, so the two agree on who is in the room.
		if m.nametag != nil {
			if rosterNames == nil {
				rosterNames = make(map[string]protocol.Nametag, len(r.members))
			}
			rosterNames[id] = *m.nametag
		}
	}
	r.mu.Unlock()

	// Bounded by the same function as a fresh join's Welcome.
	welcome, overflowRoster := boundWelcomeRoster(protocol.Welcome{
		PlayerID: sess.playerID,
		SendHz:   sendHz,
		// So a client can refuse a relay below its own floor; an older relay omits it, which is below any floor.
		ProtocolVersion: protocol.Version,
		GhostCollision:  s.resolveGhostCollision(),
		Features:        effectiveFeatures(r, resumed),
		ResumeToken:     newToken,
		Resumed:         true,
		ServerTimeMs:    time.Now().UnixMilli(),
	}, roster, rosterNames, sendBudget(nd))
	sendEnvelope(nd, protocol.TypeWelcome, welcome)

	// Members the bounded Welcome could not carry, sent as Joins before the hold is released.
	for _, id := range overflowRoster {
		j := protocol.Join{PlayerID: id}
		if tag, ok := rosterNames[id]; ok {
			t := tag
			j.Nametag = &t
		}
		sendEnvelope(nd, protocol.TypeJoin, j)
	}

	r.markWelcomedAndFlush(sess.playerID)

	// Closed after the swap, so its OnDisconnect finds another Client in r.members and does nothing.
	if previousConn != nil {
		_ = previousConn.Close()
	}

	// After the Welcome: the client drops state for any id it has not been told about.
	r.resumeSnapshot(sess.playerID)

	s.registerSession(r, sess.playerID, newToken, sess.token)

	took := "resumed its session"
	if !sess.suspended {
		// A takeover means the relay never saw the old connection die: normal on quic, odd on tcp, and worth telling
		// apart when explaining a duplicate ghost.
		took = "took over its still-open session (the relay had not yet noticed the old connection was gone)"
	}
	log.Printf("relay: %s reconnected to room %q and %s over %s", sess.playerID, r.Name, took, transportName)
	return resumed, newToken, true
}

// maxSnapshotLines bounds one join or resume snapshot: a burst of reliable lines into a queue of maxOutboxLines,
// where a reliable line at a full queue disconnects the client, so another member's many leases could otherwise
// put a resume into a disconnect loop. 192 leaves a quarter of the queue for ordinary traffic.
const maxSnapshotLines = 192

// boundSnapshot keeps at most maxSnapshotLines of outs, dropping from the end, so each caller assembles them in
// priority order. Truncation is logged once per room.
func (r *Room) boundSnapshot(outs []outgoing, kind string) []outgoing {
	if len(outs) <= maxSnapshotLines {
		return outs
	}
	dropped := len(outs) - maxSnapshotLines
	r.snapshotTruncatedOnce.Do(func() {
		log.Printf("relay: room %q: a %s snapshot came to %d lines and was truncated to %d "+
			"-- the last %d are omitted; the relay stays authoritative for all of them, and a "+
			"dropped state seed self-corrects on that peer's next sample",
			r.Name, kind, len(outs), maxSnapshotLines, dropped)
	})
	return outs[:maxSnapshotLines]
}

// resumeSnapshot is what a reinstated client needs to rebuild the view it lost, in priority order since boundSnapshot
// drops the tail: missed events, escrows and world lines nothing else restates, then leases the relay re-answers on
// request, then state seeds the peer's next sample overwrites.
func (r *Room) resumeSnapshot(to string) {
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	r.mu.Lock()
	// First: an event exists only in flight, while the relay can restate everything else.
	outs := r.missedEventsLocked(to)
	outs = append(outs, r.escrowSnapshotLocked(to)...)
	// A lossy world write sent while the client was away is never retried.
	outs = append(outs, r.worldSnapshotAllLocked(to)...)
	outs = append(outs, r.leaseSnapshotLocked(to)...)
	outs = append(outs, r.stateSnapshotLocked(to)...)
	outs = r.boundSnapshot(outs, "resume")
	r.mu.Unlock()
	r.deliver(outs)
}

// joinSnapshot seeds a newly joined client with every other member's last state and the room's whole world. It takes
// sendMu: a world seed delivered after a concurrent newer write would leave the joiner stale for good.
func (r *Room) joinSnapshot(to string) {
	r.sendMu.Lock()
	defer r.sendMu.Unlock()

	r.mu.Lock()
	// World first, then state, as in resumeSnapshot.
	outs := r.worldSnapshotAllLocked(to)
	outs = append(outs, r.stateSnapshotLocked(to)...)
	outs = r.boundSnapshot(outs, "join")
	r.mu.Unlock()
	r.deliver(outs)
}
