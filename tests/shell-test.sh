#!/usr/bin/env bash
# tests/shell-test.sh - Focused integration tests for Fish, Bash, and Zsh wrappers & installer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

for prerequisite in bash zsh fish python3 bun; do
    if ! command -v "$prerequisite" >/dev/null 2>&1; then
        echo "ERROR: '$prerequisite' is required for shell integration tests." >&2
        exit 1
    fi
done

echo "Running Agent Resume History (AHR) shell & installer integration tests..."

TMP_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_TEST_DIR"' EXIT INT TERM

TEST_HOME="$TMP_TEST_DIR/home"
TEST_AHR_HOME="$TMP_TEST_DIR/ahr_install"
mkdir -p "$TEST_HOME" "$TEST_AHR_HOME"

export HOME="$TEST_HOME"
export AHR_HOME="$TEST_AHR_HOME"
export AHR_FORCE_INTERACTIVE="1"

# -------------------------------------------------------------
# 1. Test install.sh
# -------------------------------------------------------------
echo "==> 1. Testing install.sh in clean HOME"

# Pre-populate current and legacy Code hooks plus Trae to test non-destructive merge
mkdir -p "$HOME/.code" "$HOME/.codex" "$HOME/.trae/cli" "$HOME/.config/fish"
cat > "$HOME/.code/hooks.json" << 'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "type": "command", "command": "echo existing_code_hook" }
    ],
    "SessionStart": [
      {
        "matcher": "custom",
        "hooks": [
          {
            "type": "command",
            "command": "\"${AHR_HOME:-$HOME/.local/share/agent-resume-history}/bin/agent-resume-history-hook\" 2>/dev/null || :",
            "timeout": 5
          },
          { "type": "command", "command": "echo existing_session_sibling" }
        ]
      }
    ]
  }
}
EOF

cat > "$HOME/.codex/hooks.json" << 'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "type": "command", "command": "echo existing_pre_hook" }
    ]
  }
}
EOF

cat > "$HOME/.trae/cli/hooks.json" << 'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "type": "command", "command": "echo existing_trae_hook" }
    ]
  }
}
EOF


# Dry-run must validate and report exact targets without creating anything.
DRY_HOME="$TMP_TEST_DIR/dry_home"
DRY_AHR_HOME="$TMP_TEST_DIR/dry_install"
mkdir -p "$DRY_HOME"
DRY_BEFORE="$TMP_TEST_DIR/dry_before.txt"
DRY_AFTER="$TMP_TEST_DIR/dry_after.txt"
python3 - "$DRY_HOME" "$DRY_AHR_HOME" "$DRY_BEFORE" <<'PYEOF'
import hashlib, pathlib, sys
roots = [pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])]
out = pathlib.Path(sys.argv[3])
rows = []
for root in roots:
    rows.append(f"ROOT {root} {root.exists()}")
    if root.exists():
        for path in sorted(root.rglob("*")):
            digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "-"
            rows.append(f"{path.relative_to(root)} {path.stat().st_mode:o} {digest}")
out.write_text("\n".join(rows) + "\n")
PYEOF
DRY_OUTPUT=$(HOME="$DRY_HOME" AHR_HOME="$DRY_AHR_HOME" "$WORKSPACE_ROOT/install.sh" --dry-run)
python3 - "$DRY_HOME" "$DRY_AHR_HOME" "$DRY_AFTER" <<'PYEOF'
import hashlib, pathlib, sys
roots = [pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])]
out = pathlib.Path(sys.argv[3])
rows = []
for root in roots:
    rows.append(f"ROOT {root} {root.exists()}")
    if root.exists():
        for path in sorted(root.rglob("*")):
            digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "-"
            rows.append(f"{path.relative_to(root)} {path.stat().st_mode:o} {digest}")
out.write_text("\n".join(rows) + "\n")
PYEOF
cmp -s "$DRY_BEFORE" "$DRY_AFTER" || { echo "FAIL: --dry-run mutated filesystem state"; exit 1; }
printf '%s\n' "$DRY_OUTPUT" | grep -qF "PLAN copy: $WORKSPACE_ROOT/bin/agent-resume-history-hook -> $DRY_AHR_HOME/bin/agent-resume-history-hook" || { echo "FAIL: --dry-run omitted exact hook target"; exit 1; }
printf '%s\n' "$DRY_OUTPUT" | grep -qF "PLAN configure shell: $DRY_HOME/.bashrc -> source $DRY_AHR_HOME/shell/agent-resume-history.sh" || { echo "FAIL: --dry-run omitted exact shell target"; exit 1; }
printf '%s\n' "$DRY_OUTPUT" | grep -qF "PLAN merge hook: $DRY_HOME/.code/hooks.json -> hooks.SessionStart" || { echo "FAIL: --dry-run omitted exact hook JSON target"; exit 1; }
# Installation copies only the declared runtime allowlist, never extra source
# artifacts that happen to sit beside a managed binary.
UNLISTED_SOURCE="$WORKSPACE_ROOT/bin/.ahr-unlisted-test"
trap 'rm -f "$UNLISTED_SOURCE"; rm -rf "$TMP_TEST_DIR"' EXIT INT TERM
printf 'must not install\n' > "$UNLISTED_SOURCE"

# The install root itself must never be followed when it is a symbolic link.
SYMLINK_HOME="$TMP_TEST_DIR/symlink_home"
SYMLINK_REAL_TARGET="$TMP_TEST_DIR/symlink_real_target"
SYMLINK_AHR_HOME="$TMP_TEST_DIR/symlink_install"
mkdir -p "$SYMLINK_HOME" "$SYMLINK_REAL_TARGET"
ln -s "$SYMLINK_REAL_TARGET" "$SYMLINK_AHR_HOME"
set +e
HOME="$SYMLINK_HOME" AHR_HOME="$SYMLINK_AHR_HOME" "$WORKSPACE_ROOT/install.sh" --dry-run >/dev/null 2>&1
SYMLINK_DRY_STATUS=$?
set -e
[ "$SYMLINK_DRY_STATUS" -ne 0 ] || { echo "FAIL: --dry-run accepted a symbolic-link install root"; exit 1; }
set +e
HOME="$SYMLINK_HOME" AHR_HOME="$SYMLINK_AHR_HOME" "$WORKSPACE_ROOT/install.sh" >/dev/null 2>&1
SYMLINK_INSTALL_STATUS=$?
set -e
[ "$SYMLINK_INSTALL_STATUS" -ne 0 ] || { echo "FAIL: install accepted a symbolic-link install root"; exit 1; }
[ -z "$(find "$SYMLINK_REAL_TARGET" -mindepth 1 -print -quit)" ] || { echo "FAIL: symlink target was mutated"; exit 1; }

set +e
"$WORKSPACE_ROOT/install.sh" --unknown >/dev/null 2>&1
UNKNOWN_STATUS=$?
set -e
[ "$UNKNOWN_STATUS" -eq 2 ] || { echo "FAIL: unknown option did not exit 2"; exit 1; }

set +e
"$WORKSPACE_ROOT/install.sh" --verify >/dev/null 2>&1
PREINSTALL_VERIFY_STATUS=$?
set -e
[ ! -e "$TEST_AHR_HOME/bin/.ahr-unlisted-test" ] || { echo "FAIL: installer copied an unlisted source artifact"; exit 1; }
rm -f "$UNLISTED_SOURCE"
[ "$PREINSTALL_VERIFY_STATUS" -ne 0 ] || { echo "FAIL: --verify passed before installation"; exit 1; }
echo "  [OK] Strict options, dry-run no-mutation, deterministic plan, and failing pre-install verify"
"$WORKSPACE_ROOT/install.sh"

VERIFY_OUTPUT=$("$WORKSPACE_ROOT/install.sh" --verify)
printf '%s\n' "$VERIFY_OUTPUT" | grep -qF "Verification passed: installed artifacts and registrations are complete." || { echo "FAIL: --verify omitted success summary"; exit 1; }
printf '%s\n' "$VERIFY_OUTPUT" | grep -qF "MANUAL hook trust:" || { echo "FAIL: --verify claimed or omitted manual hook trust state"; exit 1; }

# Verify is read-only: hash the complete isolated HOME and install tree before/after.
VERIFY_BEFORE="$TMP_TEST_DIR/verify_before.txt"
VERIFY_AFTER="$TMP_TEST_DIR/verify_after.txt"
python3 - "$HOME" "$AHR_HOME" "$VERIFY_BEFORE" <<'PYEOF'
import hashlib, pathlib, sys
rows = []
for root in map(pathlib.Path, sys.argv[1:3]):
    for path in sorted(root.rglob("*")):
        digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "-"
        rows.append(f"{root}|{path.relative_to(root)}|{path.stat().st_mode:o}|{digest}")
pathlib.Path(sys.argv[3]).write_text("\n".join(rows) + "\n")
PYEOF
"$WORKSPACE_ROOT/install.sh" --verify >/dev/null
python3 - "$HOME" "$AHR_HOME" "$VERIFY_AFTER" <<'PYEOF'
import hashlib, pathlib, sys
rows = []
for root in map(pathlib.Path, sys.argv[1:3]):
    for path in sorted(root.rglob("*")):
        digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "-"
        rows.append(f"{root}|{path.relative_to(root)}|{path.stat().st_mode:o}|{digest}")
pathlib.Path(sys.argv[3]).write_text("\n".join(rows) + "\n")
PYEOF
cmp -s "$VERIFY_BEFORE" "$VERIFY_AFTER" || { echo "FAIL: --verify mutated filesystem state"; exit 1; }
echo "  [OK] Verify is read-only and separates machine checks from manual trust"

# Verify files copied into AHR_HOME
for f in bin/agent-resume-history-hook bin/agent-resume-history-record lib/agent-resume-history.sh adapters/pi-session.ts adapters/claude-settings.json adapters/codex-hooks.json adapters/traex-hooks.json shell/agent-resume-history.sh shell/agent-resume-history.fish; do
    if [ ! -f "$TEST_AHR_HOME/$f" ]; then
        echo "FAIL: $TEST_AHR_HOME/$f not found after install"
        exit 1
    fi
done
echo "  [OK] Installed artifact tree verified"

# Verify idempotency before exercising an AHR_HOME path migration.
"$WORKSPACE_ROOT/install.sh" >/dev/null
# Reinstalling with a new absolute AHR_HOME must update managed rc source
# paths rather than silently preserving the previous install location.
ORIGINAL_AHR_HOME="$AHR_HOME"
MOVED_AHR_HOME="$TMP_TEST_DIR/ahr_install_moved"
AHR_HOME="$MOVED_AHR_HOME" "$WORKSPACE_ROOT/install.sh" >/dev/null
grep -qF "$MOVED_AHR_HOME/shell/agent-resume-history.sh" "$HOME/.bashrc" || { echo "FAIL: reinstall did not update Bash source path"; exit 1; }
grep -qF "$MOVED_AHR_HOME/shell/agent-resume-history.fish" "$HOME/.config/fish/config.fish" || { echo "FAIL: reinstall did not update Fish source path"; exit 1; }
grep -qF "$ORIGINAL_AHR_HOME/shell/agent-resume-history.sh" "$HOME/.bashrc" && { echo "FAIL: old Bash source path remained after reinstall"; exit 1; }
python3 - "$HOME/.code/hooks.json" <<'PYEOF'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
managed = [group for group in data["hooks"]["SessionStart"] if "agent-resume-history-hook" in json.dumps(group)]
assert len(managed) == 1, f"Expected one AHR hook after reinstall, got {len(managed)}"
PYEOF
rm -rf "$MOVED_AHR_HOME"
AHR_HOME="$ORIGINAL_AHR_HOME" "$WORKSPACE_ROOT/install.sh" >/dev/null
echo "  [OK] Reinstall updates managed shell paths for a changed AHR_HOME"

# A machine-checkable drift must make verification fail without repairing it.
chmod -x "$TEST_AHR_HOME/bin/agent-resume-history-record"
set +e
DRIFT_OUTPUT=$("$WORKSPACE_ROOT/install.sh" --verify 2>&1)
DRIFT_STATUS=$?
set -e
[ "$DRIFT_STATUS" -ne 0 ] || { echo "FAIL: --verify passed with a non-executable recorder"; exit 1; }
printf '%s\n' "$DRIFT_OUTPUT" | grep -qF "FAIL not executable: $TEST_AHR_HOME/bin/agent-resume-history-record" || { echo "FAIL: --verify did not identify recorder drift"; exit 1; }
[ ! -x "$TEST_AHR_HOME/bin/agent-resume-history-record" ] || { echo "FAIL: --verify repaired state instead of remaining read-only"; exit 1; }
chmod +x "$TEST_AHR_HOME/bin/agent-resume-history-record"

# Installed content drift is a machine-checkable failure and remains untouched.
printf '\n# drift\n' >> "$TEST_AHR_HOME/shell/agent-resume-history.sh"
set +e
CONTENT_DRIFT_OUTPUT=$("$WORKSPACE_ROOT/install.sh" --verify 2>&1)
CONTENT_DRIFT_STATUS=$?
set -e
[ "$CONTENT_DRIFT_STATUS" -ne 0 ] || { echo "FAIL: --verify passed with changed installed content"; exit 1; }
printf '%s\n' "$CONTENT_DRIFT_OUTPUT" | grep -qF "FAIL artifact differs from release: $TEST_AHR_HOME/shell/agent-resume-history.sh" || { echo "FAIL: --verify did not identify artifact content drift"; exit 1; }
grep -qF '# drift' "$TEST_AHR_HOME/shell/agent-resume-history.sh" || { echo "FAIL: --verify repaired artifact content"; exit 1; }
cp "$WORKSPACE_ROOT/shell/agent-resume-history.sh" "$TEST_AHR_HOME/shell/agent-resume-history.sh"
echo "  [OK] Verify detects installed artifact content drift without mutation"
echo "  [OK] Verify returns nonzero on machine-checkable drift without mutation"
# Check that rc files have only 1 AHR block
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.config/fish/config.fish"; do
    count=$(grep -c "# >>> agent-resume-history initialize >>>" "$rc" || :)
    if [ "$count" -ne 1 ]; then
        echo "FAIL: $rc contains $count AHR blocks (expected 1)"
        exit 1
    fi
done
echo "  [OK] RC files idempotently configured with single block"

# Verify both Code paths and Trae preserved existing hooks and added one SessionStart entry
python3 - <<PYEOF
import json

for path in ("$HOME/.code/hooks.json", "$HOME/.codex/hooks.json"):
    with open(path) as f:
        code_hooks = json.load(f)
    assert "PreToolUse" in code_hooks["hooks"], f"Code PreToolUse lost from {path}!"
    assert len(code_hooks["hooks"].get("SessionStart", [])) == 1, f"Code AHR hook not idempotent in {path}!"
with open("$HOME/.code/hooks.json") as f:
    mixed = json.load(f)["hooks"]["SessionStart"]
assert len(mixed) == 1, f"Mixed SessionStart group was split: {mixed}"
assert mixed[0].get("matcher") == "custom", f"Mixed group matcher was lost: {mixed}"
commands = [hook.get("command") for hook in mixed[0]["hooks"]]
assert "echo existing_session_sibling" in commands, f"Mixed group sibling was lost: {mixed}"
assert sum("agent-resume-history-hook" in command for command in commands) == 1, f"Managed hook was not deduplicated: {mixed}"

with open("$HOME/.trae/cli/hooks.json") as f:
    trae_hooks = json.load(f)
assert "PreToolUse" in trae_hooks["hooks"], "Trae PreToolUse lost!"
assert len(trae_hooks["hooks"].get("SessionStart", [])) == 1, "Trae AHR hook not idempotent!"
print("  [OK] Hooks JSON merged cleanly and preserved existing hooks")
PYEOF

# Verify malformed existing hooks.json causes failure and preflight ensures zero mutations
echo "==> 1b. Testing malformed and non-object hooks.json handling in install.sh"

SNAPSHOT_DIR="$TMP_TEST_DIR/snapshot_1b"

snapshot_state() {
    local invalid_target="$1"
    rm -rf "$SNAPSHOT_DIR"
    mkdir -p "$SNAPSHOT_DIR"
    cp -R "$AHR_HOME" "$SNAPSHOT_DIR/ahr_target"
    cp "$HOME/.bashrc" "$SNAPSHOT_DIR/bashrc"
    cp "$HOME/.zshrc" "$SNAPSHOT_DIR/zshrc"
    cp "$HOME/.config/fish/config.fish" "$SNAPSHOT_DIR/fish_config"
    cp "$invalid_target" "$SNAPSHOT_DIR/invalid_hooks"
}

assert_non_mutating() {
    local invalid_target="$1"
    local desc="$2"
    if ! cmp -s "$SNAPSHOT_DIR/invalid_hooks" "$invalid_target"; then
        echo "FAIL: invalid hook file $invalid_target was modified after failed install ($desc)"
        exit 1
    fi
    if ! cmp -s "$SNAPSHOT_DIR/bashrc" "$HOME/.bashrc"; then
        echo "FAIL: ~/.bashrc was modified after failed install ($desc)"
        exit 1
    fi
    if ! cmp -s "$SNAPSHOT_DIR/zshrc" "$HOME/.zshrc"; then
        echo "FAIL: ~/.zshrc was modified after failed install ($desc)"
        exit 1
    fi
    if ! cmp -s "$SNAPSHOT_DIR/fish_config" "$HOME/.config/fish/config.fish"; then
        echo "FAIL: fish config was modified after failed install ($desc)"
        exit 1
    fi
    if ! diff -r "$SNAPSHOT_DIR/ahr_target" "$AHR_HOME" >/dev/null 2>&1; then
        echo "FAIL: AHR target directory was modified after failed install ($desc)"
        exit 1
    fi
}

# Test 1: Malformed JSON syntax in ~/.code/hooks.json
BAD_HOOKS_CONTENT="{\ninvalid_json: true,\n"
printf "%b" "$BAD_HOOKS_CONTENT" > "$HOME/.code/hooks.json"
snapshot_state "$HOME/.code/hooks.json"

set +e
"$WORKSPACE_ROOT/install.sh" >/dev/null 2>&1
INSTALL_STATUS=$?
set -e

if [ "$INSTALL_STATUS" -eq 0 ]; then
    echo "FAIL: install.sh succeeded on malformed hooks.json (expected non-zero)"
    exit 1
fi
assert_non_mutating "$HOME/.code/hooks.json" "malformed JSON syntax"

# Test 2: Non-object JSON root in ~/.code/hooks.json
printf "[\"not\", \"a\", \"json\", \"object\"]\n" > "$HOME/.code/hooks.json"
snapshot_state "$HOME/.code/hooks.json"

set +e
"$WORKSPACE_ROOT/install.sh" >/dev/null 2>&1
NON_OBJ_STATUS=$?
set -e

if [ "$NON_OBJ_STATUS" -eq 0 ]; then
    echo "FAIL: install.sh succeeded on non-object root hooks.json (expected non-zero)"
    exit 1
fi
assert_non_mutating "$HOME/.code/hooks.json" "non-object JSON root"

# Test 3: Later hook target ~/.trae/hooks.json malformed does not mutate earlier configs or target
cat > "$HOME/.code/hooks.json" << 'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "type": "command", "command": "echo existing_code_hook" }
    ]
  }
}
EOF
printf "%b" "$BAD_HOOKS_CONTENT" > "$HOME/.trae/hooks.json"
snapshot_state "$HOME/.trae/hooks.json"

set +e
"$WORKSPACE_ROOT/install.sh" >/dev/null 2>&1
LATER_STATUS=$?
set -e

if [ "$LATER_STATUS" -eq 0 ]; then
    echo "FAIL: install.sh succeeded when later ~/.trae/hooks.json was malformed"
    exit 1
fi
assert_non_mutating "$HOME/.trae/hooks.json" "malformed later hook target"
rm -f "$HOME/.trae/hooks.json"

# Test 4: Missing/empty configs remain allowed (empty hooks file)
touch "$HOME/.trae/hooks.json"
"$WORKSPACE_ROOT/install.sh" >/dev/null
python3 - <<PYEOF
import json
with open("$HOME/.trae/hooks.json") as f:
    trae_root = json.load(f)
assert isinstance(trae_root, dict), "~/.trae/hooks.json root must be object"
assert len(trae_root["hooks"].get("SessionStart", [])) == 1, "SessionStart not added to empty hooks.json"
PYEOF
rm -f "$HOME/.trae/hooks.json"

echo "  [OK] Preflight correctly prevented mutations on malformed/non-object hooks JSON"

# Restore valid hooks.json for subsequent tests
cat > "$HOME/.code/hooks.json" << 'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "type": "command", "command": "echo existing_code_hook" }
    ],
    "SessionStart": [
      {
        "matcher": "custom",
        "hooks": [
          {
            "type": "command",
            "command": "\"${AHR_HOME:-$HOME/.local/share/agent-resume-history}/bin/agent-resume-history-hook\" 2>/dev/null || :",
            "timeout": 5
          },
          { "type": "command", "command": "echo existing_session_sibling" }
        ]
      }
    ]
  }
}
EOF
"$WORKSPACE_ROOT/install.sh" >/dev/null


# -------------------------------------------------------------
# 2. Setup mock agent binaries
# -------------------------------------------------------------
BIN_DIR="$TMP_TEST_DIR/bin"
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

TEST_UUID="12345678-1234-4234-8234-123456789abc"

# Mock omp and pi: check -e flag, write UUID to AHR_RUN_FILE
cat > "$BIN_DIR/omp" << 'EOF'
#!/bin/sh
# Check if -e was passed
echo "MOCK_OMP_ARGS: $@" >> "$TMPDIR_MOCK/omp.log"
if [ -n "${AHR_RUN_FILE:-}" ] && [ -f "$AHR_RUN_FILE" ]; then
    echo "12345678-1234-4234-8234-123456789abc" > "$AHR_RUN_FILE"
fi
exit 42
EOF
chmod +x "$BIN_DIR/omp"

cat > "$BIN_DIR/pi" << 'EOF'
#!/bin/sh
echo "MOCK_PI_ARGS: $@" >> "$TMPDIR_MOCK/pi.log"
if [ -n "${AHR_RUN_FILE:-}" ] && [ -f "$AHR_RUN_FILE" ]; then
    echo "12345678-1234-4234-8234-123456789abc" > "$AHR_RUN_FILE"
fi
exit 43
EOF
chmod +x "$BIN_DIR/pi"

# Mock claude: check --settings flag
cat > "$BIN_DIR/claude" << 'EOF'
#!/bin/sh
echo "MOCK_CLAUDE_ARGS: $@" >> "$TMPDIR_MOCK/claude.log"
if [ -n "${AHR_RUN_FILE:-}" ] && [ -f "$AHR_RUN_FILE" ]; then
    echo "12345678-1234-4234-8234-123456789abc" > "$AHR_RUN_FILE"
fi
exit 44
EOF
chmod +x "$BIN_DIR/claude"

# Mock code (Codex binary)
cat > "$BIN_DIR/code" << 'EOF'
#!/bin/sh
echo "MOCK_CODE_ARGS: $@" >> "$TMPDIR_MOCK/code.log"
if [ -n "${AHR_RUN_FILE:-}" ] && [ -f "$AHR_RUN_FILE" ]; then
    echo "12345678-1234-4234-8234-123456789abc" > "$AHR_RUN_FILE"
fi
exit 45
EOF
chmod +x "$BIN_DIR/code"

# Mock traex (TraeCode binary)
cat > "$BIN_DIR/traex" << 'EOF'
#!/bin/sh
echo "MOCK_TRAEX_ARGS: $@" >> "$TMPDIR_MOCK/traex.log"
if [ -n "${AHR_RUN_FILE:-}" ] && [ -f "$AHR_RUN_FILE" ]; then
    echo "12345678-1234-4234-8234-123456789abc" > "$AHR_RUN_FILE"
fi
exit 46
EOF
chmod +x "$BIN_DIR/traex"

export TMPDIR_MOCK="$TMP_TEST_DIR/mock_logs"
mkdir -p "$TMPDIR_MOCK"

# -------------------------------------------------------------
# 3. Test Bash Wrapper
# -------------------------------------------------------------
echo "==> 3. Testing Bash integration"
cat > "$TMP_TEST_DIR/test_bash.sh" << 'EOF'
#!/usr/bin/env bash
set -e
set -o history
HISTFILE="$TMP_TEST_DIR/.bash_history"

# Pre-define caller variables to test that sourcing & running does not overwrite them
agent="orig_agent"
arg="orig_arg"
real_bin="orig_real_bin"
ahr_root="orig_ahr_root"
marker="orig_marker"
exit_code="orig_exit_code"
uuid="orig_uuid"
resume_cmd="orig_resume_cmd"
extra_flags="orig_extra_flags"
_ahr_cmd="orig_ahr_cmd"

verify_caller_vars() {
    local phase="$1"
    [ "$agent" = "orig_agent" ] || { echo "Caller var agent corrupted at $phase: $agent"; exit 1; }
    [ "$arg" = "orig_arg" ] || { echo "Caller var arg corrupted at $phase: $arg"; exit 1; }
    [ "$real_bin" = "orig_real_bin" ] || { echo "Caller var real_bin corrupted at $phase: $real_bin"; exit 1; }
    [ "$ahr_root" = "orig_ahr_root" ] || { echo "Caller var ahr_root corrupted at $phase: $ahr_root"; exit 1; }
    [ "$marker" = "orig_marker" ] || { echo "Caller var marker corrupted at $phase: $marker"; exit 1; }
    [ "$exit_code" = "orig_exit_code" ] || { echo "Caller var exit_code corrupted at $phase: $exit_code"; exit 1; }
    [ "$uuid" = "orig_uuid" ] || { echo "Caller var uuid corrupted at $phase: $uuid"; exit 1; }
    [ "$resume_cmd" = "orig_resume_cmd" ] || { echo "Caller var resume_cmd corrupted at $phase: $resume_cmd"; exit 1; }
    [ "$extra_flags" = "orig_extra_flags" ] || { echo "Caller var extra_flags corrupted at $phase: $extra_flags"; exit 1; }
    [ "$_ahr_cmd" = "orig_ahr_cmd" ] || { echo "Caller var _ahr_cmd corrupted at $phase: $_ahr_cmd"; exit 1; }
}

. "$TEST_AHR_HOME/shell/agent-resume-history.sh"
verify_caller_vars "after source"

# Test omp
res=0; omp my_param || res=$?
[ $res -eq 42 ] || { echo "Bash: omp exit code $res != 42"; exit 1; }

# Test pi
res=0; pi my_param || res=$?
[ $res -eq 43 ] || { echo "Bash: pi exit code $res != 43"; exit 1; }

# Test claude
res=0; claude my_param || res=$?
[ $res -eq 44 ] || { echo "Bash: claude exit code $res != 44"; exit 1; }

# Test code
res=0; code my_param || res=$?
[ $res -eq 45 ] || { echo "Bash: code exit code $res != 45"; exit 1; }

# Test traex
res=0; traex my_param || res=$?
[ $res -eq 46 ] || { echo "Bash: traex exit code $res != 46"; exit 1; }

# Verify caller variables preserved after normal executions
verify_caller_vars "after tool runs"

# Test bypass cases (should not set AHR_RUN_FILE or record history)
res=0; AHR_RUN_FILE='' omp --help || res=$?
[ $res -eq 42 ] || exit 1

res=0; AHR_RUN_FILE='' pi --session "$TEST_UUID" || res=$?
[ $res -eq 43 ] || exit 1

res=0; AHR_RUN_FILE='' claude --resume "$TEST_UUID" || res=$?
[ $res -eq 44 ] || exit 1

res=0; AHR_RUN_FILE='' code resume "$TEST_UUID" || res=$?
[ $res -eq 45 ] || exit 1

res=0; AHR_RUN_FILE='' traex resume "$TEST_UUID" || res=$?
[ $res -eq 46 ] || exit 1

# Accurate bypass of -p and --print
res=0; AHR_RUN_FILE='' omp -p "test prompt" || res=$?
[ $res -eq 42 ] || exit 1

res=0; AHR_RUN_FILE='' omp --print "test prompt" || res=$?
[ $res -eq 42 ] || exit 1

res=0; AHR_RUN_FILE='' pi -p "test prompt" || res=$?
[ $res -eq 43 ] || exit 1

res=0; AHR_RUN_FILE='' pi --print "test prompt" || res=$?
[ $res -eq 43 ] || exit 1

# Regression test: pi --fork bypass calls underlying fake exactly once, returns original status, and appends no resume entry
pi_resume_before=$(history | grep -c "pi --session $TEST_UUID$" || true)
pi_fork_calls_before=$(grep -c "^MOCK_PI_ARGS: --fork$" "$TMPDIR_MOCK/pi.log" 2>/dev/null || true)
res=0; pi --fork || res=$?
[ $res -eq 43 ] || { echo "Bash: pi --fork exit code $res != 43"; exit 1; }
pi_fork_calls_after=$(grep -c "^MOCK_PI_ARGS: --fork$" "$TMPDIR_MOCK/pi.log" 2>/dev/null || true)
[ $((pi_fork_calls_after - pi_fork_calls_before)) -eq 1 ] || { echo "Bash: pi --fork fake called $((pi_fork_calls_after - pi_fork_calls_before)) != 1 times"; exit 1; }
pi_resume_after=$(history | grep -c "pi --session $TEST_UUID$" || true)
[ "$pi_resume_before" -eq "$pi_resume_after" ] || { echo "Bash: pi --fork appended resume entry to history"; exit 1; }
# Direct bypass logic checks
_ahr_should_bypass omp --print "test" || exit 1
_ahr_should_bypass omp -p "test" || exit 1
_ahr_should_bypass pi --print "test" || exit 1
_ahr_should_bypass pi -p "test" || exit 1
_ahr_should_bypass pi --fork || exit 1

if _ahr_should_bypass omp --prompt "test"; then
    echo "omp --prompt must not bypass"
    exit 1
fi
if _ahr_should_bypass pi --prompt "test"; then
    echo "pi --prompt must not bypass"
    exit 1
fi

verify_caller_vars "after bypass runs"
# Write history to file to verify
history -w "$TMP_TEST_DIR/bash_hist.txt"
EOF
chmod +x "$TMP_TEST_DIR/test_bash.sh"
export TEST_AHR_HOME TEST_UUID TMP_TEST_DIR
bash "$TMP_TEST_DIR/test_bash.sh"
echo "  Checking Bash history..."
python3 - <<PYEOF
with open("$TMP_TEST_DIR/bash_hist.txt") as f:
    lines = [l.strip() for l in f.readlines() if l.strip()]

expected = [
    "omp --resume $TEST_UUID",
    "pi --session $TEST_UUID",
    "claude --resume $TEST_UUID",
    "code resume $TEST_UUID",
    "traex resume $TEST_UUID"
]

for cmd in expected:
    assert cmd in lines, f"Expected '{cmd}' in bash history, got: {lines}"
    assert lines.count(cmd) == 1, f"Expected exactly 1 '{cmd}', got {lines.count(cmd)}"

# Ensure bypass calls did not add duplicate or bypass resume commands
assert lines.count(f"omp --resume {expected[0].split()[-1]}") == 1
assert lines.count(f"pi --session {expected[1].split()[-1]}") == 1
assert not any(l == "pi --fork $TEST_UUID" or l == "pi --resume $TEST_UUID" for l in lines)

print("  [OK] Bash integration passed for all 5 tools + status preservation + bypass suppression")
PYEOF

# -------------------------------------------------------------
# 4. Test Zsh Wrapper
# -------------------------------------------------------------
echo "==> 4. Testing Zsh integration"
cat > "$TMP_TEST_DIR/test_zsh.zsh" << 'EOF'
#!/usr/bin/env zsh
set -e
HISTSIZE=100
SAVEHIST=100
setopt SHARE_HISTORY

agent="orig_agent"
arg="orig_arg"
real_bin="orig_real_bin"
ahr_root="orig_ahr_root"
marker="orig_marker"
exit_code="orig_exit_code"
uuid="orig_uuid"
resume_cmd="orig_resume_cmd"
extra_flags="orig_extra_flags"
_ahr_cmd="orig_ahr_cmd"

verify_caller_vars() {
    phase="$1"
    [ "$agent" = "orig_agent" ] || { echo "Zsh: Caller var agent corrupted at $phase: $agent"; exit 1; }
    [ "$arg" = "orig_arg" ] || { echo "Zsh: Caller var arg corrupted at $phase: $arg"; exit 1; }
    [ "$real_bin" = "orig_real_bin" ] || { echo "Zsh: Caller var real_bin corrupted at $phase: $real_bin"; exit 1; }
    [ "$ahr_root" = "orig_ahr_root" ] || { echo "Zsh: Caller var ahr_root corrupted at $phase: $ahr_root"; exit 1; }
    [ "$marker" = "orig_marker" ] || { echo "Zsh: Caller var marker corrupted at $phase: $marker"; exit 1; }
    [ "$exit_code" = "orig_exit_code" ] || { echo "Zsh: Caller var exit_code corrupted at $phase: $exit_code"; exit 1; }
    [ "$uuid" = "orig_uuid" ] || { echo "Zsh: Caller var uuid corrupted at $phase: $uuid"; exit 1; }
    [ "$resume_cmd" = "orig_resume_cmd" ] || { echo "Zsh: Caller var resume_cmd corrupted at $phase: $resume_cmd"; exit 1; }
    [ "$extra_flags" = "orig_extra_flags" ] || { echo "Zsh: Caller var extra_flags corrupted at $phase: $extra_flags"; exit 1; }
    [ "$_ahr_cmd" = "orig_ahr_cmd" ] || { echo "Zsh: Caller var _ahr_cmd corrupted at $phase: $_ahr_cmd"; exit 1; }
}

. "$TEST_AHR_HOME/shell/agent-resume-history.sh"
verify_caller_vars "after source"

res=0; omp param || res=$?
[ $res -eq 42 ] || exit 1

res=0; pi param || res=$?
[ $res -eq 43 ] || exit 1

res=0; claude param || res=$?
[ $res -eq 44 ] || exit 1

res=0; code param || res=$?
[ $res -eq 45 ] || exit 1

res=0; traex param || res=$?
[ $res -eq 46 ] || exit 1

# Bypass tests
res=0; omp --resume 123 || res=$?
[ $res -eq 42 ] || exit 1

res=0; omp --print "test" || res=$?
[ $res -eq 42 ] || exit 1

res=0; pi -p "test" || res=$?
[ $res -eq 43 ] || exit 1

res=0; pi --print "test" || res=$?
[ $res -eq 43 ] || exit 1

# Regression test: pi --fork bypass calls underlying fake exactly once, returns original status, and appends no resume entry
zsh_hist_before=$(fc -l | wc -l)
pi_fork_calls_before=$(grep -c "^MOCK_PI_ARGS: --fork$" "$TMPDIR_MOCK/pi.log" 2>/dev/null || true)
res=0; pi --fork || res=$?
[ $res -eq 43 ] || { echo "Zsh: pi --fork exit code $res != 43"; exit 1; }
pi_fork_calls_after=$(grep -c "^MOCK_PI_ARGS: --fork$" "$TMPDIR_MOCK/pi.log" 2>/dev/null || true)
[ $((pi_fork_calls_after - pi_fork_calls_before)) -eq 1 ] || { echo "Zsh: pi --fork fake called $((pi_fork_calls_after - pi_fork_calls_before)) != 1 times"; exit 1; }
zsh_hist_after=$(fc -l | wc -l)
[ "$zsh_hist_before" -eq "$zsh_hist_after" ] || { echo "Zsh: pi --fork appended to history"; exit 1; }
_ahr_should_bypass pi --fork || exit 1

verify_caller_vars "after runs"
fc -ln 1 > "$TMP_TEST_DIR/zsh_hist.txt"
EOF
chmod +x "$TMP_TEST_DIR/test_zsh.zsh"
zsh "$TMP_TEST_DIR/test_zsh.zsh"

python3 - <<PYEOF
with open("$TMP_TEST_DIR/zsh_hist.txt") as f:
    content = f.read()

expected = [
    "omp --resume $TEST_UUID",
    "pi --session $TEST_UUID",
    "claude --resume $TEST_UUID",
    "code resume $TEST_UUID",
    "traex resume $TEST_UUID"
]

for cmd in expected:
    assert cmd in content, f"Expected '{cmd}' in zsh history, got: {content}"
    assert content.count(cmd) == 1, f"Expected exactly 1 '{cmd}' in zsh history, got: {content.count(cmd)}"
assert content.count("pi --session $TEST_UUID") == 1
assert "--fork" not in content

print("  [OK] Zsh integration passed for all 5 tools + status preservation")
PYEOF

# -------------------------------------------------------------
# 5. Test Fish Wrapper
# -------------------------------------------------------------
echo "==> 5. Testing Fish integration"
cat > "$TMP_TEST_DIR/test_fish.fish" << 'EOF'
set -x XDG_DATA_HOME "$TEST_HOME/.local/share"

set -g cmd "orig_cmd"
set -g agent "orig_agent"
set -g arg "orig_arg"

# Existing named functions must be composed, not silently skipped.
function omp
    test -n "$AHR_RUN_FILE"; or return 97
    test -f "$AHR_RUN_FILE"; or return 98
    echo "omp:$argv" >> "$TMP_TEST_DIR/fish_functions.txt"
    command omp $argv
end
function pi
    echo "pi:$argv" >> "$TMP_TEST_DIR/fish_functions.txt"
    command pi $argv
end
function claude
    echo "claude:$argv" >> "$TMP_TEST_DIR/fish_functions.txt"
    command claude $argv
end

source "$TEST_AHR_HOME/shell/agent-resume-history.fish"

test "$cmd" = "orig_cmd"; or exit 1

# Re-sourcing must not clone AHR's wrapper or introduce recursion.
source "$TEST_AHR_HOME/shell/agent-resume-history.fish"

functions -q _ahr_original_omp; or exit 1
functions -q _ahr_original_pi; or exit 1
functions -q _ahr_original_claude; or exit 1
test "$agent" = "orig_agent"; or exit 1
test "$arg" = "orig_arg"; or exit 1

omp param
test $status -eq 42; or exit 1

pi param
test $status -eq 43; or exit 1

claude param
test $status -eq 44; or exit 1

code param
test $status -eq 45; or exit 1

traex param
test $status -eq 46; or exit 1

# Bypass test
omp --version
test $status -eq 42; or exit 1

pi -s "$TEST_UUID"
test $status -eq 43; or exit 1

code resume "$TEST_UUID"
test $status -eq 45; or exit 1

# Bypass tests for -p/--print
omp -p "prompt"
test $status -eq 42; or exit 1

omp --print "prompt"
test $status -eq 42; or exit 1

pi -p "prompt"
test $status -eq 43; or exit 1

pi --print "prompt"
test $status -eq 43; or exit 1

_ahr_should_bypass omp --print "prompt"
test $status -eq 0; or exit 1

_ahr_should_bypass pi --print "prompt"
test $status -eq 0; or exit 1

not _ahr_should_bypass omp --prompt "prompt"
test $status -eq 0; or exit 1

not _ahr_should_bypass pi --prompt "prompt"
test $status -eq 0; or exit 1

test "$cmd" = "orig_cmd"; or exit 1
test "$agent" = "orig_agent"; or exit 1
test "$arg" = "orig_arg"; or exit 1

# Verify fish history search contains the appended commands
history search --prefix 'omp --resume' | head -n 1 > "$TMP_TEST_DIR/fish_omp.txt"
history search --prefix 'pi --session' | head -n 1 > "$TMP_TEST_DIR/fish_pi.txt"
history search --prefix 'claude --resume' | head -n 1 > "$TMP_TEST_DIR/fish_claude.txt"
history search --prefix 'code resume' | head -n 1 > "$TMP_TEST_DIR/fish_code.txt"
history search --prefix 'traex resume' | head -n 1 > "$TMP_TEST_DIR/fish_traex.txt"
EOF
chmod +x "$TMP_TEST_DIR/test_fish.fish"
fish --no-config "$TMP_TEST_DIR/test_fish.fish"

python3 - <<PYEOF
import os

checks = [
    ("fish_omp.txt", "omp --resume $TEST_UUID"),
    ("fish_pi.txt", "pi --session $TEST_UUID"),
    ("fish_claude.txt", "claude --resume $TEST_UUID"),
    ("fish_code.txt", "code resume $TEST_UUID"),
    ("fish_traex.txt", "traex resume $TEST_UUID")
]

for filename, expected in checks:
    path = os.path.join("$TMP_TEST_DIR", filename)
    with open(path) as f:
        val = f.read().strip()
    assert val == expected, f"Fish history mismatch in {filename}: expected '{expected}', got '{val}'"

with open("$TMP_TEST_DIR/fish_functions.txt") as f:
    calls = f.read().splitlines()
for expected in ("omp:-e $TEST_AHR_HOME/adapters/pi-session.ts param", "pi:-e $TEST_AHR_HOME/adapters/pi-session.ts param", "claude:--settings $TEST_AHR_HOME/adapters/claude-settings.json param"):
    assert calls.count(expected) == 1, f"Expected composed function once: {expected}; got {calls}"
print("  [OK] Fish integration passed for all 5 tools + status preservation")
PYEOF

# -------------------------------------------------------------
# 6. Test uninstall.sh safety and managed-delta cleanup
# -------------------------------------------------------------
echo "==> 6. Testing uninstall.sh"
# Uninstall must reject a later malformed managed block before changing any
# earlier rc file, hook file, or the install tree.
cp "$HOME/.bashrc" "$TMP_TEST_DIR/uninstall_bashrc.before"
cp "$HOME/.code/hooks.json" "$TMP_TEST_DIR/uninstall_code.before"
printf '\n%s\n' '# >>> agent-resume-history initialize >>>' >> "$HOME/.config/fish/config.fish"
set +e
"$WORKSPACE_ROOT/uninstall.sh" >/dev/null 2>&1
UNINSTALL_PREFLIGHT_STATUS=$?
set -e
[ "$UNINSTALL_PREFLIGHT_STATUS" -ne 0 ] || { echo "FAIL: uninstall accepted malformed managed block"; exit 1; }
cmp -s "$TMP_TEST_DIR/uninstall_bashrc.before" "$HOME/.bashrc" || { echo "FAIL: uninstall changed bashrc before later preflight failure"; exit 1; }
cmp -s "$TMP_TEST_DIR/uninstall_code.before" "$HOME/.code/hooks.json" || { echo "FAIL: uninstall changed hooks before later preflight failure"; exit 1; }
[ -d "$TEST_AHR_HOME" ] || { echo "FAIL: uninstall removed install tree before later preflight failure"; exit 1; }
python3 - "$HOME/.config/fish/config.fish" <<'PYEOF'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
marker = "\n# >>> agent-resume-history initialize >>>\n"
assert text.endswith(marker)
path.write_text(text[:-len(marker)])
PYEOF
echo "  [OK] Uninstall validates every managed surface before mutation"

# Exact managed hook cleanup must preserve similarly named unrelated hooks.
# Add an unrelated hook containing AHR text; uninstall must not remove it.
python3 - "$HOME/.code/hooks.json" <<'PYEOF'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["hooks"]["SessionStart"].append({
    "hooks": [{"type": "command", "command": "echo agent-resume-history unrelated"}]
})
path.write_text(json.dumps(data, indent=2) + "\n")
PYEOF

# Perform the successful uninstall after preflight safety checks.
# Uninstall removes only allowlisted runtime artifacts and preserves unrelated
# content in a custom install directory.
printf 'keep\n' > "$TEST_AHR_HOME/unrelated.txt"
"$WORKSPACE_ROOT/uninstall.sh"

# Check target dir deleted
# The custom target remains because it contains unrelated user content.
[ -d "$TEST_AHR_HOME" ] || { echo "FAIL: custom install root with unrelated content was removed"; exit 1; }
[ "$(cat "$TEST_AHR_HOME/unrelated.txt")" = "keep" ] || { echo "FAIL: unrelated install-tree content was removed"; exit 1; }
for rel in bin/agent-resume-history-hook bin/agent-resume-history-record lib/agent-resume-history.sh adapters/pi-session.ts adapters/claude-settings.json adapters/codex-hooks.json adapters/traex-hooks.json shell/agent-resume-history.sh shell/agent-resume-history.fish; do
    [ ! -e "$TEST_AHR_HOME/$rel" ] || { echo "FAIL: managed artifact remained after uninstall: $rel"; exit 1; }
done
# Check rc files cleaned
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.config/fish/config.fish"; do
    if grep -qF "# >>> agent-resume-history initialize >>>" "$rc" 2>/dev/null; then
        echo "FAIL: $rc still contains AHR block after uninstall"
        exit 1
    fi
done

# Check hooks.json cleaned of AHR hooks but retained original PreToolUse hook
python3 - <<PYEOF
import json

for path in ("$HOME/.code/hooks.json", "$HOME/.codex/hooks.json"):
    with open(path) as f:
        code_hooks = json.load(f)
    assert "PreToolUse" in code_hooks["hooks"], f"Code PreToolUse hook missing after uninstall from {path}!"
    session_start = code_hooks["hooks"].get("SessionStart", [])
    assert not any("agent-resume-history-hook" in json.dumps(item) for item in session_start), f"AHR hook remained in {path}!"
    if path.endswith("/.code/hooks.json"):
        assert any("echo agent-resume-history unrelated" in json.dumps(item) for item in session_start), "Unrelated similarly named hook was removed!"

        assert any(group.get("matcher") == "custom" and any(hook.get("command") == "echo existing_session_sibling" for hook in group.get("hooks", [])) for group in session_start if isinstance(group, dict)), "Mixed SessionStart matcher or sibling was removed!"
with open("$HOME/.trae/cli/hooks.json") as f:
    trae_hooks = json.load(f)
assert "PreToolUse" in trae_hooks["hooks"], "Trae PreToolUse hook missing after uninstall!"
assert not any("agent-resume-history-hook" in json.dumps(item) for item in trae_hooks["hooks"].get("SessionStart", [])), "AHR hook remained in Trae hooks!"

print("  [OK] Uninstall verified: target removed, rc cleaned, hooks reverted cleanly")
PYEOF

echo "All shell and installer tests passed successfully!"
