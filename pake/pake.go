// Package pake proves a room code without sending it: OPAQUE (RFC 9807)
// between a client and a relay, bound to the relay's TLS identity.
//
// Until 2026-09-15 the room code crossed the wire as-is inside TLS, so
// whoever terminated that TLS -- the relay you meant, or anyone who had got
// between you and it and whose certificate your client had accepted --
// read it. With a PAKE the relay learns that the client knows the code and
// the client learns that the relay knows it, and neither side's transcript
// lets a third party guess a short code offline. The relay is the OPAQUE
// server; on startup, with a room code configured, it registers ONE record
// for the code, playing both roles in-process (it holds the code, so it can),
// and every client logs in against that record. ADR 0067.
//
// # Binding to the relay's identity
//
// OPAQUE's identities are part of what the envelope authenticates, so both
// sides must name the same server identity or the login fails. That is the
// hook: the relay registers under ITS OWN certificate fingerprint, and a
// client passes the fingerprint of the certificate it actually verified on
// this connection. A man in the middle presents a different certificate,
// so the client names a different identity, and its KE3 step fails before
// anything is sent -- whatever the middle relays. The relay's own
// certificate is the one thing an interceptor cannot present, which is what
// makes a fingerprint the right identity rather than a name.
//
// # What this package is and is not
//
// It is a thin shape over github.com/bytemare/opaque (MIT; the survey that
// chose it is a row in agent_docs/licensing.md): the three login messages as
// bytes, one record per code, and the identity rule above. The cryptography
// is the library's; the tests here cover the integration -- right code
// succeeds, wrong code fails on the client before KE3 and on the relay at
// KE3, a different identity fails, a message from a different registration
// fails, and no bytes off the wire can panic either side.
package pake

import (
	"errors"
	"fmt"
	"sync"

	"github.com/bytemare/opaque"
)

// ClientIdentity is the OPAQUE client identity every player uses. There is
// one record per code, not per player, so it is a constant; what varies
// per connection is the server identity.
const ClientIdentity = "meshghost-player"

// UnboundIdentity is the server identity used when there is no certificate
// to bind to: a relay that was not told its fingerprint, or a client on a
// connection that is not TLS (the dev-only udp transport). The code is
// still proven; the relay's identity is not. The shipped relay always sets
// its fingerprint (cmd/meshghost-relay), and the shipped client always
// dials TLS, so this is a test and dev value.
const UnboundIdentity = "meshghost-relay-unbound"

// MaxMessageLen bounds one login message as raw bytes. KE1, KE2 and KE3
// under the default configuration are well under it; a longer one is not
// this protocol and is refused before it is parsed.
const MaxMessageLen = 1024

// ErrRefused is the error every failed login wraps, on either side: the
// code did not match, the identity did not match, or the bytes were not a
// login message. Deliberately one error -- a client that could tell which
// would be a client an attacker could ask.
var ErrRefused = errors.New("pake: the room code proof failed")

// context is mixed into every OPAQUE transcript so a transcript from some
// other application using the same library cannot be replayed here.
var context = []byte("meshghost room code proof v1")

func configuration() *opaque.Configuration {
	conf := opaque.DefaultConfiguration()
	conf.Context = context
	return conf
}

// Server holds the relay's OPAQUE state for one room code: the key
// material and the single registered record. Safe for concurrent use;
// build a new one when the code changes (SetRoomCode does).
type Server struct {
	identity string
	srv      *opaque.Server
	record   *opaque.ClientRecord
}

// NewServer registers roomCode under serverIdentity (the relay's certificate
// fingerprint, or UnboundIdentity) and returns a Server ready to answer
// logins. The key material is generated per call: registration and every
// login happen within one relay process, so nothing about it needs to
// survive a restart, and a fresh set per code is one less secret to keep.
func NewServer(roomCode, serverIdentity string) (*Server, error) {
	if roomCode == "" {
		return nil, errors.New("pake: no room code to register")
	}
	if serverIdentity == "" {
		serverIdentity = UnboundIdentity
	}
	conf := configuration()
	seed := conf.GenerateOPRFSeed()
	priv, pub := conf.KeyGen()
	if seed == nil || priv == nil || pub == nil {
		return nil, errors.New("pake: could not generate server key material")
	}
	srv, err := conf.Server()
	if err != nil {
		return nil, fmt.Errorf("pake: server: %w", err)
	}
	if err := srv.SetKeyMaterial(&opaque.ServerKeyMaterial{
		Identity:       []byte(serverIdentity),
		PrivateKey:     priv,
		PublicKeyBytes: pub.Encode(),
		OPRFGlobalSeed: seed,
	}); err != nil {
		return nil, fmt.Errorf("pake: key material: %w", err)
	}

	// Registration, both roles in-process. The relay holds the code, so it
	// is its own "user" here; the record it keeps is what every player's
	// login is checked against.
	reg, err := conf.Client()
	if err != nil {
		return nil, fmt.Errorf("pake: registration client: %w", err)
	}
	req, err := reg.RegistrationInit([]byte(roomCode))
	if err != nil {
		return nil, fmt.Errorf("pake: registration init: %w", err)
	}
	credID := opaque.RandomBytes(32)
	resp, err := srv.RegistrationResponse(req, credID, nil)
	if err != nil {
		return nil, fmt.Errorf("pake: registration response: %w", err)
	}
	rec, _, err := reg.RegistrationFinalize(resp, []byte(ClientIdentity), []byte(serverIdentity))
	if err != nil {
		return nil, fmt.Errorf("pake: registration finalize: %w", err)
	}
	return &Server{
		identity: serverIdentity,
		srv:      srv,
		record: &opaque.ClientRecord{
			CredentialIdentifier: credID,
			ClientIdentity:       []byte(ClientIdentity),
			RegistrationRecord:   rec,
		},
	}, nil
}

// Identity is the server identity this Server registered under.
func (s *Server) Identity() string { return s.identity }

// Session is one login in progress on the relay: KE2 has been sent and KE3
// is awaited. Finish must be called exactly once.
type Session struct {
	once     sync.Once
	srv      *opaque.Server
	expected []byte
	done     bool
}

// Respond answers a client's KE1 with KE2 and the Session that will judge
// its KE3. Bytes that are not a KE1 return ErrRefused.
func (s *Server) Respond(ke1 []byte) ([]byte, *Session, error) {
	if len(ke1) == 0 || len(ke1) > MaxMessageLen {
		return nil, nil, ErrRefused
	}
	m1, err := s.srv.Deserialize.KE1(ke1)
	if err != nil {
		return nil, nil, ErrRefused
	}
	ke2, out, err := s.srv.GenerateKE2(m1, s.record)
	if err != nil {
		return nil, nil, ErrRefused
	}
	return ke2.Serialize(), &Session{srv: s.srv, expected: out.ClientMAC}, nil
}

// Finish judges the client's KE3. A nil error means the client knows the
// code and named this relay's identity; anything else is ErrRefused.
func (ss *Session) Finish(ke3 []byte) error {
	var err error = ErrRefused
	ss.once.Do(func() {
		ss.done = true
		if len(ke3) == 0 || len(ke3) > MaxMessageLen {
			return
		}
		m3, derr := ss.srv.Deserialize.KE3(ke3)
		if derr != nil {
			return
		}
		if ss.srv.LoginFinish(m3, ss.expected) != nil {
			return
		}
		err = nil
	})
	return err
}

// Client is one login attempt from a player's side. Start once, Finish once.
type Client struct {
	code   []byte
	client *opaque.Client
}

// NewClient prepares a login with roomCode.
func NewClient(roomCode string) (*Client, error) {
	if roomCode == "" {
		return nil, errors.New("pake: no room code to prove")
	}
	c, err := configuration().Client()
	if err != nil {
		return nil, fmt.Errorf("pake: client: %w", err)
	}
	return &Client{code: []byte(roomCode), client: c}, nil
}

// Start returns KE1, the first message, to send in the hello.
func (c *Client) Start() ([]byte, error) {
	ke1, err := c.client.GenerateKE1(c.code)
	if err != nil {
		return nil, fmt.Errorf("pake: ke1: %w", err)
	}
	return ke1.Serialize(), nil
}

// Finish checks the relay's KE2 against the code and serverIdentity -- the
// fingerprint of the certificate this connection verified, or
// UnboundIdentity -- and returns KE3 to send. ErrRefused means the code is
// wrong, or the relay is not the one this identity names; nothing is
// returned to send in that case, so a refused relay learns nothing more.
func (c *Client) Finish(ke2 []byte, serverIdentity string) ([]byte, error) {
	if serverIdentity == "" {
		serverIdentity = UnboundIdentity
	}
	if len(ke2) == 0 || len(ke2) > MaxMessageLen {
		return nil, ErrRefused
	}
	m2, err := c.client.Deserialize.KE2(ke2)
	if err != nil {
		return nil, ErrRefused
	}
	ke3, _, _, err := c.client.GenerateKE3(m2, []byte(ClientIdentity), []byte(serverIdentity))
	if err != nil {
		return nil, ErrRefused
	}
	return ke3.Serialize(), nil
}
