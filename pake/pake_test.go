package pake_test

import (
	"bytes"
	"errors"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/pake"
)

const fp = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// run drives one login end to end and returns what each side concluded.
func run(t *testing.T, srv *pake.Server, code, clientIdentityOfServer string) (clientErr, serverErr error) {
	t.Helper()
	c, err := pake.NewClient(code)
	if err != nil {
		t.Fatal(err)
	}
	ke1, err := c.Start()
	if err != nil {
		t.Fatal(err)
	}
	ke2, sess, err := srv.Respond(ke1)
	if err != nil {
		t.Fatalf("Respond: %v", err)
	}
	ke3, cerr := c.Finish(ke2, clientIdentityOfServer)
	if cerr != nil {
		// The client refused; a real client sends nothing. The relay then
		// counts the session as failed (its Finish is never called) -- here
		// we call it with nothing to show it refuses too.
		return cerr, sess.Finish(nil)
	}
	return nil, sess.Finish(ke3)
}

func TestTheRightCodeSucceedsOnBothSides(t *testing.T) {
	srv, err := pake.NewServer("hunter2", fp)
	if err != nil {
		t.Fatal(err)
	}
	cerr, serr := run(t, srv, "hunter2", fp)
	if cerr != nil || serr != nil {
		t.Fatalf("right code: client %v, server %v", cerr, serr)
	}
	// And again on the same Server: one record serves every login.
	if cerr, serr := run(t, srv, "hunter2", fp); cerr != nil || serr != nil {
		t.Fatalf("second login: client %v, server %v", cerr, serr)
	}
}

func TestTheWrongCodeFailsOnTheClientBeforeAnythingIsSent(t *testing.T) {
	srv, err := pake.NewServer("hunter2", fp)
	if err != nil {
		t.Fatal(err)
	}
	cerr, serr := run(t, srv, "hunter3", fp)
	if !errors.Is(cerr, pake.ErrRefused) {
		t.Fatalf("a wrong code passed the client's own check: %v", cerr)
	}
	if !errors.Is(serr, pake.ErrRefused) {
		t.Fatalf("the relay accepted a login whose KE3 never came: %v", serr)
	}
}

// TestADifferentServerIdentityFailsTheClient is the binding: a client that
// verified some OTHER certificate names a different identity, and the login
// fails on its side even though the code is right and the bytes are the
// genuine relay's -- which is exactly what a man in the middle relaying
// KE1/KE2 between two TLS sessions looks like.
func TestADifferentServerIdentityFailsTheClient(t *testing.T) {
	srv, err := pake.NewServer("hunter2", fp)
	if err != nil {
		t.Fatal(err)
	}
	other := "ffff" + fp[4:]
	if cerr, _ := run(t, srv, "hunter2", other); !errors.Is(cerr, pake.ErrRefused) {
		t.Fatalf("a login naming a different relay identity succeeded on the client: %v", cerr)
	}
	if cerr, _ := run(t, srv, "hunter2", pake.UnboundIdentity); !errors.Is(cerr, pake.ErrRefused) {
		t.Fatalf("a bound relay accepted an unbound client: %v", cerr)
	}
}

// TestAForgedKE3IsRefusedByTheRelay: a KE3 from a login against another
// record (another code) does not satisfy this one, and a KE3 from a
// different session on the same record does not either.
func TestAForgedKE3IsRefusedByTheRelay(t *testing.T) {
	srv, err := pake.NewServer("hunter2", fp)
	if err != nil {
		t.Fatal(err)
	}
	// A genuine login, KE3 captured.
	c, _ := pake.NewClient("hunter2")
	ke1, _ := c.Start()
	ke2, sessA, err := srv.Respond(ke1)
	if err != nil {
		t.Fatal(err)
	}
	ke3, err := c.Finish(ke2, fp)
	if err != nil {
		t.Fatal(err)
	}
	// Replayed into a second session on the same record.
	c2, _ := pake.NewClient("hunter2")
	ke1b, _ := c2.Start()
	_, sessB, err := srv.Respond(ke1b)
	if err != nil {
		t.Fatal(err)
	}
	if err := sessB.Finish(ke3); !errors.Is(err, pake.ErrRefused) {
		t.Fatalf("a KE3 from another session was accepted: %v", err)
	}
	if err := sessA.Finish(ke3); err != nil {
		t.Fatalf("the genuine session refused its own KE3: %v", err)
	}
	// A session judges once: the same KE3 again is refused.
	if err := sessA.Finish(ke3); !errors.Is(err, pake.ErrRefused) {
		t.Fatalf("a session accepted a second Finish: %v", err)
	}
}

func TestMessagesAreSmallAndBounded(t *testing.T) {
	srv, err := pake.NewServer("hunter2", fp)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := pake.NewClient("hunter2")
	ke1, _ := c.Start()
	ke2, sess, _ := srv.Respond(ke1)
	ke3, _ := c.Finish(ke2, fp)
	for name, m := range map[string][]byte{"ke1": ke1, "ke2": ke2, "ke3": ke3} {
		if len(m) == 0 || len(m) > pake.MaxMessageLen {
			t.Errorf("%s is %d bytes; want 1..%d", name, len(m), pake.MaxMessageLen)
		}
	}
	if err := sess.Finish(ke3); err != nil {
		t.Fatal(err)
	}
	if _, _, err := srv.Respond(bytes.Repeat([]byte{1}, pake.MaxMessageLen+1)); !errors.Is(err, pake.ErrRefused) {
		t.Fatalf("an oversized KE1 was not refused: %v", err)
	}
}

func TestAnEmptyCodeIsAnError(t *testing.T) {
	if _, err := pake.NewServer("", fp); err == nil {
		t.Fatal("NewServer with no code returned a server")
	}
	if _, err := pake.NewClient(""); err == nil {
		t.Fatal("NewClient with no code returned a client")
	}
}

// FuzzMessagesNeverPanic: whatever bytes arrive as KE1 at the relay or as
// KE2 at the client, the answer is ErrRefused or a real message, never a
// panic. A relay's login endpoint is reachable by anyone who can complete a
// TLS handshake.
func FuzzMessagesNeverPanic(f *testing.F) {
	srv, err := pake.NewServer("hunter2", fp)
	if err != nil {
		f.Fatal(err)
	}
	c, _ := pake.NewClient("hunter2")
	ke1, _ := c.Start()
	ke2, sess, _ := srv.Respond(ke1)
	ke3, _ := c.Finish(ke2, fp)
	_ = sess.Finish(ke3)
	f.Add(ke1)
	f.Add(ke2)
	f.Add(ke3)
	f.Add([]byte{})
	f.Add(bytes.Repeat([]byte{0xff}, 96))
	f.Add(ke1[:len(ke1)-1])
	f.Fuzz(func(t *testing.T, data []byte) {
		if _, s, err := srv.Respond(data); err == nil {
			_ = s.Finish(data)
		}
		cl, _ := pake.NewClient("hunter2")
		_, _ = cl.Start()
		_, _ = cl.Finish(data, fp)
	})
}
