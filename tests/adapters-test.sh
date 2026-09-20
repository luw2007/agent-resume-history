#!/bin/sh
# tests/adapters-test.sh
# Focused tests for Agent Resume History adapters.
# Requires Python 3 and Bun; missing prerequisites are failures.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$REPO_ROOT"

for prerequisite in python3 bun; do
    if ! command -v "$prerequisite" >/dev/null 2>&1; then
        echo "FAIL: $prerequisite is required for adapter tests" >&2
        exit 1
    fi
done

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ahr-adapter-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

export AHR_HOME="$REPO_ROOT"
RECORDER="$AHR_HOME/bin/agent-resume-history-record"

if [ ! -x "$RECORDER" ]; then
    echo "FAIL: Recorder $RECORDER not executable" >&2
    exit 1
fi

# -------------------------------------------------------------
# Test 1: JSON Hook Extraction (Claude / Codex / Traex)
# -------------------------------------------------------------
echo "==> Test 1: Hook JSON payload extraction & recording"

# Extract command string from adapters/claude-settings.json
CLAUDE_CMD=$(python3 -c '
import json
with open("adapters/claude-settings.json") as f:
    d = json.load(f)
print(d["hooks"]["SessionStart"][0]["hooks"][0]["command"])
')

TEST_UUID="019a1234-5678-7000-8000-123456789abc"
MARKER="$TEST_TMP/marker.run"

# Create valid mode-600 marker
touch "$MARKER"
chmod 600 "$MARKER"
export AHR_RUN_FILE="$MARKER"

# 1.1 Claude payload format
PAYLOAD_CLAUDE="{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$TEST_UUID\",\"transcript_path\":\"/tmp/transcript.json\"}"
printf '%s' "$PAYLOAD_CLAUDE" | sh -c "$CLAUDE_CMD"

RECORDED=$(cat "$MARKER")
if [ "$RECORDED" != "$TEST_UUID" ]; then
    echo "FAIL: Claude hook wrote '$RECORDED', expected '$TEST_UUID'" >&2
    exit 1
fi
echo "  [OK] Claude payload recorded correctly"

# 1.2 Subagent rejection in hook
SUBAGENT_UUID="019a9999-9999-7000-8000-999999999999"
PAYLOAD_SUBAGENT="{\"hook_event_name\":\"SessionStart\",\"agent_id\":\"sub-123\",\"session_id\":\"$SUBAGENT_UUID\"}"
printf '%s' "$PAYLOAD_SUBAGENT" | sh -c "$CLAUDE_CMD"

# Marker should still have original TEST_UUID, not subagent UUID
RECORDED=$(cat "$MARKER")
if [ "$RECORDED" != "$TEST_UUID" ]; then
    echo "FAIL: Subagent payload overwrote marker: '$RECORDED'" >&2
    exit 1
fi
echo "  [OK] Subagent payload rejected"

# 1.3 Codex payload format
CODEX_CMD=$(python3 -c '
import json
with open("adapters/codex-hooks.json") as f:
    d = json.load(f)
print(d["hooks"]["SessionStart"][0]["hooks"][0]["command"])
')

CODEX_UUID="019b2222-3333-7444-8555-666677778888"
PAYLOAD_CODEX="{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$CODEX_UUID\",\"cwd\":\"/tmp\"}"
printf '%s' "$PAYLOAD_CODEX" | sh -c "$CODEX_CMD"

RECORDED=$(cat "$MARKER")
if [ "$RECORDED" != "$CODEX_UUID" ]; then
    echo "FAIL: Codex hook wrote '$RECORDED', expected '$CODEX_UUID'" >&2
    exit 1
fi
echo "  [OK] Codex payload recorded correctly"

# 1.4 Traex payload format (session_id)
TRAEX_CMD=$(python3 -c '
import json
with open("adapters/traex-hooks.json") as f:
    d = json.load(f)
print(d["hooks"]["SessionStart"][0]["hooks"][0]["command"])
')

TRAEX_UUID="019c3333-4444-7555-8666-777788889999"
PAYLOAD_TRAEX="{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$TRAEX_UUID\"}"
printf '%s' "$PAYLOAD_TRAEX" | sh -c "$TRAEX_CMD"

RECORDED=$(cat "$MARKER")
if [ "$RECORDED" != "$TRAEX_UUID" ]; then
    echo "FAIL: Traex hook wrote '$RECORDED', expected '$TRAEX_UUID'" >&2
    exit 1
fi
echo "  [OK] Traex payload recorded correctly"

# 1.5 thread_id support
THREAD_UUID="019e5555-6666-7777-8888-999900001111"
PAYLOAD_THREAD="{\"hook_event_name\":\"SessionStart\",\"thread_id\":\"$THREAD_UUID\"}"
printf '%s' "$PAYLOAD_THREAD" | sh -c "$CLAUDE_CMD"
RECORDED=$(cat "$MARKER")
if [ "$RECORDED" != "$THREAD_UUID" ]; then
    echo "FAIL: thread_id payload wrote '$RECORDED', expected '$THREAD_UUID'" >&2
    exit 1
fi
echo "  [OK] thread_id payload recorded correctly"

# 1.6 nested session.id support
NESTED_UUID="019f6666-7777-8888-9999-000011112222"
PAYLOAD_NESTED="{\"hook_event_name\":\"SessionStart\",\"session\":{\"id\":\"$NESTED_UUID\"}}"
printf '%s' "$PAYLOAD_NESTED" | sh -c "$CLAUDE_CMD"
RECORDED=$(cat "$MARKER")
if [ "$RECORDED" != "$NESTED_UUID" ]; then
    echo "FAIL: nested session.id payload wrote '$RECORDED', expected '$NESTED_UUID'" >&2
    exit 1
fi
echo "  [OK] nested session.id payload recorded correctly"

# 1.7 Bad payload (invalid JSON)
printf 'not json at all' | sh -c "$CLAUDE_CMD"
RECORDED=$(cat "$MARKER")
if [ "$RECORDED" != "$NESTED_UUID" ]; then
    echo "FAIL: Bad JSON payload changed marker: '$RECORDED'" >&2
    exit 1
fi
echo "  [OK] Bad payload ignored cleanly"

# 1.8 Empty payload
printf '' | sh -c "$CLAUDE_CMD"
RECORDED=$(cat "$MARKER")
if [ "$RECORDED" != "$NESTED_UUID" ]; then
    echo "FAIL: Empty payload changed marker: '$RECORDED'" >&2
    exit 1
fi
echo "  [OK] Empty payload ignored cleanly"

# 1.9 Missing session/thread ID
printf '{"hook_event_name":"SessionStart","foo":"bar"}' | sh -c "$CLAUDE_CMD"
RECORDED=$(cat "$MARKER")
if [ "$RECORDED" != "$NESTED_UUID" ]; then
    echo "FAIL: Missing ID payload changed marker: '$RECORDED'" >&2
    exit 1
fi
echo "  [OK] Missing ID payload ignored cleanly"

# 1.10 No marker behavior (AHR_RUN_FILE unset or empty)
(
    unset AHR_RUN_FILE
    printf '%s' "{\"session_id\":\"019a1111-2222-7333-8444-555566667777\"}" | sh -c "$CLAUDE_CMD"
)
RECORDED=$(cat "$MARKER")
if [ "$RECORDED" != "$NESTED_UUID" ]; then
    echo "FAIL: No marker run modified marker: '$RECORDED'" >&2
    exit 1
fi
echo "  [OK] No marker run exits cleanly as no-op"

# 1.11 Missing marker file on disk
(
    export AHR_RUN_FILE="$TEST_TMP/nonexistent-marker.run"
    printf '%s' "{\"session_id\":\"019a1111-2222-7333-8444-555566667777\"}" | sh -c "$CLAUDE_CMD"
)
if [ -f "$TEST_TMP/nonexistent-marker.run" ]; then
    echo "FAIL: Hook created nonexistent marker file" >&2
    exit 1
fi
echo "  [OK] Nonexistent marker file ignored cleanly"
# -------------------------------------------------------------
# Test 2: Pi / OMP Extension Source Contract Inspection
# -------------------------------------------------------------
echo "==> Test 2: Pi / OMP extension source contract inspection"

EXT_FILE="adapters/pi-session.ts"
if [ ! -f "$EXT_FILE" ]; then
    echo "FAIL: $EXT_FILE not found" >&2
    exit 1
fi

grep -q "AHR_RUN_FILE" "$EXT_FILE" || { echo "FAIL: missing AHR_RUN_FILE in $EXT_FILE" >&2; exit 1; }
grep -q "getSessionId" "$EXT_FILE" || { echo "FAIL: missing getSessionId in $EXT_FILE" >&2; exit 1; }
grep -q "getSessionFile" "$EXT_FILE" || { echo "FAIL: missing getSessionFile in $EXT_FILE" >&2; exit 1; }
grep -q "agent-resume-history-record" "$EXT_FILE" || { echo "FAIL: missing recorder call in $EXT_FILE" >&2; exit 1; }
grep -q 'ctx.mode === "tui" || ctx.hasUI === true' "$EXT_FILE" || { echo "FAIL: missing Pi / OMP interactive parent guard in $EXT_FILE" >&2; exit 1; }
if grep -q '"agent_start"\|"agent_end"\|"session_shutdown"' "$EXT_FILE"; then
    echo "FAIL: child-prone lifecycle subscriptions remain in $EXT_FILE" >&2
    exit 1
fi
echo "  [OK] Pi / OMP extension adheres to contract"

# -------------------------------------------------------------
# Test 3: Pi / OMP Extension Simulated Runtime
# -------------------------------------------------------------
echo "==> Test 3: Pi / OMP extension execution check"

RUNTIME="bun"

echo "  Running simulation with $RUNTIME..."

SIM_UUID="019d4444-5555-7666-8777-888899990000"

# Run test script that loads extension and invokes callbacks.
$RUNTIME - <<EOF
import ahrExtension from "./adapters/pi-session.ts";
import { readFileSync } from "node:fs";

let registeredCallbacks: Record<string, Function[]> = {};
const fakePi = {
  on(event: string, handler: Function) {
    if (!registeredCallbacks[event]) registeredCallbacks[event] = [];
    registeredCallbacks[event].push(handler);
  }
};

ahrExtension(fakePi as any);

const fireSessionStart = (ctx: unknown) => {
  for (const cb of registeredCallbacks["session_start"] ?? []) cb({ reason: "startup" }, ctx);
};

// OMP has no mode. A fresh session file is not materialized yet, but the
// top-level UI and native session ID are already available.
const ompCtx = {
  hasUI: true,
  sessionManager: {
    getSessionId: () => "$SIM_UUID",
    getSessionFile: () => "$TEST_TMP/not-yet-created-session.json",
  },
};
fireSessionStart(ompCtx);
if (readFileSync(process.env.AHR_RUN_FILE!, "utf8").trim() !== "$SIM_UUID") {
  throw new Error("fresh OMP session was not recorded");
}

// OMP in-process subagents have no UI and must not replace the marker.
fireSessionStart({
  hasUI: false,
  sessionManager: {
    getSessionId: () => "019d9999-9999-7666-8777-888899999999",
    getSessionFile: () => "$TEST_TMP/child-session.json",
  },
});
if (readFileSync(process.env.AHR_RUN_FILE!, "utf8").trim() !== "$SIM_UUID") {
  throw new Error("OMP child overwrote parent marker");
}

// Pi still identifies its interactive parent with mode=tui.
fireSessionStart({
  mode: "tui",
  sessionManager: {
    getSessionId: () => "$SIM_UUID",
    getSessionFile: () => "$TEST_TMP/pi-session.json",
  },
});
EOF

RECORDED=$(cat "$MARKER")
if [ "$RECORDED" != "$SIM_UUID" ]; then
    echo "FAIL: Extension simulation wrote '$RECORDED', expected '$SIM_UUID'" >&2
    exit 1
fi
echo "  [OK] Fresh OMP and Pi parent sessions record without child overwrite"

echo "All adapter tests passed successfully."
