package quicconn

import "testing"

// TestQLogTracerIsOffUnlessAsked: QLOGDIR alone installs no tracer; only SetQLog(true) does.
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
