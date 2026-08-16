#!/bin/sh
# Marks the Linux/macOS MeshGhost binaries in this folder as programs you're allowed to run.
#
# Why this is needed at all: a .zip file has no way to record that a file is a program (that
# is a Unix idea, and .zip is a Windows format). So on Linux and macOS every MeshGhost binary
# in this folder arrives as an ordinary, un-runnable file, and the system refuses to start it
# with "permission denied" until it's marked. Windows doesn't work this way and doesn't care.
#
# Run this WITHOUT needing to mark it first -- that would be a chicken-and-egg problem:
#
#     sh make-executable.sh
#
# It only ever touches MeshGhost's own files in the folder it lives in, and does nothing else.

set -e
cd "$(dirname "$0")"

found=0
for f in meshghost-linux-* meshghost-macos-* meshghost-server-linux-* meshghost-server-macos-*; do
    # An unmatched pattern comes through literally in /bin/sh, so check the file is real.
    [ -f "$f" ] || continue
    chmod +x "$f"
    echo "  marked as runnable: $f"
    found=$((found + 1))
done

if [ "$found" -eq 0 ]; then
    echo "No MeshGhost Linux/macOS binaries found next to this script."
    echo "Run it from the folder you unzipped, where meshghost.exe also lives."
    exit 1
fi

echo ""
echo "Done -- $found file(s). Now start the one for your machine, for example:"
echo "    ./meshghost-linux-amd64"
echo ""
echo "Not sure which? amd64 is a normal Intel/AMD PC (including the Steam Deck)."
echo "arm64 is an Apple Silicon Mac (M1 and later) or an ARM Linux machine."
