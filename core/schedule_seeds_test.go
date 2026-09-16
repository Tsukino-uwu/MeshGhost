package core

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestFuzzScheduleSeedsAreLongerThanTheirConfig: FuzzSchedule returns at once
// on any input no longer than its configuration prefix, so a seed or a
// committed reproducer that short passes every run while testing nothing. On
// 2026-09-01 the prefix grew to five bytes and nothing was migrated; the
// reproducer pinning the "names before Welcome block the handshake"
// regression (three bytes) and two of the five seeds had been no-ops since
// (pass 5 of the adversarial review, 2026-09-16, X2-1).
func TestFuzzScheduleSeedsAreLongerThanTheirConfig(t *testing.T) {
	for i, schedule := range fuzzScheduleSeedSchedules {
		if len(schedule) == 0 {
			t.Errorf("seed %d has no schedule bytes after the config prefix", i)
		}
	}
	if len(fuzzSchedulePinnedConfig) != fuzzScheduleConfigBytes {
		t.Fatalf("the pinned config is %d bytes, the prefix is %d", len(fuzzSchedulePinnedConfig), fuzzScheduleConfigBytes)
	}
	dir := filepath.Join("testdata", "fuzz", "FuzzSchedule")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read %s: %v", dir, err)
	}
	if len(entries) == 0 {
		t.Fatalf("%s is empty: this check is reading the wrong place", dir)
	}
	for _, e := range entries {
		raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		lines := strings.Split(strings.TrimSpace(strings.ReplaceAll(string(raw), "\r\n", "\n")), "\n")
		if len(lines) != 2 || !strings.HasPrefix(lines[1], "[]byte(") || !strings.HasSuffix(lines[1], ")") {
			t.Fatalf("%s is not a one-[]byte corpus file: %q", e.Name(), raw)
		}
		val, err := strconv.Unquote(strings.TrimSuffix(strings.TrimPrefix(lines[1], "[]byte("), ")"))
		if err != nil {
			t.Fatalf("%s: %v", e.Name(), err)
		}
		if len(val) <= fuzzScheduleConfigBytes {
			t.Errorf("corpus entry %s is %d bytes: FuzzSchedule returns before running anything at %d or fewer",
				e.Name(), len(val), fuzzScheduleConfigBytes)
		}
	}
}
