package udpconn

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"time"
)

// Split out of udpconn.go on 2026-08-27, along the banner comments that file had already drawn
// around its four concerns -- so the cut lines were chosen by whoever wrote them, not by this
// pass. Same precedent as relay/online.go into one file per plane (2026-08-25). udpconn.go keeps
// the package doc, the wire format, the constants and ErrDatagramTooLarge, which every part uses.
//
// Address-validation cookies: the stateless challenge that stops a spoofed source address
// costing the listener any per-connection state.

// ---------------------------------------------------------------- cookies

// cookieFor derives the address-validation cookie for addr in the given
// time slot. Deriving rather than storing is what keeps an unauthenticated
// stranger from growing the listener's memory — see the package doc.
func cookieFor(secret []byte, addr string, slot int64) []byte {
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(addr))
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], uint64(slot))
	m.Write(b[:])
	return m.Sum(nil)[:cookieLen]
}

func currentSlot(now time.Time) int64 { return now.UnixNano() / int64(cookieSlot) }

// validCookie reports whether got is the cookie for addr in either the
// current or the previous slot. Constant-time, so a wrong guess cannot be
// refined byte by byte the way the room-code comparison in relay
// already guards against.
func validCookie(secret []byte, addr string, got []byte, now time.Time) bool {
	if len(got) != cookieLen {
		return false
	}
	slot := currentSlot(now)
	for _, s := range []int64{slot, slot - 1} {
		if subtle.ConstantTimeCompare(got, cookieFor(secret, addr, s)) == 1 {
			return true
		}
	}
	return false
}
