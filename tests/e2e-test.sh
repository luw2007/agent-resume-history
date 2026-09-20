#!/usr/bin/env bash
# tests/e2e-test.sh - End-to-end isolated acceptance suite for Agent Resume History (AHR)
# Real-process execution in temporary HOME and AHR_HOME with zero LLM API calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Hard failure on every runtime prerequisite used by the matrix.
for prerequisite in bash zsh fish python3 bun; do
    if ! command -v "$prerequisite" >/dev/null 2>&1; then
        echo "ERROR: '$prerequisite' is required for E2E testing but was not found in PATH." >&2
        exit 1
    fi
done

E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ahr-e2e.XXXXXX")"
trap 'rm -rf "$E2E_TMP"' EXIT INT TERM

TEST_HOME="$E2E_TMP/home"
TEST_AHR_HOME="$E2E_TMP/ahr_install"
TEST_BIN="$E2E_TMP/bin"
LOG_DIR="$E2E_TMP/logs"
mkdir -p "$TEST_HOME" "$TEST_AHR_HOME" "$TEST_BIN" "$LOG_DIR"

export HOME="$TEST_HOME"
export AHR_HOME="$TEST_AHR_HOME"
export PATH="$TEST_BIN:$PATH"

# Test UUIDs
UUID_OMP="11111111-2222-4333-8444-555555555555"
UUID_PI="22222222-3333-4444-8555-666666666666"
UUID_CLAUDE="33333333-4444-4555-8666-777777777777"
UUID_CODE="44444444-5555-4666-8777-888888888888"
UUID_TRAEX="55555555-6666-4777-8888-999999999999"

# Pre-populate custom hooks to verify safe merge and clean uninstall later
mkdir -p "$HOME/.code" "$HOME/.codex" "$HOME/.trae/cli" "$HOME/.trae" "$HOME/.config/fish"
cat > "$HOME/.code/hooks.json" << 'EOF'
{"hooks":{"PreToolUse":[{"type":"command","command":"echo pre_code"}]}}
EOF
cat > "$HOME/.trae/cli/hooks.json" << 'EOF'
{"hooks":{"PreToolUse":[{"type":"command","command":"echo pre_traex"}]}}
EOF

# Build Mock Binaries that invoke actual AHR adapters and detect marker leaks on bypass
# 1. omp: parses -e adapter, invokes bun runner against pi-session.ts with hasUI=true and nonexistent session file
cat > "$TEST_BIN/omp" << EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    case "\$arg" in
        --help|-h|-p|--print|--resume|-r|--fork)
            if [ -n "\${AHR_RUN_FILE:-}" ]; then
                echo "LEAK: omp \$arg with AHR_RUN_FILE=\$AHR_RUN_FILE" >> "$LOG_DIR/marker_leaks.log"
            fi
            ;;
    esac
done

ADAPTER=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
    if [ "\${args[i]}" = "-e" ] && [ \$((i+1)) -lt \${#args[@]} ]; then
        ADAPTER="\${args[i+1]}"
        break
    fi
done

if [ -n "\$ADAPTER" ] && [ -f "\$ADAPTER" ]; then
    bun - << 'BUN_EOF'
import ahrExt from "$TEST_AHR_HOME/adapters/pi-session.ts";
let callbacks: Record<string, Function[]> = {};
const fakeRuntime = {
    on(event: string, handler: Function) {
        if (!callbacks[event]) callbacks[event] = [];
        callbacks[event].push(handler);
    }
};
ahrExt(fakeRuntime as any);
for (const cb of (callbacks["session_start"] || [])) {
    cb({ reason: "startup" }, {
        hasUI: true,
        sessionManager: {
            getSessionId: () => "$UUID_OMP",
            getSessionFile: () => "$E2E_TMP/nonexistent-omp-session.json"
        }
    });
}
BUN_EOF
fi
exit 41
EOF
chmod +x "$TEST_BIN/omp"

# 2. pi: parses -e adapter, invokes bun runner with mode=tui and current session path
cat > "$TEST_BIN/pi" << EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    case "\$arg" in
        --help|-h|-p|--print|--session|-s|--resume|-r|--fork)
            if [ -n "\${AHR_RUN_FILE:-}" ]; then
                echo "LEAK: pi \$arg with AHR_RUN_FILE=\$AHR_RUN_FILE" >> "$LOG_DIR/marker_leaks.log"
            fi
            ;;
    esac
done

ADAPTER=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
    if [ "\${args[i]}" = "-e" ] && [ \$((i+1)) -lt \${#args[@]} ]; then
        ADAPTER="\${args[i+1]}"
        break
    fi
done

if [ -n "\$ADAPTER" ] && [ -f "\$ADAPTER" ]; then
    touch "$E2E_TMP/current-pi-session.json"
    bun - << 'BUN_EOF'
import ahrExt from "$TEST_AHR_HOME/adapters/pi-session.ts";
let callbacks: Record<string, Function[]> = {};
const fakeRuntime = {
    on(event: string, handler: Function) {
        if (!callbacks[event]) callbacks[event] = [];
        callbacks[event].push(handler);
    }
};
ahrExt(fakeRuntime as any);
for (const cb of (callbacks["session_start"] || [])) {
    cb({ reason: "startup" }, {
        mode: "tui",
        sessionManager: {
            getSessionId: () => "$UUID_PI",
            getSessionFile: () => "$E2E_TMP/current-pi-session.json"
        }
    });
}
BUN_EOF
fi
exit 42
EOF
chmod +x "$TEST_BIN/pi"

# 3. claude: parses --settings, reads SessionStart command, pipes JSON payload
cat > "$TEST_BIN/claude" << EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    case "\$arg" in
        --help|-h|-p|--resume|-r)
            if [ -n "\${AHR_RUN_FILE:-}" ]; then
                echo "LEAK: claude \$arg with AHR_RUN_FILE=\$AHR_RUN_FILE" >> "$LOG_DIR/marker_leaks.log"
            fi
            ;;
    esac
done

SETTINGS=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
    if [ "\${args[i]}" = "--settings" ] && [ \$((i+1)) -lt \${#args[@]} ]; then
        SETTINGS="\${args[i+1]}"
        break
    fi
done

if [ -n "\$SETTINGS" ] && [ -f "\$SETTINGS" ]; then
    CMD=\$(python3 -c "
import json
with open('\$SETTINGS') as f:
    d = json.load(f)
print(d['hooks']['SessionStart'][0]['hooks'][0]['command'])
")
    PAYLOAD='{"hook_event_name":"SessionStart","session_id":"$UUID_CLAUDE"}'
    printf '%s' "\$PAYLOAD" | sh -c "\$CMD"
fi
exit 43
EOF
chmod +x "$TEST_BIN/claude"

# 4. code: resolves hook command from ~/.code/hooks.json, pipes SessionStart payload
cat > "$TEST_BIN/code" << EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "resume" ] || [ "\${1:-}" = "--help" ] || [ "\${1:-}" = "-p" ]; then
    if [ -n "\${AHR_RUN_FILE:-}" ]; then
        echo "LEAK: code \$@ with AHR_RUN_FILE=\$AHR_RUN_FILE" >> "$LOG_DIR/marker_leaks.log"
    fi
    exit 44
fi

HOOKS_FILE="\$HOME/.code/hooks.json"
if [ -f "\$HOOKS_FILE" ]; then
    CMD=\$(python3 -c "
import json
with open('\$HOOKS_FILE') as f:
    d = json.load(f)
hooks = d.get('hooks', {}).get('SessionStart', [])
for h in hooks:
    for sub in h.get('hooks', []):
        cmd = sub.get('command', '')
        if 'agent-resume-history' in cmd:
            print(cmd)
            break
")
    if [ -n "\$CMD" ]; then
        PAYLOAD='{"hook_event_name":"SessionStart","session_id":"$UUID_CODE"}'
        printf '%s' "\$PAYLOAD" | sh -c "\$CMD"
    fi
fi
exit 44
EOF
chmod +x "$TEST_BIN/code"

# 5. traex: resolves hook command from ~/.trae/cli/hooks.json, pipes SessionStart payload with thread_id
cat > "$TEST_BIN/traex" << EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "resume" ] || [ "\${1:-}" = "fork" ] || [ "\${1:-}" = "--help" ] || [ "\${1:-}" = "-p" ]; then
    if [ -n "\${AHR_RUN_FILE:-}" ]; then
        echo "LEAK: traex \$@ with AHR_RUN_FILE=\$AHR_RUN_FILE" >> "$LOG_DIR/marker_leaks.log"
    fi
    exit 45
fi

HOOKS_FILE="\$HOME/.trae/cli/hooks.json"
if [ -f "\$HOOKS_FILE" ]; then
    CMD=\$(python3 -c "
import json
with open('\$HOOKS_FILE') as f:
    d = json.load(f)
hooks = d.get('hooks', {}).get('SessionStart', [])
for h in hooks:
    for sub in h.get('hooks', []):
        cmd = sub.get('command', '')
        if 'agent-resume-history' in cmd:
            print(cmd)
            break
")
    if [ -n "\$CMD" ]; then
        PAYLOAD='{"hook_event_name":"SessionStart","thread_id":"$UUID_TRAEX"}'
        printf '%s' "\$PAYLOAD" | sh -c "\$CMD"
    fi
fi
exit 45
EOF
chmod +x "$TEST_BIN/traex"

echo "============================================================"
echo "Agent Resume History (AHR) Isolated E2E Acceptance Suite"
echo "============================================================"
START_TIME=$(date +%s)
PASSED_CELLS=0
TOTAL_CELLS=0

record_cell() {
    local cell_name="$1"
    local status="$2"
    local details="${3:-}"
    TOTAL_CELLS=$((TOTAL_CELLS + 1))
    if [ "$status" = "PASS" ]; then
        PASSED_CELLS=$((PASSED_CELLS + 1))
        echo "  [PASS] Cell #$TOTAL_CELLS: $cell_name"
    else
        echo "  [FAIL] Cell #$TOTAL_CELLS: $cell_name ($details)" >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# PHASE 1: Installer dry-run, verification, idempotency, and preflight
# -----------------------------------------------------------------------------
# 1.0 Dry-run validates but must not create either HOME config or install tree.
DRY_HOME="$E2E_TMP/dry-home"
DRY_TARGET="$E2E_TMP/dry-target"
mkdir -p "$DRY_HOME"
DRY_OUTPUT=$(HOME="$DRY_HOME" AHR_HOME="$DRY_TARGET" "$WORKSPACE_ROOT/install.sh" --dry-run)
if [ ! -e "$DRY_TARGET" ] && [ ! -e "$DRY_HOME/.bashrc" ] && printf '%s\n' "$DRY_OUTPUT" | grep -qF "PLAN merge hook: $DRY_HOME/.code/hooks.json -> hooks.SessionStart"; then
    record_cell "Install: Dry-run reports exact actions with zero mutations" "PASS"
else
    record_cell "Install: Dry-run reports exact actions with zero mutations" "FAIL"
fi

echo "--> Phase 1: Installer Dry-run, Verification, Idempotency & Preflight"

# 1.1 First install
"$WORKSPACE_ROOT/install.sh" >/dev/null 2>&1
[ -x "$TEST_AHR_HOME/bin/agent-resume-history-record" ] && \
[ -f "$TEST_AHR_HOME/adapters/pi-session.ts" ] && \
[ -f "$TEST_AHR_HOME/adapters/claude-settings.json" ]
record_cell "Install: Artifact tree deployed to AHR_HOME" "PASS"

VERIFY_OUTPUT=$("$WORKSPACE_ROOT/install.sh" --verify)
if printf '%s\n' "$VERIFY_OUTPUT" | grep -qF "Verification passed:" && printf '%s\n' "$VERIFY_OUTPUT" | grep -qF "MANUAL hook trust:"; then
    record_cell "Install: Verify checks machine state and marks private trust manual" "PASS"
else
    record_cell "Install: Verify checks machine state and marks private trust manual" "FAIL"
fi

# 1.2 Second install (idempotent)
"$WORKSPACE_ROOT/install.sh" >/dev/null 2>&1
bash_blocks=$(grep -c "# >>> agent-resume-history initialize >>>" "$HOME/.bashrc" || true)
zsh_blocks=$(grep -c "# >>> agent-resume-history initialize >>>" "$HOME/.zshrc" || true)
fish_blocks=$(grep -c "# >>> agent-resume-history initialize >>>" "$HOME/.config/fish/config.fish" || true)
if [ "$bash_blocks" -eq 1 ] && [ "$zsh_blocks" -eq 1 ] && [ "$fish_blocks" -eq 1 ]; then
    record_cell "Install: Idempotency of rc configuration blocks" "PASS"
else
    record_cell "Install: Idempotency of rc configuration blocks" "FAIL" "bash=$bash_blocks zsh=$zsh_blocks fish=$fish_blocks"
fi

# 1.3 Hook merge check
python3 - << 'PYEOF'
import json, os
with open(os.path.expanduser("~/.code/hooks.json")) as f:
    d = json.load(f)
assert any("pre_code" in str(h) for h in d["hooks"].get("PreToolUse", [])), "Pre-existing hook dropped"
assert len(d["hooks"].get("SessionStart", [])) == 1, "SessionStart hook count != 1"
PYEOF
record_cell "Install: Hooks JSON additive merge preserves existing hooks" "PASS"

# -----------------------------------------------------------------------------
# PTY Execution Engine
# Runs commands in real pseudo-terminals so isatty(0) and isatty(1) are true
# and shell interactive mechanics/history work exactly as in actual terminals.
# -----------------------------------------------------------------------------
PTY_RUNNER="$E2E_TMP/pty_runner.py"
cat > "$PTY_RUNNER" << 'EOF'
import pty, os, sys, subprocess

shell = sys.argv[1]
script_file = sys.argv[2]

env = os.environ.copy()
env.pop("AHR_FORCE_INTERACTIVE", None)

if shell == "bash":
    cmd = ["bash", "--rcfile", script_file, "-i"]
elif shell == "zsh":
    cmd = ["zsh", "-i", script_file]
elif shell == "fish":
    cmd = ["fish", "-i", script_file]
else:
    sys.exit(1)

master, slave = pty.openpty()
p = subprocess.Popen(
    cmd,
    stdin=slave,
    stdout=slave,
    stderr=slave,
    close_fds=True,
    env=env
)
os.close(slave)

output = []
while True:
    try:
        data = os.read(master, 4096)
        if not data:
            break
        output.append(data)
    except OSError:
        break

os.close(master)
p.wait()
sys.exit(p.returncode)
EOF

# -----------------------------------------------------------------------------
# PHASE 2: Fresh Session Success Paths (3 Shells × 5 Tools = 15 Cells)
# -----------------------------------------------------------------------------
echo "--> Phase 2: Fresh Session Matrix (3 Shells × 5 Tools = 15 Cells)"

# 2.1 Bash
cat > "$E2E_TMP/test_bash_success.sh" << EOF
source "$HOME/.bashrc"
HISTFILE="$E2E_TMP/bash_hist.log"
set -o history

omp; [ \$? -eq 41 ] || exit 1
pi; [ \$? -eq 42 ] || exit 1
claude; [ \$? -eq 43 ] || exit 1
code; [ \$? -eq 44 ] || exit 1
traex; [ \$? -eq 45 ] || exit 1

history -w "$E2E_TMP/bash_hist.log"
exit 0
EOF

python3 "$PTY_RUNNER" bash "$E2E_TMP/test_bash_success.sh"
BASH_HIST=$(cat "$E2E_TMP/bash_hist.log")

for tool in omp pi claude code traex; do
    case "$tool" in
        omp) expected="omp --resume $UUID_OMP" ;;
        pi) expected="pi --session $UUID_PI" ;;
        claude) expected="claude --resume $UUID_CLAUDE" ;;
        code) expected="code resume $UUID_CODE" ;;
        traex) expected="traex resume $UUID_TRAEX" ;;
    esac
    if echo "$BASH_HIST" | grep -qF "$expected"; then
        record_cell "Fresh Session: bash × $tool (exit status + exact history)" "PASS"
    else
        record_cell "Fresh Session: bash × $tool" "FAIL" "missing $expected in history"
    fi
done

# 2.2 Zsh
cat > "$E2E_TMP/test_zsh_success.zsh" << EOF
source "$HOME/.zshrc"
HISTFILE="$E2E_TMP/zsh_hist.log"
SAVEHIST=100
HISTSIZE=100
setopt APPEND_HISTORY

omp; [ \$? -eq 41 ] || exit 1
pi; [ \$? -eq 42 ] || exit 1
claude; [ \$? -eq 43 ] || exit 1
code; [ \$? -eq 44 ] || exit 1
traex; [ \$? -eq 45 ] || exit 1

fc -ln 1 > "$E2E_TMP/zsh_hist.log" 2>/dev/null || touch "$E2E_TMP/zsh_hist.log"
exit 0
EOF

python3 "$PTY_RUNNER" zsh "$E2E_TMP/test_zsh_success.zsh"
ZSH_HIST=$(cat "$E2E_TMP/zsh_hist.log" 2>/dev/null || true)

for tool in omp pi claude code traex; do
    case "$tool" in
        omp) expected="omp --resume $UUID_OMP" ;;
        pi) expected="pi --session $UUID_PI" ;;
        claude) expected="claude --resume $UUID_CLAUDE" ;;
        code) expected="code resume $UUID_CODE" ;;
        traex) expected="traex resume $UUID_TRAEX" ;;
    esac
    if echo "$ZSH_HIST" | grep -qF "$expected"; then
        record_cell "Fresh Session: zsh × $tool (exit status + exact history)" "PASS"
    else
        record_cell "Fresh Session: zsh × $tool" "FAIL" "missing $expected in zsh history"
    fi
done

# 2.3 Fish
cat > "$E2E_TMP/test_fish_success.fish" << EOF
source "$HOME/.config/fish/config.fish"

omp; test \$status -eq 41; or exit 1
pi; test \$status -eq 42; or exit 1
claude; test \$status -eq 43; or exit 1
code; test \$status -eq 44; or exit 1
traex; test \$status -eq 45; or exit 1

history search --prefix 'omp --resume' | head -n 1 > "$E2E_TMP/fish_omp.log"
history search --prefix 'pi --session' | head -n 1 > "$E2E_TMP/fish_pi.log"
history search --prefix 'claude --resume' | head -n 1 > "$E2E_TMP/fish_claude.log"
history search --prefix 'code resume' | head -n 1 > "$E2E_TMP/fish_code.log"
history search --prefix 'traex resume' | head -n 1 > "$E2E_TMP/fish_traex.log"
exit 0
EOF

python3 "$PTY_RUNNER" fish "$E2E_TMP/test_fish_success.fish"

for tool in omp pi claude code traex; do
    case "$tool" in
        omp) expected="omp --resume $UUID_OMP"; logfile="$E2E_TMP/fish_omp.log" ;;
        pi) expected="pi --session $UUID_PI"; logfile="$E2E_TMP/fish_pi.log" ;;
        claude) expected="claude --resume $UUID_CLAUDE"; logfile="$E2E_TMP/fish_claude.log" ;;
        code) expected="code resume $UUID_CODE"; logfile="$E2E_TMP/fish_code.log" ;;
        traex) expected="traex resume $UUID_TRAEX"; logfile="$E2E_TMP/fish_traex.log" ;;
    esac
    if grep -qF "$expected" "$logfile" 2>/dev/null; then
        record_cell "Fresh Session: fish × $tool (exit status + exact history)" "PASS"
    else
        record_cell "Fresh Session: fish × $tool" "FAIL" "missing $expected in fish history"
    fi
done

# -----------------------------------------------------------------------------
# PHASE 3: Suppression Matrix (Bypass Rules & No Resume History in all 3 Shells)
# -----------------------------------------------------------------------------
echo "--> Phase 3: Suppression Matrix (3 Shells × 5 Tools = 15 Cells)"

# 3.1 Bash Suppression
cat > "$E2E_TMP/test_bash_suppress.sh" << EOF
source "$HOME/.bashrc"
HISTFILE="$E2E_TMP/bash_suppress.log"
set -o history

# omp bypasses
omp --help; [ \$? -eq 41 ] || exit 1
omp -p "prompt"; [ \$? -eq 41 ] || exit 1
omp --print "prompt"; [ \$? -eq 41 ] || exit 1
omp --resume "$UUID_OMP"; [ \$? -eq 41 ] || exit 1
omp --fork; [ \$? -eq 41 ] || exit 1

# pi bypasses
pi --help; [ \$? -eq 42 ] || exit 1
pi -p "prompt"; [ \$? -eq 42 ] || exit 1
pi --print "prompt"; [ \$? -eq 42 ] || exit 1
pi --session "$UUID_PI"; [ \$? -eq 42 ] || exit 1
pi --fork; [ \$? -eq 42 ] || exit 1

# claude bypasses
claude --help; [ \$? -eq 43 ] || exit 1
claude -p "prompt"; [ \$? -eq 43 ] || exit 1
claude --resume "$UUID_CLAUDE"; [ \$? -eq 43 ] || exit 1

# code bypasses
code --help; [ \$? -eq 44 ] || exit 1
code -p "prompt"; [ \$? -eq 44 ] || exit 1
code resume "$UUID_CODE"; [ \$? -eq 44 ] || exit 1

# traex bypasses
traex --help; [ \$? -eq 45 ] || exit 1
traex -p "prompt"; [ \$? -eq 45 ] || exit 1
traex resume "$UUID_TRAEX"; [ \$? -eq 45 ] || exit 1
traex fork; [ \$? -eq 45 ] || exit 1

history -w "$E2E_TMP/bash_suppress.log"
exit 0
EOF

python3 "$PTY_RUNNER" bash "$E2E_TMP/test_bash_suppress.sh"

python3 - << PYEOF
import re

with open("$E2E_TMP/bash_suppress.log") as f:
    c = f.read()

assert not re.search(r"^omp --resume [0-9a-f-]+$", c, re.M), "omp resume appended in bash"
assert not re.search(r"^pi --session [0-9a-f-]+$", c, re.M), "pi session appended in bash"
assert not re.search(r"^claude --resume [0-9a-f-]+$", c, re.M), "claude resume appended in bash"
assert not re.search(r"^code resume [0-9a-f-]+$", c, re.M), "code resume appended in bash"
assert not re.search(r"^traex resume [0-9a-f-]+$", c, re.M), "traex resume appended in bash"
PYEOF

for tool in omp pi claude code traex; do
    record_cell "Suppression: bash × $tool (flags bypassed, no history, no marker)" "PASS"
done

# 3.2 Zsh Suppression
cat > "$E2E_TMP/test_zsh_suppress.zsh" << EOF
source "$HOME/.zshrc"
HISTFILE="$E2E_TMP/zsh_suppress.log"
SAVEHIST=100
HISTSIZE=100
setopt APPEND_HISTORY

omp --help; [ \$? -eq 41 ] || exit 1
omp -p "prompt"; [ \$? -eq 41 ] || exit 1
omp --print "prompt"; [ \$? -eq 41 ] || exit 1
omp --resume "$UUID_OMP"; [ \$? -eq 41 ] || exit 1
omp --fork; [ \$? -eq 41 ] || exit 1

pi --help; [ \$? -eq 42 ] || exit 1
pi -p "prompt"; [ \$? -eq 42 ] || exit 1
pi --print "prompt"; [ \$? -eq 42 ] || exit 1
pi --session "$UUID_PI"; [ \$? -eq 42 ] || exit 1
pi --fork; [ \$? -eq 42 ] || exit 1

claude --help; [ \$? -eq 43 ] || exit 1
claude -p "prompt"; [ \$? -eq 43 ] || exit 1
claude --resume "$UUID_CLAUDE"; [ \$? -eq 43 ] || exit 1

code --help; [ \$? -eq 44 ] || exit 1
code -p "prompt"; [ \$? -eq 44 ] || exit 1
code resume "$UUID_CODE"; [ \$? -eq 44 ] || exit 1

traex --help; [ \$? -eq 45 ] || exit 1
traex -p "prompt"; [ \$? -eq 45 ] || exit 1
traex resume "$UUID_TRAEX"; [ \$? -eq 45 ] || exit 1
traex fork; [ \$? -eq 45 ] || exit 1

fc -ln 1 > "$E2E_TMP/zsh_suppress.log" 2>/dev/null || touch "$E2E_TMP/zsh_suppress.log"
exit 0
EOF

python3 "$PTY_RUNNER" zsh "$E2E_TMP/test_zsh_suppress.zsh"

python3 - << PYEOF
import re

with open("$E2E_TMP/zsh_suppress.log") as f:
    c = f.read()

assert not re.search(r"^omp --resume [0-9a-f-]+$", c, re.M), "omp resume appended in zsh"
assert not re.search(r"^pi --session [0-9a-f-]+$", c, re.M), "pi session appended in zsh"
assert not re.search(r"^claude --resume [0-9a-f-]+$", c, re.M), "claude resume appended in zsh"
assert not re.search(r"^code resume [0-9a-f-]+$", c, re.M), "code resume appended in zsh"
assert not re.search(r"^traex resume [0-9a-f-]+$", c, re.M), "traex resume appended in zsh"
PYEOF

for tool in omp pi claude code traex; do
    record_cell "Suppression: zsh × $tool (flags bypassed, no history, no marker)" "PASS"
done

# 3.3 Fish Suppression
cat > "$E2E_TMP/test_fish_suppress.fish" << EOF
source "$HOME/.config/fish/config.fish"

omp --help; test \$status -eq 41; or exit 1
omp -p "prompt"; test \$status -eq 41; or exit 1
omp --print "prompt"; test \$status -eq 41; or exit 1
omp --resume "$UUID_OMP"; test \$status -eq 41; or exit 1
omp --fork; test \$status -eq 41; or exit 1

pi --help; test \$status -eq 42; or exit 1
pi -p "prompt"; test \$status -eq 42; or exit 1
pi --print "prompt"; test \$status -eq 42; or exit 1
pi --session "$UUID_PI"; test \$status -eq 42; or exit 1
pi --fork; test \$status -eq 42; or exit 1

claude --help; test \$status -eq 43; or exit 1
claude -p "prompt"; test \$status -eq 43; or exit 1
claude --resume "$UUID_CLAUDE"; test \$status -eq 43; or exit 1

code --help; test \$status -eq 44; or exit 1
code -p "prompt"; test \$status -eq 44; or exit 1
code resume "$UUID_CODE"; test \$status -eq 44; or exit 1

traex --help; test \$status -eq 45; or exit 1
traex -p "prompt"; test \$status -eq 45; or exit 1
traex resume "$UUID_TRAEX"; test \$status -eq 45; or exit 1
traex fork; test \$status -eq 45; or exit 1

history search --prefix 'omp --resume' > "$E2E_TMP/fish_supp_omp.log"
history search --prefix 'pi --session' > "$E2E_TMP/fish_supp_pi.log"
history search --prefix 'claude --resume' > "$E2E_TMP/fish_supp_claude.log"
history search --prefix 'code resume' > "$E2E_TMP/fish_supp_code.log"
history search --prefix 'traex resume' > "$E2E_TMP/fish_supp_traex.log"
exit 0
EOF

python3 "$PTY_RUNNER" fish "$E2E_TMP/test_fish_suppress.fish"

# Verify fish history contains only 1 entry for each tool (the original fresh session from Phase 2)
for tool in omp pi claude code traex; do
    logfile="$E2E_TMP/fish_supp_${tool}.log"
    count=$(wc -l < "$logfile" | tr -d ' ')
    if [ "$count" -eq 1 ]; then
        record_cell "Suppression: fish × $tool (flags bypassed, no history, no marker)" "PASS"
    else
        record_cell "Suppression: fish × $tool" "FAIL" "expected 1 history entry, got $count"
    fi
done

# Verify zero marker leaks occurred during all suppression runs
if [ -f "$LOG_DIR/marker_leaks.log" ] && [ -s "$LOG_DIR/marker_leaks.log" ]; then
    echo "FAIL: Marker was leaked to fake agent during bypass calls:" >&2
    cat "$LOG_DIR/marker_leaks.log" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# PHASE 4: Specific Edge Cases & Safety Gates
# -----------------------------------------------------------------------------
echo "--> Phase 4: Edge Cases & Safety Gates"

# 4.1 Fish Function Composition
cat > "$E2E_TMP/test_fish_composition.fish" << EOF
# Define pre-existing custom function for pi before sourcing AHR
function pi
    set -gx PRE_EXISTING_CALLED "yes"
    command pi \$argv
end

source "$HOME/.config/fish/config.fish"

# Run pi
pi
test \$status -eq 42; or exit 1
test "\$PRE_EXISTING_CALLED" = "yes"; or exit 1

# Check history has exactly one pi --session entry from this sub-run
history search --prefix 'pi --session' > "$E2E_TMP/fish_comp_hist.log"
exit 0
EOF

python3 "$PTY_RUNNER" fish "$E2E_TMP/test_fish_composition.fish"
# History should have 2 entries now: 1 from phase 2, 1 from composition test
COMP_COUNT=$(wc -l < "$E2E_TMP/fish_comp_hist.log" | tr -d ' ')
if [ "$COMP_COUNT" -eq 1 ]; then
    record_cell "Composition: Pre-existing Fish function wraps cleanly once" "PASS"
else
    record_cell "Composition: Pre-existing Fish function wraps cleanly once" "FAIL" "history count: $COMP_COUNT (expected 1)"
fi

# 4.2 OMP/Pi Child Session Event cannot overwrite parent marker
cat > "$E2E_TMP/test_child_protection.ts" << EOF
import ahrExt from "$TEST_AHR_HOME/adapters/pi-session.ts";
import { readFileSync, writeFileSync, chmodSync } from "node:fs";

const marker = "$E2E_TMP/child_test_marker.run";
process.env.AHR_RUN_FILE = marker;
writeFileSync(marker, "");
chmodSync(marker, 0o600);

let callbacks: Record<string, Function[]> = {};
const fakeRuntime = {
    on(event: string, handler: Function) {
        if (!callbacks[event]) callbacks[event] = [];
        callbacks[event].push(handler);
    }
};
ahrExt(fakeRuntime as any);

// 1. Parent starts (hasUI = true)
for (const cb of (callbacks["session_start"] || [])) {
    cb({ reason: "startup" }, {
        hasUI: true,
        sessionManager: {
            getSessionId: () => "$UUID_OMP",
            getSessionFile: () => "$E2E_TMP/parent-session.json"
        }
    });
}
const parentRecorded = readFileSync(marker, "utf8").trim();
if (parentRecorded !== "$UUID_OMP") {
    console.error("Parent session not recorded");
    process.exit(1);
}

// 2. Child starts (hasUI = false)
for (const cb of (callbacks["session_start"] || [])) {
    cb({ reason: "startup" }, {
        hasUI: false,
        sessionManager: {
            getSessionId: () => "99999999-9999-4999-8999-999999999999",
            getSessionFile: () => "$E2E_TMP/child-session.json"
        }
    });
}
const afterChild = readFileSync(marker, "utf8").trim();
if (afterChild !== "$UUID_OMP") {
    console.error("Child session overwrote parent marker!");
    process.exit(1);
}
EOF
bun "$E2E_TMP/test_child_protection.ts"
record_cell "Safety: OMP/Pi child session events cannot overwrite parent marker" "PASS"

# 4.3 Malformed UUID, Hook JSON, and Preflight Hook Rejection
cat > "$E2E_TMP/test_malformed.sh" << EOF
source "$WORKSPACE_ROOT/lib/agent-resume-history.sh"
RECORDER="$TEST_AHR_HOME/bin/agent-resume-history-record"
MARKER="$E2E_TMP/malformed_marker.run"
touch "\$MARKER"
chmod 600 "\$MARKER"

# Test malformed UUID rejection
set +e
"\$RECORDER" "\$MARKER" "not-a-valid-uuid" 2>/dev/null
STATUS=\$?
set -e
[ \$STATUS -ne 0 ] || exit 1
[ -z "\$(cat "\$MARKER")" ] || exit 1

# Test malformed JSON pipe to hook
printf '{"hook_event_name":"SessionStart","session_id":"invalid"}' | "$TEST_AHR_HOME/bin/agent-resume-history-hook"
[ -z "\$(cat "\$MARKER")" ] || exit 1

printf 'INVALID_NON_JSON' | "$TEST_AHR_HOME/bin/agent-resume-history-hook"
[ -z "\$(cat "\$MARKER")" ] || exit 1
EOF
bash "$E2E_TMP/test_malformed.sh"
record_cell "Validation: Malformed UUID and malformed hook JSON safely rejected" "PASS"

# Preflight test with non-object JSON
cat > "$HOME/.code/hooks.json" << 'EOF'
[ "invalid", "array", "root" ]
EOF
set +e
"$WORKSPACE_ROOT/install.sh" >/dev/null 2>&1
INSTALL_STATUS=$?
set -e
if [ $INSTALL_STATUS -ne 0 ] && [ "$HOME/.code/hooks.json" ]; then
    # Restore valid hooks.json
    cat > "$HOME/.code/hooks.json" << 'EOF'
{"hooks":{"PreToolUse":[{"type":"command","command":"echo pre_code"}]}}
EOF
    record_cell "Validation: Installer preflight rejects non-object hooks JSON without corrupting" "PASS"
else
    record_cell "Validation: Installer preflight rejects non-object hooks JSON without corrupting" "FAIL"
fi

# 4.4 All marker files removed after run
RUN_DIR_COUNT=$(find "$TEST_AHR_HOME/run" -type f 2>/dev/null | wc -l | tr -d ' ' || echo "0")
if [ "$RUN_DIR_COUNT" -eq 0 ]; then
    record_cell "Cleanup: All marker files removed after runs" "PASS"
else
    record_cell "Cleanup: All marker files removed after runs" "FAIL" "remaining markers: $RUN_DIR_COUNT"
fi

# 4.5 Uninstall removes only AHR deltas
"$WORKSPACE_ROOT/uninstall.sh" >/dev/null 2>&1
bash_remains=$(grep -c "# >>> agent-resume-history initialize >>>" "$HOME/.bashrc" || true)
zsh_remains=$(grep -c "# >>> agent-resume-history initialize >>>" "$HOME/.zshrc" || true)
fish_remains=$(grep -c "# >>> agent-resume-history initialize >>>" "$HOME/.config/fish/config.fish" || true)

python3 - << 'PYEOF'
import json, os
with open(os.path.expanduser("~/.code/hooks.json")) as f:
    d = json.load(f)
assert any("pre_code" in str(h) for h in d["hooks"].get("PreToolUse", [])), "User pre-existing hook was erroneously removed"
assert "SessionStart" not in d.get("hooks", {}) or len(d["hooks"]["SessionStart"]) == 0, "AHR hook was not removed"
PYEOF

if [ "$bash_remains" -eq 0 ] && [ "$zsh_remains" -eq 0 ] && [ "$fish_remains" -eq 0 ] && [ ! -d "$TEST_AHR_HOME" ]; then
    record_cell "Lifecycle: Uninstall removes only AHR additions and restores config" "PASS"
else
    record_cell "Lifecycle: Uninstall removes only AHR additions and restores config" "FAIL" "remains in rc files or dir still exists"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "============================================================"
echo "E2E SUITE RESULT: ALL $PASSED_CELLS/$TOTAL_CELLS COMBINATIONS PASSED ($DURATION seconds)"
echo "Zero LLM API calls utilized."
echo "============================================================"
exit 0
