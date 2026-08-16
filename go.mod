// Module path is local-only ("meshghost") rather than a github.com/<owner>/... path.
// The repo does have a real remote (github.com/Tsukino-uwu/MeshGhost), but this is a
// deliberate choice to leave as-is, not an oversight: renaming would touch every import
// path under cmd/ and internal/ for no functional gain, since nothing outside this repo
// currently imports this module as a library.
module meshghost

go 1.25.0

require github.com/quic-go/quic-go v0.61.0

require (
	golang.org/x/crypto v0.54.0 // indirect
	golang.org/x/net v0.56.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
)
