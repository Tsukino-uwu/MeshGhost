//go:build meshghost_devudp

package udpconn

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"time"
)

// cookieFor derives the address-validation cookie for addr in the given time slot. Derived rather than stored, so
// a stranger cannot grow the listener's memory.
func cookieFor(secret []byte, addr string, slot int64) []byte {
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(addr))
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], uint64(slot))
	m.Write(b[:])
	return m.Sum(nil)[:cookieLen]
}

func currentSlot(now time.Time) int64 { return now.UnixNano() / int64(cookieSlot) }

// validCookie reports whether got is the cookie for addr in either the current or the previous slot. Constant-time,
// so a wrong guess cannot be refined byte by byte.
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
