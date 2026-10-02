// Package pake proves a room code without sending it: OPAQUE (RFC 9807) between a client and a relay, bound to the
// relay's TLS identity.
//
// The relay learns that the client knows the code and the client learns that the relay knows it, and neither side's
// transcript lets a third party guess a short code offline. The relay is the OPAQUE server: with a room code
// configured it registers one record for the code at the first login, playing both roles in-process, and every client
// logs in against that record.
//
// # Binding to the relay's identity
//
// OPAQUE authenticates both identities, so both sides must name the same server identity. The relay registers under
// its own certificate fingerprint, and a client passes the fingerprint of the certificate it verified on this
// connection. A man in the middle presents a different certificate, so the client names a different identity and its
// KE3 step fails before anything is sent. The cryptography is github.com/bytemare/opaque's.
package pake

import (
	"errors"
	"fmt"
	"sync"

	"github.com/bytemare/opaque"
)

// ClientIdentity is the OPAQUE client identity every player uses: there is one record per code, not per player.
const ClientIdentity = "meshghost-player"

// UnboundIdentity is the server identity when there is no certificate to bind to (tests, the dev-only udp
// transport): the code is still proven, the relay's identity is not.
const UnboundIdentity = "meshghost-relay-unbound"

// MaxMessageLen bounds one login message as raw bytes; a longer one is refused before it is parsed.
const MaxMessageLen = 1024

// ErrRefused is the error every failed login wraps, on either side. It is one error so an attacker cannot ask which
// check failed.
var ErrRefused = errors.New("pake: the room code proof failed")

// context is mixed into every transcript so one from another application using the library cannot be replayed here.
var context = []byte("meshghost room code proof v1")

func configuration() *opaque.Configuration {
	conf := opaque.DefaultConfiguration()
	conf.Context = context
	return conf
}

// Server holds the relay's OPAQUE state for one room code: the key material and the single registered record. Safe
// for concurrent use; build a new one when the code changes.
type Server struct {
	identity string
	srv      *opaque.Server
	record   *opaque.ClientRecord
}

// NewServer registers roomCode under serverIdentity (the relay's certificate fingerprint, or UnboundIdentity). The
// key material is generated per call: registration and every login happen within one relay process, so none of it
// needs to survive a restart.
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

	// Registration, both roles in-process: the relay holds the code, so it is its own client here.
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

// Session is one login in progress on the relay: KE2 has been sent and KE3 is awaited. Finish must be called exactly
// once.
type Session struct {
	once     sync.Once
	srv      *opaque.Server
	expected []byte
	done     bool
}

// Respond answers a client's KE1 with KE2 and the Session that will judge its KE3. Bytes that are not a KE1 return
// ErrRefused.
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

// Finish judges the client's KE3. A nil error means the client knows the code and named this relay's identity.
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

// Finish checks the relay's KE2 against the code and serverIdentity (the fingerprint of the certificate this
// connection verified, or UnboundIdentity) and returns KE3 to send. On ErrRefused there is nothing to send, so a
// refused relay learns nothing more.
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
