package core

import (
	"log"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// Peer nametags: learned once from a Join or the Welcome, kept for an adapter that attaches later, and re-sanitized
// on receipt because the relay may be hostile or older. SanitizeDisplayName is idempotent, so the second pass cannot
// disagree with the first and render one player under two names.

// admitToRosterLocked adds playerID to the roster unless that takes its kind past protocol.MaxRosterSize; a refused id
// stays unknown, so its states are dropped. An id already present is always admitted. Relay ids and local ghosts each
// get the whole bound, so neither can starve the other. Caller holds c.mu.
func (c *Core) admitToRosterLocked(playerID string) bool {
	if c.roster == nil {
		c.roster = make(map[string]int64)
	}
	if _, present := c.roster[playerID]; present {
		return true
	}
	if len(c.roster) >= protocol.MaxRosterSize {
		local := isLocalPeerID(playerID)
		same := 0
		for id := range c.roster {
			if isLocalPeerID(id) == local {
				same++
			}
		}
		if same >= protocol.MaxRosterSize {
			return false
		}
	}
	// Stamped with the admission, so remoteStatesAt can tell a new seat from one that never carried anything.
	c.roster[playerID] = c.nowMsLocked()
	return true
}

// storeRemoteName records a peer's nametag, sanitized here, and tells the attached adapter if it changed. An empty
// name is stored as an absence: a name made entirely of stripped characters must draw no nametag either.
func (c *Core) storeRemoteName(playerID string, raw *protocol.Nametag) {
	c.storeRemoteNameOpts(playerID, raw, false)
}

// storeRemoteNameQuiet skips the per-change log line, for a tag that changes several times a second (a replay ghost's
// split time).
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
	// A tag whose name did not survive sanitizing is no tag, colour included, or a renderer draws an empty box.
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
	// adapterReady gates the attached adapter: it starts listening at bridge_ready.
	nd := c.attachedAdapter
	ready := c.adapterReady
	c.mu.Unlock()

	// Logged either way, once per change, or a missing nametag cannot tell never-sent from never-stored from
	// never-handed-over.
	if changed && !quiet {
		switch {
		case !ready || nd == nil:
			log.Printf("core: learned %s's nametag %q -- holding it, no adapter is attached yet "+
				"(it gets pushed when one attaches)", playerID, tag.Name)
		default:
			log.Printf("core: telling the adapter %s's nametag %q", playerID, tag.Name)
		}
	}

	// Only on a change, so a reconnect into the same id does not tell the adapter again.
	if changed && ready && nd != nil {
		_ = c.sendToAdapter(nd, bridge.TypeRemoteName, bridge.RemoteName{
			PlayerID:    playerID,
			DisplayName: tag.Name,
			Color:       tag.Color,
		})
	}
}

// storeRosterNames records the nametags of players already in the room, from Welcome.Nametags: a Join announces only
// arrivals. A name is kept only for an id the roster holds, which is also this map's only bound, since the relay
// fills it and nothing ties its keys to the roster.
func (c *Core) storeRosterNames(names map[string]protocol.Nametag) {
	if len(names) > 0 {
		log.Printf("core: the room's welcome carried %d nametag(s)", len(names))
	}
	c.mu.Lock()
	keep := make([]string, 0, len(names))
	for id := range names {
		if _, member := c.roster[id]; member {
			keep = append(keep, id)
		}
	}
	c.mu.Unlock()
	// Said out loud: a name that never appears otherwise looks like a renderer fault.
	if dropped := len(names) - len(keep); dropped > 0 {
		log.Printf("core: ignoring %d welcome nametag(s) for ids that are not in the room's roster", dropped)
	}
	for _, id := range keep {
		tag := names[id]
		c.storeRemoteName(id, &tag)
	}
}

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

// pushRemoteNames tells a freshly attached adapter every nametag already known: the game may launch long after the
// Joins that carried them went past.
func (c *Core) pushRemoteNames(nd transport.Transport) {
	known := c.remoteNamesSnapshot()
	// The count, zero included: "none to hand over" and "never called" must not look the same.
	log.Printf("core: adapter attached -- handing it %d already-known nametag(s)", len(known))
	for id, tag := range known {
		_ = c.sendToAdapter(nd, bridge.TypeRemoteName, bridge.RemoteName{
			PlayerID:    id,
			DisplayName: tag.Name,
			Color:       tag.Color,
		})
	}
}
