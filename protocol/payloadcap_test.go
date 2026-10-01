package protocol

import (
	"bufio"
	"bytes"
	"strings"
	"testing"
)

// TestMaxPayloadBytesIsWhatTheScannerActuallyAccepts pins a property of Go's bufio.Scanner: the token and its
// delimiter must both fit the buffer, so a payload of exactly the limit is refused. If a Go release changes that,
// this fails rather than every sender going one byte wrong.
func TestMaxPayloadBytesIsWhatTheScannerActuallyAccepts(t *testing.T) {
	deliver := func(payload int) (int, error) {
		data := append([]byte(strings.Repeat("a", payload)), '\n')
		sc := bufio.NewScanner(bytes.NewReader(data))
		// As transport configures it: the limit is the buffer size.
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
