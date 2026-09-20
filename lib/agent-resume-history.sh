#!/bin/sh
# agent-resume-history common library (POSIX / Bash 3.2 / Zsh compatible)

ahr_home() {
    if [ -n "${AHR_HOME:-}" ]; then
        printf '%s\n' "$AHR_HOME"
    else
        printf '%s\n' "${HOME:-.}/.local/share/agent-resume-history"
    fi
}

ahr_canonical_uuid() {
    raw="${1:-}"
    nl='
'
    case "$raw" in
        *"$nl"*) return 1 ;;
    esac
    case "$raw" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
            printf '%s\n' "$raw" | tr '[:upper:]' '[:lower:]'
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

ahr_create_marker() {
    home_dir=$(ahr_home)
    run_dir="$home_dir/run"
    if [ ! -d "$run_dir" ]; then
        mkdir -p "$run_dir" 2>/dev/null || return 1
        chmod 700 "$run_dir" 2>/dev/null || :
    else
        chmod 700 "$run_dir" 2>/dev/null || :
    fi

    # Create temporary marker file with mode 0600
    old_umask=$(umask)
    umask 077
    marker=$(mktemp "$run_dir/ahr_marker_XXXXXX" 2>/dev/null) || marker=""
    umask "$old_umask"

    if [ -z "$marker" ] || [ ! -f "$marker" ]; then
        return 1
    fi
    chmod 600 "$marker" 2>/dev/null || :

    # Ensure path is absolute
    case "$marker" in
        /*) printf '%s\n' "$marker" ;;
        *) printf '%s/%s\n' "$(pwd)" "$marker" ;;
    esac
    return 0
}

ahr_validate_marker() {
    m="${1:-}"
    [ -n "$m" ] || return 1
    # Must be absolute path
    case "$m" in
        /*) ;;
        *) return 1 ;;
    esac

    # Must exist and be a regular file (not dir, socket, fifo, device)
    [ -f "$m" ] || return 1
    # Must not be a symlink
    [ ! -L "$m" ] || return 1

    # Must be writable
    [ -w "$m" ] || return 1

    # Check ownership: must be owned by current user
    if ! [ -O "$m" ] 2>/dev/null; then
        cur_uid=$(id -u 2>/dev/null || :)
        file_uid=$(stat -f "%u" "$m" 2>/dev/null || stat -c "%u" "$m" 2>/dev/null || :)
        if [ -z "$cur_uid" ] || [ -z "$file_uid" ] || [ "$cur_uid" != "$file_uid" ]; then
            return 1
        fi
    fi

    # Check permissions: owner read/write (0600), no group/other permissions
    file_perm=$(stat -f "%Lp" "$m" 2>/dev/null || stat -c "%a" "$m" 2>/dev/null || :)
    case "$file_perm" in
        600|0600) ;;
        *) return 1 ;;
    esac

    return 0
}

ahr_read_and_remove_marker() {
    m="${1:-}"
    [ -n "$m" ] || return 1

    # Safe validation before acting
    if ! ahr_validate_marker "$m"; then
        return 1
    fi

    # Read exactly the first line
    line=""
    if [ -r "$m" ]; then
        read -r line < "$m" 2>/dev/null || :
    fi

    # Per contract: must always remove a safe marker even if its contents are malformed
    rm -f "$m" 2>/dev/null || :

    # Validate UUID
    if canon_id=$(ahr_canonical_uuid "$line"); then
        printf '%s\n' "$canon_id"
        return 0
    else
        return 1
    fi
}
