# Sourced by the hooks: defines run_python, a Python 3.11 or newer that really runs, or stops the hook.
# Tried in order: an absolute path in this clone's own config (git config preflight.python <path>), py -3, python3,
# python. Each is probed, so a stand-in that only prints an install hint (the Microsoft Store's python3) is passed over.
probe() { "$@" -c 'import sys; sys.exit(sys.version_info < (3, 11))' >/dev/null 2>&1; }
configured=$(git config --get preflight.python)
if [ -n "$configured" ] && probe "$configured"; then run_python() { "$configured" "$@"; }
elif probe py -3; then run_python() { py -3 "$@"; }
elif probe python3; then run_python() { python3 "$@"; }
elif probe python; then run_python() { python "$@"; }
else
    echo "hooks: no Python 3.11 or newer runs here; name one with: git config preflight.python <path to python>" >&2
    exit 1
fi
