package quicconn

import "testing"

// TestQLogTracerIsOffUnlessAsked is finding B5 of the fourth adversarial
// review: the tracer used to be installed unconditionally, so the QLOGDIR
// environment variable alone made every stranger's handshake write a file.
// Now it is installed only after SetQLog(true), whatever the environment says.
func TestQLogTracerIsOffUnlessAsked(t *testing.T) {
	t.Setenv("QLOGDIR", t.TempDir())
	if quicConfig().Tracer != nil {
		t.Fatal("a qlog tracer is installed with QLOGDIR set and nobody having asked for it")
	}
	SetQLog(true)
	t.Cleanup(func() { SetQLog(false) })
	if quicConfig().Tracer == nil {
		t.Fatal("SetQLog(true) did not install the tracer")
	}
}
