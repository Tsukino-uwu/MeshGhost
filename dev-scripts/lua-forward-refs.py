#!/usr/bin/env python
"""Find names used before their `local` definition in a Lua file.

Lua resolves such a name to a global, which is nil, so the call site silently does nothing or errors somewhere
unrelated. Deliberately crude: it flags candidates for a human to judge, it does not parse Lua. Forward declarations
(`local x` earlier, assigned later) are understood and not flagged.
"""
import re, sys

# File scope only (no leading whitespace): a local inside a function cannot be referenced from outside it.
DEF = re.compile(r'^local\s+(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)')
DEF_MULTI = re.compile(r'^local\s+([A-Za-z_][A-Za-z0-9_,\s]*?)\s*=')

def check(path):
    lines = open(path, encoding='utf-8', errors='ignore').read().split('\n')
    first_def = {}
    for i, line in enumerate(lines):
        m = DEF_MULTI.match(line) or DEF.match(line)
        if m:
            for name in m.group(1).split(','):
                name = name.strip()
                if name and name not in first_def:
                    first_def[name] = i
    def strip_noise(line):
        """Remove string literals and comments before searching for a use: the raw line finds words, not references."""
        line = re.sub(r'"[^"]*"', '""', line)
        line = re.sub(r"'[^']*'", "''", line)
        line = re.sub(r'--.*$', '', line)
        return line

    problems = []
    for name, defline in first_def.items():
        if len(name) < 3:
            continue
        # A bare `local name` line is a forward declaration: the fix for this problem, not an instance of it.
        decl = re.compile(r'^local\s+' + re.escape(name) + r'\s*$')
        if any(decl.match(l) for l in lines[:defline]):
            continue
        use = re.compile(r'\b' + re.escape(name) + r'\b')
        for i, line in enumerate(lines[:defline]):
            code = strip_noise(line)
            # `x:name(` is a method call and `x.name` a field, not our local; an indented `name = ...` is a table key.
            code = re.sub(r'[:.]\s*' + re.escape(name) + r'\b', '.', code)
            if re.match(r'^\s+' + re.escape(name) + r'\s*=', line):
                continue
            if not use.search(code):
                continue
            s = line.strip()
            problems.append((i + 1, name, defline + 1, s[:90]))
            break
    return problems

for path in sys.argv[1:]:
    probs = check(path)
    print(f"=== {path}: {len(probs)} candidate(s)")
    for lineno, name, defline, text in sorted(probs):
        print(f"  line {lineno}: uses `{name}` (defined line {defline})")
        print(f"      {text}")
