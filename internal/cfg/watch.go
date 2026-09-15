package cfg

import (
	"os"
	"time"
)

// FileWatch notices when a config file a human edits has been saved.
//
// It is a poll of the file's modification time and size, once a second, and
// a change counts only on the SECOND poll that shows the same new values --
// one poll after the write stopped -- so an editor's two-step save (truncate,
// then write) is read whole rather than as an empty file. Lifted out of
// cmd/meshghost's configWatcher on 2026-09-15 so the relay could re-read its
// own config the same way (fourth adversarial review, B4: changing room_code
// used to mean restarting the relay and dropping everyone). The mechanics are
// the client's, unchanged; what each binary DOES with a change stays its own.
type FileWatch struct {
	path        string
	seenMod     time.Time // the file as last applied
	seenSize    int64
	pendingMod  time.Time // a change seen once, waiting to hold still
	pendingSize int64
	havePending bool
}

// NewFileWatch remembers the file as it is now, so only a later save counts.
func NewFileWatch(path string) *FileWatch {
	w := &FileWatch{path: path}
	if info, err := os.Stat(path); err == nil {
		w.seenMod, w.seenSize = info.ModTime(), info.Size()
	}
	return w
}

// Poll looks at the file once and reports whether a settled change is there
// to be applied. A missing file changes nothing: the settings in force stay.
func (w *FileWatch) Poll() bool {
	info, err := os.Stat(w.path)
	if err != nil {
		w.havePending = false
		return false
	}
	mod, size := info.ModTime(), info.Size()
	if mod.Equal(w.seenMod) && size == w.seenSize {
		w.havePending = false
		return false
	}
	if !w.havePending || !mod.Equal(w.pendingMod) || size != w.pendingSize {
		w.havePending, w.pendingMod, w.pendingSize = true, mod, size
		return false
	}
	w.havePending = false
	w.seenMod, w.seenSize = mod, size
	return true
}

// Pending reports whether a change has been seen once and is waiting to hold
// still. For tests.
func (w *FileWatch) Pending() bool { return w.havePending }

// Run polls once a second until stop closes, calling onChange for each
// settled change. Wall-clock, because it paces a stat() of a file a human
// edits.
func (w *FileWatch) Run(stop <-chan struct{}, onChange func()) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			if w.Poll() {
				onChange()
			}
		}
	}
}
