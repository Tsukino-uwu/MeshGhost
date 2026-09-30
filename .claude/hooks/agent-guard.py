"""Claude Code runs this before every shell command, file edit and page fetch in this repo (.claude/settings.json).
It denies what would get past the git hooks and a read of a GitHub project with no agent_docs/licensing.md row (its
licence file aside), and asks before a change to the gate data, docs/capabilities.md or .claude/. A guard against
slips, not a wall: pre-push and CI check everything again."""
import json
import os
import re
import shlex
import subprocess
import sys

# What the gates allow is never the agent's call; .claude/ is this guard, .git/ holds the clone's hooks and settings.
ASKED = ('docs/capabilities.md', 'dev-scripts/gate-lists.txt', 'dev-scripts/doc-map.txt', 'dev-scripts/phase-map.txt',
         '.claude/', '.git/')
ARMING = re.compile(r'git config (--local )?(--get )?core\.hookspath( \.githooks)?', re.I)
RUNS_ITS_ARGUMENT = {'-c', '-command', '/c', 'eval', 'iex', 'invoke-expression'}
CONTROL = {';', '&&', '||', '|', '&', '(', ')', ';;', '|&'}
GIT_TAKES_VALUE = {'-c', '-C', '--git-dir', '--work-tree', '--namespace', '--config-env'}
# A project's licence is read before anything else of it, and then it gets its row.
LICENSING, LISTS = 'agent_docs/licensing.md', 'dev-scripts/gate-lists.txt'
GITHUB_URL = re.compile(r'(?<![\w.-])(?:(?:www\.)?github\.com|raw\.githubusercontent\.com|codeload\.github\.com'
                        r'|api\.github\.com/repos)/([\w.-]+)/([\w.-]+)([^\s\'"]*)', re.I)
API_PATH = re.compile(r'/?repos/([\w.-]+)/([\w.-]+)(\S*)', re.I)
SEARCHED_REPO = re.compile(r'repo:([\w.-]+)/([\w.-]+)', re.I)
LICENCE_FILE = re.compile(r'(licen[cs]e|copying)[\w.-]*', re.I)
FETCHERS = {'curl', 'wget', 'invoke-webrequest', 'iwr', 'invoke-restmethod', 'irm', 'start-bitstransfer'}
GIT_FETCHES = {'clone', 'fetch', 'ls-remote', 'pull', 'archive', 'submodule'}


def answer(decision, reason):
    print(json.dumps({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': decision,
                                             'permissionDecisionReason': 'agent-guard: ' + reason}}))
    sys.exit(0)


def asked(rel):
    rel = rel.lower()
    return any(rel == p or (p.endswith('/') and rel.startswith(p)) for p in ASKED)


def in_repo(path, root):
    try:
        rel = os.path.relpath(os.path.normcase(os.path.realpath(os.path.join(root, path))),
                              os.path.normcase(os.path.realpath(root)))
    except ValueError:
        return None
    rel = rel.replace(os.sep, '/')
    return None if rel == '..' or rel.startswith('../') else rel


def without_bodies(command):
    """Drops heredoc and here-string bodies: a commit message may mention anything without running it."""
    command = re.sub(r'@([\'"])\r?\n.*?\r?\n\1@', "''", command, flags=re.S)
    out, closing = [], None
    for line in command.split('\n'):
        if closing:
            closing = None if line.strip() == closing else closing
            continue
        out.append(line)
        m = re.search(r'<<-?\s*([\'"]?)(\w+)\1', line)
        closing = m.group(2) if m else None
    return '\n'.join(out)


def words_of(command):
    lexer = shlex.shlex(command.replace('\n', ' ; '), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError:
        return re.findall(r'[;&|()]+|[^\s;&|()]+', command)


def program(word):
    return re.split(r'[\\/]', word)[-1].lower().removesuffix('.exe')


def git_subcommand(seg):
    """The git subcommand a segment runs, past git's own options; '' when it runs no git."""
    names = [program(w) for w in seg]
    if 'git' not in names:
        return ''
    i = names.index('git') + 1
    while i < len(seg) and seg[i].startswith('-'):
        i += 2 if seg[i] in GIT_TAKES_VALUE else 1
    return seg[i].lower() if i < len(seg) else ''


def segments(words):
    seg = []
    for w in words + [';']:
        if w in CONTROL:
            if seg:
                yield seg
            seg = []
        else:
            seg.append(w)


def refusal(command, depth=0):
    words = words_of(without_bodies(command))
    for i, w in enumerate(words):
        low = w.lower()
        if low.startswith('--no-veri'):
            return f'{w} skips the git hooks'
        if low in ('commit-tree', 'update-ref'):
            return f'git {w} writes history by hand, past the git hooks'
        if re.match(r'(\$env:)?git_config_', low):
            return f'{w} sets git config from the environment, which can turn the hooks off'
        if low in RUNS_ITS_ARGUMENT and i + 1 < len(words) and depth < 3:
            inner = refusal(words[i + 1], depth + 1)
            if inner:
                return inner
    for seg in segments(words):
        names = [program(w) for w in seg]
        if 'git' not in names:
            continue
        if any(re.match(r'(-c|--config-env=)?core\.hookspath', w, re.I) for w in seg) \
                and not ARMING.fullmatch(' '.join(seg[names.index('git'):])):
            return 'this changes core.hooksPath, which decides whether the git hooks run at all'
        if git_subcommand(seg) == 'commit':
            after = seg[[w.lower() for w in seg].index('commit') + 1:]
            cluster = next((w for w in after if re.fullmatch(r'-[A-Za-z]*n[A-Za-z]*', w)), None)
            if cluster:
                return f'git commit {cluster}: -n skips the git hooks'
    return None


def asks(command, root):
    for seg in segments(words_of(without_bodies(command))):
        names = [program(w) for w in seg]
        if any(re.search(r'\.git[\\/](config|hooks)', w) for w in seg):
            return 'this reads or changes the clone\'s own git settings or hooks'
        if names[:1] == ['gh'] and 'api' in seg and any(
                w in ('-f', '-F', '--field', '--raw-field', '--input') or (w in ('-X', '--method') and i + 1 < len(seg)
                and seg[i + 1].upper() != 'GET') for i, w in enumerate(seg)):
            return 'gh api writing to GitHub puts changes there past the git hooks'
        if git_subcommand(seg) == 'commit':
            # A script can write these without an edit to ask about; the commit is the last place to catch it.
            changed = changed_asked_files(root)
            if changed:
                return ('this commit may change what the gates allow, or this guard, which is the user\'s call: '
                        + ', '.join(changed[:6]))
    return None


def repos_read(seg):
    """(owner, repo, rest of the path) for each GitHub project a shell segment reads from."""
    names = [program(w) for w in seg]
    found, fetcher = [], any(n in FETCHERS for n in names)
    if fetcher or git_subcommand(seg) in GIT_FETCHES or names[:1] == ['gh']:
        found += [m.groups() for w in seg for m in GITHUB_URL.finditer(w)]
    if fetcher:
        found += [(m.group(1), m.group(2), '') for w in seg if 'api.github.com' in w.lower()
                  for m in SEARCHED_REPO.finditer(w)]
    if names[:1] == ['gh']:
        found += [m.groups() for w in seg for m in [API_PATH.fullmatch(w)] if m]
        found += [(m.group(1), m.group(2), '') for w in seg for m in SEARCHED_REPO.finditer(w)]
        found += [(*seg[i + 1].split('/', 1), '') for i, w in enumerate(seg[:-1])
                  if w in ('-R', '--repo') and seg[i + 1].count('/') == 1]
        if len(seg) > 2 and seg[1] == 'repo' and seg[2] in ('view', 'clone', 'fork') and len(seg) > 3 \
                and seg[3].count('/') == 1:
            found.append((*seg[3].split('/'), ''))
    return found


def unlicensed(reads, root):
    """The first project read that has no licensing.md row and isn't ours, unless all that's read is its licence."""
    table, own = None, None
    for owner, repo, rest in reads:
        repo = re.sub(r'\.git$', '', repo)
        last = rest.split('?')[0].rstrip('/').rsplit('/', 1)[-1]
        if last and LICENCE_FILE.fullmatch(last):
            continue
        if table is None:
            table, own = read_text(root, LICENSING).lower(), set()
            own = {o.lower() for o in gate_list(root, 'own-github-owners')}
        if owner.lower() not in own and f'{owner}/{repo}'.lower() not in table:
            return f'{owner}/{repo}'
    return None


def gate_list(root, name):
    """The entries (first words) under [name] in the gate lists."""
    entries, on = [], False
    for line in read_text(root, LISTS).splitlines():
        if line.startswith('['):
            on = line.strip() == f'[{name}]'
        elif on and line.strip() and not line.lstrip().startswith('#'):
            entries.append(line.split()[0])
    return entries


def read_text(root, rel):
    try:
        with open(os.path.join(root, rel), encoding='utf-8') as f:
            return f.read()
    except OSError:
        return ''


def refuse_unlicensed(project):
    answer('deny', f'{project} has no row in {LICENSING}. Read its licence first (gh api repos/{project}/license), '
                   'add its row, then read the rest; or ask the user.')


def changed_asked_files(root):
    r = subprocess.run(['git', '-C', root, 'status', '--porcelain=v1', '-z', '--untracked-files=all'],
                       capture_output=True, timeout=20)
    if r.returncode != 0:
        return ['(git status failed, so what the commit holds is unknown)']
    entries, paths = r.stdout.decode('utf-8', 'replace').split('\0'), []
    while entries:
        entry = entries.pop(0)
        if len(entry) > 3:
            paths.append(entry[3:])
            if 'R' in entry[:2] or 'C' in entry[:2]:
                paths.append(entries.pop(0))
    return [p for p in paths if asked(p)]


def main():
    event = json.load(sys.stdin)
    tool, given = event.get('tool_name', ''), event.get('tool_input') or {}
    root = os.environ.get('CLAUDE_PROJECT_DIR') or os.getcwd()
    if tool in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit'):
        rel = in_repo(given.get('file_path') or given.get('notebook_path') or '', root)
        if rel is not None and asked(rel):
            answer('ask', f'{rel} decides what the gates allow or how the hooks run; changing it is the user\'s call')
    elif tool in ('Bash', 'PowerShell'):
        command = given.get('command', '')
        if tool == 'PowerShell':
            command = command.replace('`', '')
        why = refusal(command)
        if why:
            answer('deny', why + '. Nothing may get past the hooks: fix what they refuse, or ask the user.')
        project = unlicensed([r for seg in segments(words_of(without_bodies(command))) for r in repos_read(seg)], root)
        if project:
            refuse_unlicensed(project)
        why = asks(command, root)
        if why:
            answer('ask', why)
    elif tool == 'WebFetch':
        project = unlicensed([m.groups() for m in GITHUB_URL.finditer(given.get('url', ''))], root)
        if project:
            refuse_unlicensed(project)


if __name__ == '__main__':
    main()
