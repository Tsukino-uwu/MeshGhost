# Committed corpus for `FuzzRelaySurvivesArbitraryLines`

Seeds the target's own `f.Add` calls cannot express as well: inputs with MORE THAN ONE LINE. The
target writes its input and hangs up, so a single-line seed only ever exercises one message; the
2026-09-07 "second hello during the reject drain" family was a multi-line shape, and until
2026-09-15 no seed had one (fourth adversarial review, E5). `relay/fuzz_test.go` had also claimed a
corpus lived here that did not exist.

Each file is Go's corpus format (`go test fuzz v1`, then one `[]byte(...)` literal). A failing
input CI uploads as `fuzz-failure-corpus` goes in this folder too, under any name, and becomes a
regression test on the next `go test ./relay`.
