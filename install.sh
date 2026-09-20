#!/usr/bin/env bash
# Install and verify Agent Resume History (AHR).
set -euo pipefail

AHR_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${AHR_HOME:-${HOME:-}/.local/share/agent-resume-history}"
AHR_BLOCK_START="# >>> agent-resume-history initialize >>>"
AHR_BLOCK_END="# <<< agent-resume-history initialize <<<"
HOOK_COMMAND='"${AHR_HOME:-$HOME/.local/share/agent-resume-history}/bin/agent-resume-history-hook" 2>/dev/null || :'
MODE="install"

usage() {
    cat <<'EOF'
Usage: ./install.sh [--dry-run | --verify]

  --dry-run  Validate prerequisites and existing hook JSON, then print the
             exact planned filesystem changes without making any changes.
  --verify   Read only: verify the installed files, shell blocks, and hooks.
EOF
}

if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi
if [ "$#" -eq 1 ]; then
    case "$1" in
        --dry-run) MODE="dry-run" ;;
        --verify) MODE="verify" ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
fi

BASH_RC="${HOME:-}/.bashrc"
BASH_PROFILE="${HOME:-}/.bash_profile"
ZSH_RC="${HOME:-}/.zshrc"
FISH_RC="${HOME:-}/.config/fish/config.fish"
HOOK_FILES=(
    "${HOME:-}/.code/hooks.json"
    "${HOME:-}/.codex/hooks.json"
    "${HOME:-}/.trae/cli/hooks.json"
    "${HOME:-}/.trae/hooks.json"
)
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

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

nearest_existing_parent() {
    local path="$1"
    while [ ! -e "$path" ]; do
        local parent
        parent="$(dirname "$path")"
        [ "$parent" != "$path" ] || break
        path="$parent"
    done
    printf '%s\n' "$path"
}

reject_symlink_components() {
    local path="$1"
    while [ "$path" != "/" ]; do
        if [ -L "$path" ] && [ -w "$(dirname "$path")" ]; then
            fail "path contains a user-writable symbolic-link component and will not be modified: $path"
        fi
        path="$(dirname "$path")"
    done
}

validate_destination() {
    local path="$1"
    local kind="$2"
    reject_symlink_components "$path"
    if [ -L "$path" ]; then
        fail "$kind is a symbolic link and will not be modified: $path"
    fi
    if [ -e "$path" ]; then
        [ -w "$path" ] || fail "$kind is not writable: $path"
        if [ "$kind" = "file" ]; then
            [ -f "$path" ] || fail "expected a regular file: $path"
            [ -r "$path" ] || fail "$kind is not readable: $path"
        else
            [ -d "$path" ] || fail "expected a directory: $path"
        fi
    else
        local parent
        parent="$(nearest_existing_parent "$(dirname "$path")")"
        [ -d "$parent" ] && [ -w "$parent" ] || fail "cannot create $path (nearest parent is not writable: $parent)"
    fi
}

validate_rc_blocks() {
    python3 - "$AHR_BLOCK_START" "$AHR_BLOCK_END" "$@" <<'PY'
import pathlib
import sys

start, end, *paths = sys.argv[1:]
for raw_path in paths:
    path = pathlib.Path(raw_path)
    if not path.exists():
        continue
    if path.is_symlink() or not path.is_file():
        print(f"Error: unsafe shell config path: {path}", file=sys.stderr)
        raise SystemExit(1)
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as exc:
        print(f"Error: cannot read shell config {path}: {exc}", file=sys.stderr)
        raise SystemExit(1)
    starts = text.count(start)
    ends = text.count(end)
    if starts != ends or starts > 1 or (starts == 1 and text.index(start) > text.index(end)):
        print(f"Error: malformed or duplicate AHR managed block in {path}", file=sys.stderr)
        raise SystemExit(1)
PY
}

validate_hooks_json() {
    python3 - "$AHR_SOURCE_DIR/adapters/codex-hooks.json" "$AHR_SOURCE_DIR/adapters/traex-hooks.json" "$@" <<'PY'
import json
import pathlib
import sys

templates = [pathlib.Path(p) for p in sys.argv[1:3]]
targets = [pathlib.Path(p) for p in sys.argv[3:]]
for path in templates:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        entries = data["hooks"]["SessionStart"]
        if not isinstance(entries, list) or not entries:
            raise ValueError("SessionStart must be a non-empty list")
    except Exception as exc:
        print(f"Error: invalid hook template {path}: {exc}", file=sys.stderr)
        raise SystemExit(1)
for path in targets:
    if not path.exists():
        continue
    if path.is_symlink() or not path.is_file():
        print(f"Error: unsafe hook path: {path}", file=sys.stderr)
        raise SystemExit(1)
    try:
        raw = path.read_text(encoding="utf-8")
    except Exception as exc:
        print(f"Error: {path} cannot be read: {exc}", file=sys.stderr)
        raise SystemExit(1)
    if not raw.strip():
        continue
    try:
        data = json.loads(raw)
    except Exception as exc:
        print(f"Error: {path} contains invalid JSON: {exc}", file=sys.stderr)
        raise SystemExit(1)
    if not isinstance(data, dict):
        print(f"Error: {path} root must be a JSON object", file=sys.stderr)
        raise SystemExit(1)
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        print(f"Error: {path} field 'hooks' must be an object", file=sys.stderr)
        raise SystemExit(1)
    session_start = hooks.get("SessionStart", [])
    if not isinstance(session_start, list):
        print(f"Error: {path} field 'hooks.SessionStart' must be an array", file=sys.stderr)
        raise SystemExit(1)
PY
}

preflight() {
    [ -n "${HOME:-}" ] || fail "HOME must be set"
    case "$HOME" in /*) ;; *) fail "HOME must be an absolute path" ;; esac
    case "$TARGET_DIR" in /*) ;; *) fail "AHR_HOME must be an absolute path" ;; esac
    local prerequisite
    for prerequisite in bash fish zsh bun python3; do
        command -v "$prerequisite" >/dev/null 2>&1 || fail "$prerequisite is required"
    done

    local rel
    for rel in "${RUNTIME_FILES[@]}"; do
        [ -f "$AHR_SOURCE_DIR/$rel" ] || fail "required source artifact is missing: $AHR_SOURCE_DIR/$rel"
        [ -r "$AHR_SOURCE_DIR/$rel" ] || fail "required source artifact is unreadable: $AHR_SOURCE_DIR/$rel"
    done

    local path
    for path in "$BASH_RC" "$ZSH_RC" "$FISH_RC" "${HOOK_FILES[@]}"; do
        validate_destination "$path" file
    done
    if [ -e "$BASH_PROFILE" ] || [ -L "$BASH_PROFILE" ]; then
        validate_destination "$BASH_PROFILE" file
    fi
    validate_destination "$TARGET_DIR" directory
    for path in "$TARGET_DIR/bin" "$TARGET_DIR/lib" "$TARGET_DIR/adapters" "$TARGET_DIR/shell"; do
        validate_destination "$path" directory
    done
    for rel in "${RUNTIME_FILES[@]}"; do
        validate_destination "$TARGET_DIR/$rel" file
    done
    validate_rc_blocks "$BASH_RC" "$BASH_PROFILE" "$ZSH_RC" "$FISH_RC"
    validate_hooks_json "${HOOK_FILES[@]}"
}

print_plan() {
    printf 'Dry run: validation passed; no files were changed.\n'
    printf 'Install target: %s\n' "$TARGET_DIR"
    local rel
    for rel in "${RUNTIME_FILES[@]}"; do
        printf 'PLAN copy: %s -> %s/%s\n' "$AHR_SOURCE_DIR/$rel" "$TARGET_DIR" "$rel"
    done
    printf 'PLAN configure shell: %s -> source %s/shell/agent-resume-history.sh\n' "$BASH_RC" "$TARGET_DIR"
    if [ -e "$BASH_PROFILE" ]; then
        printf 'PLAN configure shell: %s -> source %s/shell/agent-resume-history.sh\n' "$BASH_PROFILE" "$TARGET_DIR"
    fi
    printf 'PLAN configure shell: %s -> source %s/shell/agent-resume-history.sh\n' "$ZSH_RC" "$TARGET_DIR"
    printf 'PLAN configure shell: %s -> source %s/shell/agent-resume-history.fish\n' "$FISH_RC" "$TARGET_DIR"
    local hook_file
    for hook_file in "${HOOK_FILES[@]}"; do
        printf 'PLAN merge hook: %s -> hooks.SessionStart\n' "$hook_file"
    done
    printf 'MANUAL after install: review and approve Codex/Traex hooks with /hooks.\n'
}

inject_rc() {
    local rc_file="$1"
    local source_file="$2"
    local syntax="$3"
    mkdir -p "$(dirname "$rc_file")"
    touch "$rc_file"
    if grep -qF "$AHR_BLOCK_START" "$rc_file" 2>/dev/null; then
        python3 - "$rc_file" "$AHR_BLOCK_START" "$AHR_BLOCK_END" "$source_file" "$syntax" <<'PY'
import os
import pathlib
import stat
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
start, end, source, syntax = sys.argv[2:]
text = path.read_text(encoding="utf-8")
before, rest = text.split(start, 1)
_, after = rest.split(end, 1)
if syntax == "fish":
    body = f'{start}\nif test -f "{source}"\n    source "{source}"\nend\n{end}'
else:
    body = f'{start}\nif [ -f "{source}" ]; then\n    . "{source}"\nfi\n{end}'
updated = before + body + after
if updated == text:
    print(f"Already configured: {path}")
    raise SystemExit(0)
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
print(f"Updated: {path}")
PY
        return
    fi
    if [ "$syntax" = "fish" ]; then
        cat >>"$rc_file" <<EOF

$AHR_BLOCK_START
if test -f "$source_file"
    source "$source_file"
end
$AHR_BLOCK_END
EOF
    else
        cat >>"$rc_file" <<EOF

$AHR_BLOCK_START
if [ -f "$source_file" ]; then
    . "$source_file"
fi
$AHR_BLOCK_END
EOF
    fi
    printf 'Configured: %s\n' "$rc_file"
}

merge_hook() {
    local target="$1"
    local template="$2"
    mkdir -p "$(dirname "$target")"
    python3 - "$target" "$template" <<'PY'
import json
import os
import pathlib
import stat
import sys
import tempfile

target = pathlib.Path(sys.argv[1])
template = pathlib.Path(sys.argv[2])
raw = target.read_text(encoding="utf-8") if target.exists() else ""
data = json.loads(raw) if raw.strip() else {}
entry = json.loads(template.read_text(encoding="utf-8"))["hooks"]["SessionStart"][0]
expected_hook = entry["hooks"][0]
expected_command = expected_hook["command"]
session_start = data.setdefault("hooks", {}).setdefault("SessionStart", [])

def managed(hook):
    return (
        isinstance(hook, dict)
        and hook.get("type") == "command"
        and hook.get("command") == expected_command
    )

found = False
changed = False
updated_groups = []
for group in session_start:
    if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
        updated_groups.append(group)
        continue
    nested = []
    for hook in group["hooks"]:
        if not managed(hook):
            nested.append(hook)
            continue
        if not found:
            nested.append(expected_hook)
            found = True
            changed = changed or hook != expected_hook
        else:
            changed = True
    if nested != group["hooks"]:
        group["hooks"] = nested
    if nested or set(group) != {"hooks"}:
        updated_groups.append(group)
    else:
        changed = True

if found:
    session_start[:] = updated_groups
    if not changed:
        print(f"Already configured: {target}")
        raise SystemExit(0)
else:
    session_start.append(entry)
old_mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o600
fd, temp_name = tempfile.mkstemp(prefix=f".{target.name}.ahr.", dir=target.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump(data, out, indent=2)
        out.write("\n")
    os.chmod(temp_name, old_mode)
    os.replace(temp_name, target)
except BaseException:
    try:
        os.unlink(temp_name)
    except FileNotFoundError:
        pass
    raise
print(f"Configured: {target}")
PY
}

verify_install() {
    local failures=0
    local rel
    for rel in "${RUNTIME_FILES[@]}"; do
        if [ ! -f "$TARGET_DIR/$rel" ]; then
            printf 'FAIL artifact missing: %s\n' "$TARGET_DIR/$rel" >&2
            failures=$((failures + 1))
        elif cmp -s "$AHR_SOURCE_DIR/$rel" "$TARGET_DIR/$rel"; then
            printf 'PASS artifact: %s\n' "$TARGET_DIR/$rel"
        else
            printf 'FAIL artifact differs from release: %s\n' "$TARGET_DIR/$rel" >&2
            failures=$((failures + 1))
        fi
    done
    for rel in bin/agent-resume-history-hook bin/agent-resume-history-record; do
        if [ -x "$TARGET_DIR/$rel" ]; then
            printf 'PASS executable: %s\n' "$TARGET_DIR/$rel"
        else
            printf 'FAIL not executable: %s\n' "$TARGET_DIR/$rel" >&2
            failures=$((failures + 1))
        fi
    done

    local rc_file source_file
    while IFS='|' read -r rc_file source_file; do
        [ -n "$rc_file" ] || continue
        if python3 - "$rc_file" "$AHR_BLOCK_START" "$AHR_BLOCK_END" "$source_file" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
start, end, source = sys.argv[2:]
if not path.is_file():
    raise SystemExit(1)
text = path.read_text(encoding="utf-8")
if text.count(start) != 1 or text.count(end) != 1 or text.index(start) > text.index(end):
    raise SystemExit(1)
managed = text.split(start, 1)[1].split(end, 1)[0]
raise SystemExit(0 if source in managed else 1)
PY
        then
            printf 'PASS shell block: %s\n' "$rc_file"
        else
            printf 'FAIL shell block: %s\n' "$rc_file" >&2
            failures=$((failures + 1))
        fi
    done <<EOF
$BASH_RC|$TARGET_DIR/shell/agent-resume-history.sh
$(if [ -e "$BASH_PROFILE" ]; then printf '%s|%s\n' "$BASH_PROFILE" "$TARGET_DIR/shell/agent-resume-history.sh"; fi)
$ZSH_RC|$TARGET_DIR/shell/agent-resume-history.sh
$FISH_RC|$TARGET_DIR/shell/agent-resume-history.fish
EOF

    local hook_file
    for hook_file in "${HOOK_FILES[@]}"; do
        if python3 - "$hook_file" "$HOOK_COMMAND" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
expected = sys.argv[2]
try:
    data = json.loads(path.read_text(encoding="utf-8"))
    entries = data["hooks"]["SessionStart"]
    matches = [
        hook
        for group in entries if isinstance(group, dict)
        for hook in group.get("hooks", []) if isinstance(group.get("hooks", []), list) and isinstance(hook, dict)
        if hook.get("type") == "command" and hook.get("command") == expected
    ]
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if len(matches) == 1 else 1)
PY
        then
            printf 'PASS hook registration: %s\n' "$hook_file"
        else
            printf 'FAIL hook registration: %s\n' "$hook_file" >&2
            failures=$((failures + 1))
        fi
    done

    printf 'MANUAL hook trust: open Codex and Traex, run /hooks, and approve the registered hook if prompted.\n'
    if [ "$failures" -ne 0 ]; then
        printf 'Verification failed: %d machine-checkable problem(s).\n' "$failures" >&2
        return 1
    fi
    printf 'Verification passed: installed artifacts and registrations are complete.\n'
}

if [ "$MODE" = "verify" ]; then
    command -v python3 >/dev/null 2>&1 || fail "python3 is required"
    verify_install
    exit $?
fi

preflight
if [ "$MODE" = "dry-run" ]; then
    print_plan
    exit 0
fi

printf 'Installing Agent Resume History (AHR) to %s\n' "$TARGET_DIR"
mkdir -p "$TARGET_DIR"
for rel in "${RUNTIME_FILES[@]}"; do
    mkdir -p "$TARGET_DIR/$(dirname "$rel")"
    cp "$AHR_SOURCE_DIR/$rel" "$TARGET_DIR/$rel"
done
chmod +x "$TARGET_DIR/bin/agent-resume-history-hook" "$TARGET_DIR/bin/agent-resume-history-record"

inject_rc "$BASH_RC" "$TARGET_DIR/shell/agent-resume-history.sh" posix
if [ -e "$BASH_PROFILE" ]; then
    inject_rc "$BASH_PROFILE" "$TARGET_DIR/shell/agent-resume-history.sh" posix
fi
inject_rc "$ZSH_RC" "$TARGET_DIR/shell/agent-resume-history.sh" posix
inject_rc "$FISH_RC" "$TARGET_DIR/shell/agent-resume-history.fish" fish

merge_hook "${HOOK_FILES[0]}" "$TARGET_DIR/adapters/codex-hooks.json"
merge_hook "${HOOK_FILES[1]}" "$TARGET_DIR/adapters/codex-hooks.json"
merge_hook "${HOOK_FILES[2]}" "$TARGET_DIR/adapters/traex-hooks.json"
merge_hook "${HOOK_FILES[3]}" "$TARGET_DIR/adapters/traex-hooks.json"

verify_install
cat <<EOF

Agent Resume History v0.1.0 installed successfully.
Next steps:
  1. Restart Bash/Zsh/Fish, or source its configured rc file.
  2. In Codex and Traex, run /hooks and approve the AHR hook if prompted.
  3. Smoke test: start omp, exit it, press Up, and confirm:
       omp --resume <session-uuid>
  4. Recheck at any time with: $AHR_SOURCE_DIR/install.sh --verify
EOF
