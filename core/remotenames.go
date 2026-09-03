package core

import (
	"log"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// Peer nametags: learning them from the relay, and handing them to the adapter.
//
// A name is not part of a peer's motion, which is why none of this lives with
// the interpolation buffer. It arrives once -- in a Join, or in the Welcome
// roster for players already in the room -- stays put through every state that
// follows, and has to still be available to an adapter that attaches minutes
// after the core connected.
//
// EVERYTHING HERE RE-SANITIZES. The relay sanitizes on the way in, and this
// does it again on the way out, because "the relay already did it" assumes a
// relay this client did not write and cannot inspect. A hostile or simply older
// relay can put anything in a Join. protocol.SanitizeDisplayName is idempotent
// precisely so this second pass costs nothing and cannot disagree with the
// first -- if it could, one player would render under different names on
// different machines, which makes impersonation easier rather than harder.

// storeRemoteName records a peer's nametag and, if it changed, tells the
// attached adapter. raw is whatever the relay sent and is sanitized here.
//
// An empty name is stored as an ABSENCE rather than as "": there is no
// difference between "set no name" and "set a name made entirely of characters
// we strip", and both must end with no nametag drawn.
// admitToRosterLocked adds playerID to the roster unless doing so would take
// it past protocol.MaxRosterSize, in which case the id is refused and stays
// unknown -- so its state is dropped by storeRemoteState like any other
// unannounced id, and the adapter never hears of it. An id already present
// is always admitted (a repeated join is not a new seat). Caller holds c.mu.
func (c *Core) admitToRosterLocked(playerID string) bool {
	if c.roster == nil {
		c.roster = make(map[string]struct{})
	}
	if _, present := c.roster[playerID]; present {
		return true
	}
	if len(c.roster) >= protocol.MaxRosterSize {
		return false
	}
	c.roster[playerID] = struct{}{}
	return true
}

func (c *Core) storeRemoteName(playerID string, raw *protocol.Nametag) {
	c.storeRemoteNameOpts(playerID, raw, false)
}

// storeRemoteNameQuiet is storeRemoteName without the per-change log line,
// for a tag that legitimately changes several times a second: the split
// time on a replay ghost (core/splittime.go). The push-on-change rule is
// unchanged; only the log is.
func (c *Core) storeRemoteNameQuiet(playerID string, raw *protocol.Nametag) {
	c.storeRemoteNameOpts(playerID, raw, true)
}

func (c *Core) storeRemoteNameOpts(playerID string, raw *protocol.Nametag, quiet bool) {
	var tag protocol.Nametag
	if raw != nil {
		tag = protocol.Nametag{
			Name:  protocol.SanitizeDisplayName(raw.Name),
			Color: protocol.SanitizeNameColor(raw.Color),
		}
	}
	// A tag whose name did not survive sanitizing is no tag, colour included:
	// a colour with nothing to colour would have a renderer draw an empty box.
	if tag.Name == "" {
		tag = protocol.Nametag{}
	}

	c.mu.Lock()
	prev, had := c.remoteNames[playerID]
	switch {
	case tag.Name == "" && had:
		delete(c.remoteNames, playerID)
	case tag.Name != "":
		if c.remoteNames == nil {
			c.remoteNames = make(map[string]protocol.Nametag)
		}
		c.remoteNames[playerID] = tag
	}
	changed := tag != prev
	// attachedAdapter, the connection that actually became the adapter -- not
	// merely any bridge connection. adapterReady gates it because an adapter
	// keys off bridge_ready to start listening, so a name sent before that has
	// nowhere to land.
	nd := c.attachedAdapter
	ready := c.adapterReady
	c.mu.Unlock()

	// LOGGED EITHER WAY, once per change, because silence here was unreadable.
	//
	// A nametag failing to appear in a game had three possible causes on this side -- the relay
	// never sent one, this core never stored it, or it stored it and never handed it over -- and
	// nothing distinguished them. That cost several live sessions chasing the renderer while the
	// message was never arriving. Cheap by construction: a name changes at most once per peer per
	// session, so this cannot become per-frame logging.
	if changed && !quiet {
		switch {
		case !ready || nd == nil:
			log.Printf("core: learned %s's nametag %q -- holding it, no adapter is attached yet "+
				"(it gets pushed when one attaches)", playerID, tag.Name)
		default:
			log.Printf("core: telling the adapter %s's nametag %q", playerID, tag.Name)
		}
	}

	// Only on a change: a name is stable for a whole session, so an adapter
	// that has been told once must not be told again every time somebody
	// reconnects into the same id.
	if changed && ready && nd != nil {
		sendBridgeEnvelope(nd, bridge.TypeRemoteName, bridge.RemoteName{
			PlayerID:    playerID,
			DisplayName: tag.Name,
			Color:       tag.Color,
		})
	}
}

// storeRosterNames records the nametags of players already in the room, from
// Welcome.RosterNames.
//
// Without this a newcomer learns ids and no names for everybody who was already
// standing there, and stays that way until each of them happens to reconnect --
// because a Join only ever announces an ARRIVAL, and names are deliberately not
// in the state stream.
func (c *Core) storeRosterNames(names map[string]protocol.Nametag) {
	if len(names) > 0 {
		log.Printf("core: the room's welcome carried %d nametag(s)", len(names))
	}
	for id, raw := range names {
		c.storeRemoteName(id, &raw)
	}
}

// remoteNamesSnapshot copies the currently known nametags.
func (c *Core) remoteNamesSnapshot() map[string]protocol.Nametag {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.remoteNames) == 0 {
		return nil
	}
	out := make(map[string]protocol.Nametag, len(c.remoteNames))
	for id, tag := range c.remoteNames {
		out[id] = tag
	}
	return out
}

// pushRemoteNames tells a freshly attached adapter every nametag already known.
//
// An adapter attaches whenever the game launches, which can be long after this
// core connected and long after the Joins that carried these names went past --
// the same gap pushAreaPreference exists for. Without this, ghosts that were
// already in the room render with no nametag for the rest of the session while
// anyone joining later gets one, which looks like a bug in the nametags rather
// than a missed handover.
func (c *Core) pushRemoteNames(nd transport.Transport) {
	known := c.remoteNamesSnapshot()
	// Says the COUNT, including zero. "No nametags to hand over" and "this was never called" are
	// different facts and looked identical for an entire evening of live testing.
	log.Printf("core: adapter attached -- handing it %d already-known nametag(s)", len(known))
	for id, tag := range known {
		sendBridgeEnvelope(nd, bridge.TypeRemoteName, bridge.RemoteName{
			PlayerID:    id,
			DisplayName: tag.Name,
			Color:       tag.Color,
		})
	}
}
