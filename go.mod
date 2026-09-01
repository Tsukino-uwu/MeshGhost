// v1.0.0 (2026-08-30): the stable surface is the WIRE protocol (version-checked at the
// handshake; docs/integrating.md documents it) -- that is what the 1.0 marks. The Go
// package APIs follow module semver from here (a breaking Go-API change means a /v2
// module path), but third-party use of the packages is unsupported and untested, so pin
// a version if it must not move. See the README's "Using this from your own game".
// v0.9.0 is the first fetchable tag; v0.8.5 and earlier were cut under the old local-only
// module name and cannot be resolved.
module github.com/Tsukino-uwu/MeshGhost

go 1.25.0

require github.com/quic-go/quic-go v0.61.0

require (
	golang.org/x/crypto v0.54.0 // indirect
	golang.org/x/net v0.56.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
)
