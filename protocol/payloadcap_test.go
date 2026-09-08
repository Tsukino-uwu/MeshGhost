package protocol

import (
	"bufio"
	"bytes"
	"strings"
	"testing"
)

// MaxPayloadBytes must stay exactly the largest payload a receiver ACCEPTS.
//
// This pins a property of Go's bufio.Scanner, not of this repo, which is why it
// is asserted rather than commented: the scanner's buffer may grow to the limit
// it was given, and the token AND its delimiter must both fit inside it -- so a
// payload of exactly the limit is refused, and the effective cap is one byte
// under. Measured 2026-09-08 against Buffer(_, 4096): 4095 delivered, 4096
// refused with "token too long".
//
// Every sender bound in the repo was written against MaxLineBytes and was
// therefore one byte optimistic: an envelope of exactly 4096 passed the check,
// went out, and killed the receiver's read loop with the very ErrTooLong the
// check existed to prevent. A one-byte window is exactly the kind that survives
// review and then surfaces as an unexplained reconnect loop, so it is pinned
// here against the real scanner rather than trusted to arithmetic.
//
// If a future Go release changes this, THIS test fails rather than the
// production path silently going one byte wrong again.
func TestMaxPayloadBytesIsWhatTheScannerActuallyAccepts(t *testing.T) {
	deliver := func(payload int) (int, error) {
		data := append([]byte(strings.Repeat("a", payload)), '\n')
		sc := bufio.NewScanner(bytes.NewReader(data))
		// Exactly how transport configures it: the limit is the BUFFER size.
		sc.Buffer(make([]byte, 0, 64), MaxLineBytes)
		if sc.Scan() {
			return len(sc.Bytes()), nil
		}
		return 0, sc.Err()
	}

	if got, err := deliver(MaxPayloadBytes); err != nil || got != MaxPayloadBytes {
		t.Fatalf("a payload of MaxPayloadBytes (%d) was not delivered whole: got %d bytes, err %v "+
			"-- the cap is meant to be the largest size that DOES arrive",
			MaxPayloadBytes, got, err)
	}
	if _, err := deliver(MaxPayloadBytes + 1); err == nil {
		t.Fatalf("a payload of %d (MaxPayloadBytes+1, i.e. exactly MaxLineBytes) was DELIVERED -- "+
			"then the cap is one byte too conservative and every sender is needlessly refusing a "+
			"line that would have arrived", MaxPayloadBytes+1)
	}
	if MaxPayloadBytes != MaxLineBytes-1 {
		t.Fatalf("MaxPayloadBytes = %d, MaxLineBytes = %d -- the relationship is not arbitrary: "+
			"it is the one byte the delimiter occupies in the scanner's buffer",
			MaxPayloadBytes, MaxLineBytes)
	}
}
