#!/usr/bin/env bash
# Remove only deltas managed by Agent Resume History (AHR).
set -euo pipefail

TARGET_DIR="${AHR_HOME:-${HOME:-}/.local/share/agent-resume-history}"
AHR_BLOCK_START="# >>> agent-resume-history initialize >>>"
AHR_BLOCK_END="# <<< agent-resume-history initialize <<<"
HOOK_COMMAND='"${AHR_HOME:-$HOME/.local/share/agent-resume-history}/bin/agent-resume-history-hook" 2>/dev/null || :'
RUNTIME_FILES=(
    "bin/agent-resume-history-hook"
    "bin/agent-resume-history-record"
    "lib/agent-resume-history.sh"
    "adapters/pi-session.ts"
    "adapters/claude-settings.json"
    "adapters/codex-hooks.json"
    "adapters/traex-hooks.json"
    "shell/agent-resume-history.sh"
    "shell/agent-resume-history.fish"
)

[ -n "${HOME:-}" ] || { echo "Error: HOME must be set" >&2; exit 1; }
case "$TARGET_DIR" in /*) ;; *) echo "Error: AHR_HOME must be an absolute path" >&2; exit 1 ;; esac
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 is required" >&2; exit 1; }

# Validate every managed surface before removing the first one. This avoids a
# half-uninstall when a later rc block or hook file is malformed.
python3 - "$AHR_BLOCK_START" "$AHR_BLOCK_END" "$HOOK_COMMAND" "$TARGET_DIR" \
    "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.config/fish/config.fish" \
    -- "$HOME/.code/hooks.json" "$HOME/.codex/hooks.json" "$HOME/.trae/cli/hooks.json" "$HOME/.trae/hooks.json" <<'PY'
import json
import os
import pathlib
import sys

start, end, expected, target_raw = sys.argv[1:5]
separator = sys.argv.index("--")
rc_paths = [pathlib.Path(p) for p in sys.argv[5:separator]]
hook_paths = [pathlib.Path(p) for p in sys.argv[separator + 1:]]

def reject_symlink_components(path):
    path = path.absolute()
    while path != path.parent:
        if path.is_symlink() and os.access(path.parent, os.W_OK):
            print(f"Error: refusing user-writable symbolic-link component: {path}", file=sys.stderr)
            raise SystemExit(1)
        path = path.parent

target = pathlib.Path(target_raw)
reject_symlink_components(target)
for name in ("bin", "lib", "adapters", "shell", "run"):
    reject_symlink_components(target / name)
for path in rc_paths + hook_paths:
    reject_symlink_components(path)
for path in rc_paths:
    if not path.exists():
        continue
    if path.is_symlink() or not path.is_file():
        print(f"Error: refusing unsafe shell config path: {path}", file=sys.stderr)
        raise SystemExit(1)
    text = path.read_text(encoding="utf-8")
    starts, ends = text.count(start), text.count(end)
    if starts != ends or starts > 1 or (starts == 1 and text.index(start) > text.index(end)):
        print(f"Error: refusing malformed AHR block in {path}", file=sys.stderr)
        raise SystemExit(1)

for path in hook_paths:
    if not path.exists():
        continue
    if path.is_symlink() or not path.is_file():
        print(f"Error: refusing unsafe hook path: {path}", file=sys.stderr)
        raise SystemExit(1)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"Error: refusing invalid JSON in {path}: {exc}", file=sys.stderr)
        raise SystemExit(1)
    if not isinstance(data, dict):
        print(f"Error: refusing non-object JSON in {path}", file=sys.stderr)
        raise SystemExit(1)

if target.is_symlink():
    print(f"Error: refusing to remove symbolic-link install path: {target}", file=sys.stderr)
    raise SystemExit(1)

for path in rc_paths + hook_paths:
    if not path.exists():
        continue
    if not path.parent.is_dir() or not os.access(path.parent, os.W_OK):
        print(f"Error: containing directory is not writable: {path.parent}", file=sys.stderr)
        raise SystemExit(1)
if target.exists():
    if not target.is_dir():
        print(f"Error: expected install directory: {target}", file=sys.stderr)
        raise SystemExit(1)
    if not target.parent.is_dir() or not os.access(target.parent, os.W_OK):
        print(f"Error: containing directory is not writable: {target.parent}", file=sys.stderr)
        raise SystemExit(1)
PY

clean_rc() {
    local rc_file="$1"
    [ -f "$rc_file" ] || return 0
    python3 - "$rc_file" "$AHR_BLOCK_START" "$AHR_BLOCK_END" <<'PY'
import os
import pathlib
import stat
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
start, end = sys.argv[2:]
text = path.read_text(encoding="utf-8")
start_count, end_count = text.count(start), text.count(end)
if not start_count and not end_count:
    raise SystemExit(0)
if start_count != 1 or end_count != 1 or text.index(start) > text.index(end):
    print(f"Error: refusing malformed AHR block in {path}", file=sys.stderr)
    raise SystemExit(1)
before, rest = text.split(start, 1)
_, after = rest.split(end, 1)
if before.endswith("\n") and after.startswith("\n"):
    after = after[1:]
updated = before + after
mode = stat.S_IMODE(path.stat().st_mode)
fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.ahr.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.write(updated)
    os.chmod(temp_name, mode)
    os.replace(temp_name, path)
except BaseException:
    try:
        os.unlink(temp_name)
    except FileNotFoundError:
        pass
    raise
print(f"Removed AHR shell block: {path}")
PY
}

clean_hook() {
    local target="$1"
    [ -f "$target" ] || return 0
    python3 - "$target" "$HOOK_COMMAND" <<'PY'
import json
import os
import pathlib
import stat
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
expected = sys.argv[2]
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"Error: refusing invalid JSON in {path}: {exc}", file=sys.stderr)
    raise SystemExit(1)
if not isinstance(data, dict):
    print(f"Error: refusing non-object JSON in {path}", file=sys.stderr)
    raise SystemExit(1)
hooks = data.get("hooks")
if not isinstance(hooks, dict):
    raise SystemExit(0)
entries = hooks.get("SessionStart")
if not isinstance(entries, list):
    raise SystemExit(0)

def managed(hook):
    return (
        isinstance(hook, dict)
        and hook.get("type") == "command"
        and hook.get("command") == expected
    )

changed = False
updated = []
for group in entries:
    if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
        updated.append(group)
        continue
    nested = [hook for hook in group["hooks"] if not managed(hook)]
    if len(nested) == len(group["hooks"]):
        updated.append(group)
        continue
    changed = True
    if nested:
        group["hooks"] = nested
        updated.append(group)
    elif set(group) != {"hooks"}:
        group["hooks"] = nested
        updated.append(group)
if not changed:
    raise SystemExit(0)
hooks["SessionStart"] = updated
mode = stat.S_IMODE(path.stat().st_mode)
fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.ahr.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump(data, out, indent=2)
        out.write("\n")
    os.chmod(temp_name, mode)
    os.replace(temp_name, path)
except BaseException:
    try:
        os.unlink(temp_name)
    except FileNotFoundError:
        pass
    raise
print(f"Removed AHR hook: {path}")
PY
}

clean_rc "$HOME/.bashrc"
clean_rc "$HOME/.bash_profile"
clean_rc "$HOME/.zshrc"
clean_rc "$HOME/.config/fish/config.fish"
clean_hook "$HOME/.code/hooks.json"
clean_hook "$HOME/.codex/hooks.json"
clean_hook "$HOME/.trae/cli/hooks.json"
clean_hook "$HOME/.trae/hooks.json"

if [ -d "$TARGET_DIR" ] && [ ! -L "$TARGET_DIR" ]; then
    removed=0
    for rel in "${RUNTIME_FILES[@]}"; do
        if [ -e "$TARGET_DIR/$rel" ] || [ -L "$TARGET_DIR/$rel" ]; then
            rm -f "$TARGET_DIR/$rel"
            removed=1
        fi
    done
    for dir in bin lib adapters shell run; do
        rmdir "$TARGET_DIR/$dir" 2>/dev/null || :
    done
    rmdir "$TARGET_DIR" 2>/dev/null || :
    if [ "$removed" -eq 1 ]; then
        printf 'Removed managed install artifacts: %s\n' "$TARGET_DIR"
    fi
elif [ -L "$TARGET_DIR" ]; then
    printf 'Error: refusing to remove symbolic-link install path: %s\n' "$TARGET_DIR" >&2
    exit 1
fi

printf 'Agent Resume History uninstalled. Restart your shell.\n'
