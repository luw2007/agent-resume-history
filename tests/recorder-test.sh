#!/bin/sh
# tests/recorder-test.sh - Focused test suite for recorder and common library
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)

# Create isolated test environment
TMP_TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_TEST_DIR"' EXIT INT TERM

export HOME="$TMP_TEST_DIR/home"
export AHR_HOME="$TMP_TEST_DIR/ahr_home"
mkdir -p "$HOME" "$AHR_HOME"

# shellcheck source=../lib/agent-resume-history.sh
. "$ROOT_DIR/lib/agent-resume-history.sh"
RECORD_BIN="$ROOT_DIR/bin/agent-resume-history-record"

pass_count=0
fail_count=0

assert_eq() {
    expected="$1"
    actual="$2"
    desc="$3"
    if [ "$expected" = "$actual" ]; then
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc (expected '$expected', got '$actual')" >&2
        fail_count=$((fail_count + 1))
    fi
}

assert_status() {
    expected="$1"
    actual="$2"
    desc="$3"
    if [ "$expected" -eq "$actual" ]; then
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc (expected exit code $expected, got $actual)" >&2
        fail_count=$((fail_count + 1))
    fi
}

echo "=== Test 1: ahr_home default and override ==="
assert_eq "$TMP_TEST_DIR/ahr_home" "$(ahr_home)" "AHR_HOME override respected"
(
    unset AHR_HOME
    assert_eq "$HOME/.local/share/agent-resume-history" "$(ahr_home)" "Default AHR_HOME under HOME"
)

echo "=== Test 2: ahr_canonical_uuid validation and lowercasing ==="
uuid_lower="9f533d73-5db9-42f3-b8fc-903489b76589"
uuid_upper="9F533D73-5DB9-42F3-B8FC-903489B76589"

assert_eq "$uuid_lower" "$(ahr_canonical_uuid "$uuid_lower")" "Valid lowercase UUID"
assert_eq "$uuid_lower" "$(ahr_canonical_uuid "$uuid_upper")" "Uppercase UUID canonicalized to lowercase"

set +e
ahr_canonical_uuid "invalid-uuid" >/dev/null 2>&1
assert_status 1 $? "Invalid string rejected"

ahr_canonical_uuid "/etc/passwd" >/dev/null 2>&1
assert_status 1 $? "Path injection rejected"

ahr_canonical_uuid "9f533d73-5db9-42f3-b8fc-903489b76589
9f533d73-5db9-42f3-b8fc-903489b76589" >/dev/null 2>&1
assert_status 1 $? "Multiline injection rejected"

ahr_canonical_uuid "9f533d73-5db9-42f3-b8fc-903489b7658" >/dev/null 2>&1
assert_status 1 $? "Short UUID rejected"
set -e

echo "=== Test 3: ahr_create_marker ==="
marker_path=$(ahr_create_marker)
[ -n "$marker_path" ] && [ -f "$marker_path" ]
assert_status 0 $? "Marker file created"

case "$marker_path" in
    /*) assert_status 0 0 "Marker path is absolute" ;;
    *) assert_status 0 1 "Marker path must be absolute" ;;
esac

perm=$(stat -f "%Lp" "$marker_path" 2>/dev/null || stat -c "%a" "$marker_path" 2>/dev/null)
assert_eq "600" "$perm" "Marker file permissions 0600"

echo "=== Test 4: Record valid UUID (two arguments) ==="
cmd_st=0
"$RECORD_BIN" "$marker_path" "$uuid_upper" || cmd_st=$?
assert_status 0 $cmd_st "Record exits 0 on valid input"

content=$(cat "$marker_path")
assert_eq "$uuid_lower" "$content" "Marker contains canonical lowercase UUID"

echo "=== Test 5: ahr_read_and_remove_marker consumes valid marker ==="
read_uuid=$(ahr_read_and_remove_marker "$marker_path")
assert_eq "$uuid_lower" "$read_uuid" "Read output matches canonical UUID"
[ ! -f "$marker_path" ]
assert_status 0 $? "Marker file unlinked after read"

echo "=== Test 6: Malformed content removed and rejected by ahr_read_and_remove_marker ==="
marker2=$(ahr_create_marker)
printf "corrupt_data\n" > "$marker2"
set +e
bad_uuid=$(ahr_read_and_remove_marker "$marker2" 2>/dev/null)
bad_st=$?
set -e
assert_status 1 $bad_st "Read of malformed marker returns non-zero"
assert_eq "" "$bad_uuid" "No output emitted on malformed read"
[ ! -f "$marker2" ]
assert_status 0 $? "Malformed safe marker unlinked per contract"

echo "=== Test 7: Record with single argument using AHR_RUN_FILE ==="
marker3=$(ahr_create_marker)
export AHR_RUN_FILE="$marker3"
cmd_st=0
"$RECORD_BIN" "$uuid_lower" || cmd_st=$?
assert_status 0 $cmd_st "Record exits 0 with AHR_RUN_FILE"
assert_eq "$uuid_lower" "$(cat "$marker3")" "Marker has valid UUID"
rm -f "$marker3"
unset AHR_RUN_FILE

echo "=== Test 8: Reject unsafe marker targets ==="
# Missing target
set +e
"$RECORD_BIN" "$TMP_TEST_DIR/nonexistent_file" "$uuid_lower" 2>/dev/null
assert_status 3 $? "Non-existent marker rejected"

# Directory target
dir_target="$TMP_TEST_DIR/dir_target"
mkdir -p "$dir_target"
chmod 700 "$dir_target"
"$RECORD_BIN" "$dir_target" "$uuid_lower" 2>/dev/null
assert_status 3 $? "Directory marker rejected"

# Insecure permissions (0644 or 0666)
insecure_marker=$(ahr_create_marker)
chmod 644 "$insecure_marker"
"$RECORD_BIN" "$insecure_marker" "$uuid_lower" 2>/dev/null
assert_status 3 $? "Insecure 0644 marker rejected"
rm -f "$insecure_marker"

# Symlink target
real_file=$(ahr_create_marker)
symlink_marker="$TMP_TEST_DIR/symlink_marker"
ln -s "$real_file" "$symlink_marker"
"$RECORD_BIN" "$symlink_marker" "$uuid_lower" 2>/dev/null
assert_status 3 $? "Symlink marker rejected"
rm -f "$real_file" "$symlink_marker"

# Malformed UUID does not modify marker
marker4=$(ahr_create_marker)
echo "pre_existing" > "$marker4"
chmod 600 "$marker4"
"$RECORD_BIN" "$marker4" "not-a-valid-uuid" 2>/dev/null
assert_status 2 $? "Malformed UUID rejected with code 2"
assert_eq "pre_existing" "$(cat "$marker4")" "Marker preserved on malformed rejection"
rm -f "$marker4"
set -e

echo "=== Test 9: Stdin support via '-' arg ==="
marker5=$(ahr_create_marker)
printf '%s\n' "$uuid_lower" | "$RECORD_BIN" "$marker5" -
assert_eq "$uuid_lower" "$(cat "$marker5")" "Record via stdin '-' succeeds"
rm -f "$marker5"

echo "=== Test 10: Old unpublished alias is absent ==="
[ ! -e "$ROOT_DIR/bin/ahr-record" ]
assert_status 0 $? "Obsolete bin/ahr-record alias removed"

echo ""
echo "=== Test Summary ==="
echo "Passed: $pass_count"
echo "Failed: $fail_count"

if [ $fail_count -gt 0 ]; then
    exit 1
fi
echo "All tests passed successfully!"
exit 0
