package bridge

import (
	"encoding/json"
	"testing"
)

// The two lines the Pseudoregalia adapter actually emits (Plugin.cpp,
// input_track_drain_and_send, 2026-09-08), byte for byte as its std::format
// calls shape them: the first batch after a hello carries the label table,
// every later one only edges. Pinned here so a change on either side that
// breaks the other is a red test and not a silently dropped track -- the core
// drops a batch that fails ValidateInputSample and logs, and an adapter never
// hears about it.
func TestPseudoregaliaAdapterLinesAreAccepted(t *testing.T) {
	lines := []string{
		`{"type":"input_sample","payload":{"labels":["jump","attack","crouch","wallride","throw","guard","interact","lockon","power","quickmap","perspective"],"axes":["move_x","move_y","look_x","look_y"],"source":"enhanced_input_bound_value","edges":[{"f":1041,"t":17350,"m":1,"ax":[0,0,0,0]}]}}`,
		`{"type":"input_sample","payload":{"labels":["jump","attack","crouch","wallride","throw","guard","interact","lockon","power","quickmap","perspective"],"axes":["move_x","move_y","look_x","look_y"],"source":"enhanced_input_bound_value","edges":[]}}`,
		`{"type":"input_sample","payload":{"drop":3,"edges":[{"f":1043,"t":17383,"m":0,"ax":[0.5,-0.25,0.015625,-1]},{"f":1044,"t":17400,"m":9,"ax":[0.5,-0.25,0.015625,-1]}]}}`,
	}
	for i, line := range lines {
		var env Envelope
		if err := json.Unmarshal([]byte(line), &env); err != nil {
			t.Fatalf("line %d: envelope: %v", i, err)
		}
		if env.Type != TypeInputSample {
			t.Fatalf("line %d: type %q", i, env.Type)
		}
		var msg InputSample
		if err := json.Unmarshal(env.Payload, &msg); err != nil {
			t.Fatalf("line %d: payload: %v", i, err)
		}
		if !ValidateInputSample(msg) {
			t.Fatalf("line %d refused: %s", i, InputSampleRejectReason(msg))
		}
	}
}
