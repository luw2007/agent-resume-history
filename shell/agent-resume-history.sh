# Agent Resume History (AHR) for Bash & Zsh
# Compatible with Bash 3.2+ and Zsh

_ahr_is_interactive() {
    if [ -n "${AHR_FORCE_INTERACTIVE:-}" ]; then
        return 0
    fi
    # Check if stdin and stdout are terminals, or shell is interactive
    if [ -t 0 ] && [ -t 1 ]; then
        return 0
    fi
    case "$-" in
        *i*) return 0 ;;
        *) return 1 ;;
    esac
}

_ahr_should_bypass() {
    local agent arg
    agent="$1"
    shift
    if [ $# -eq 0 ]; then
        return 1
    fi

    # Check for help / version
    for arg in "$@"; do
        case "$arg" in
            -h|--help|-v|--version|-V) return 0 ;;
        esac
    done

    # Agent-specific bypass rules
    case "$agent" in
        omp)
            # --resume, -r, --fork, -p, --print, --pipe, exec, run
            for arg in "$@"; do
                case "$arg" in
                    -r|--resume|--fork|-p|--print|--pipe) return 0 ;;
                esac
            done
            case "$1" in
                exec|run) return 0 ;;
            esac
            ;;
        pi)
            # -s, --session, -r, --resume, -c, --continue, --fork, -p, --print, --pipe
            for arg in "$@"; do
                case "$arg" in
                    -s|--session|-r|--resume|-c|--continue|--fork|-p|--print|--pipe) return 0 ;;
                esac
            done
            ;;
        claude)
            # -r, --resume, -c, --continue, -p, --print
            for arg in "$@"; do
                case "$arg" in
                    -r|--resume|-c|--continue|-p|--print) return 0 ;;
                esac
            done
            ;;
        code)
            # code resume, code exec, code -p
            case "$1" in
                resume|exec) return 0 ;;
            esac
            for arg in "$@"; do
                case "$arg" in
                    -p|--prompt) return 0 ;;
                esac
            done
            ;;
        traex)
            # traex resume, traex fork, traex exec, traex -p
            case "$1" in
                resume|fork|exec) return 0 ;;
            esac
            for arg in "$@"; do
                case "$arg" in
                    -p|--prompt) return 0 ;;
                esac
            done
            ;;
    esac

    return 1
}

ahr_run() {
    local agent real_bin ahr_root marker exit_code uuid resume_cmd
    local -a extra_flags=()
    agent="$1"
    shift

    # Find underlying binary
    # In bash/zsh, 'command -v' gives the path if binary exists
    # Use 'type -p' or PATH search to avoid alias/function
    real_bin=""
    if [ -n "${BASH_VERSION:-}" ]; then
        real_bin=$(type -P "$agent" 2>/dev/null || which "$agent" 2>/dev/null || :)
    elif [ -n "${ZSH_VERSION:-}" ]; then
        real_bin=$(whence -p "$agent" 2>/dev/null || which "$agent" 2>/dev/null || :)
    else
        real_bin=$(which "$agent" 2>/dev/null || :)
    fi

    if [ -z "$real_bin" ]; then
        echo "ahr: command not found: $agent" >&2
        return 127
    fi

    # Non-interactive or bypass requested -> run directly
    if ! _ahr_is_interactive || _ahr_should_bypass "$agent" "$@"; then
        "$real_bin" "$@"
        return $?
    fi

    # Resolve AHR root directory
    ahr_root="${AHR_HOME:-$HOME/.local/share/agent-resume-history}"

    # Load lib
    if [ -f "$ahr_root/lib/agent-resume-history.sh" ]; then
        # shellcheck disable=SC1090
        . "$ahr_root/lib/agent-resume-history.sh"
    fi

    marker=""
    if command -v ahr_create_marker >/dev/null 2>&1; then
        marker=$(ahr_create_marker)
    fi

    if [ -z "$marker" ]; then
        "$real_bin" "$@"
        return $?
    fi

    # Injected flags based on tool
    extra_flags=()
    case "$agent" in
        omp|pi)
            if [ -f "$ahr_root/adapters/pi-session.ts" ]; then
                extra_flags=(-e "$ahr_root/adapters/pi-session.ts")
            fi
            ;;
        claude)
            if [ -f "$ahr_root/adapters/claude-settings.json" ]; then
                extra_flags=(--settings "$ahr_root/adapters/claude-settings.json")
            fi
            ;;
        code|traex)
            # Code and Traex use global SessionStart hooks
            extra_flags=()
            ;;
    esac

    # Execute with AHR_RUN_FILE
    # shellcheck disable=SC2097,SC2098
    AHR_RUN_FILE="$marker" "$real_bin" "${extra_flags[@]+"${extra_flags[@]}"}" "$@"
    exit_code=$?

    # Read and remove marker
    uuid=""
    if command -v ahr_read_and_remove_marker >/dev/null 2>&1; then
        uuid=$(ahr_read_and_remove_marker "$marker")
    else
        rm -f "$marker" 2>/dev/null || :
    fi

    if [ -n "$uuid" ]; then
        resume_cmd=""
        case "$agent" in
            omp) resume_cmd="omp --resume $uuid" ;;
            pi) resume_cmd="pi --session $uuid" ;;
            claude) resume_cmd="claude --resume $uuid" ;;
            code) resume_cmd="code resume $uuid" ;;
            traex) resume_cmd="traex resume $uuid" ;;
        esac

        if [ -n "$resume_cmd" ]; then
            if [ -n "${ZSH_VERSION:-}" ]; then
                print -s "$resume_cmd" 2>/dev/null || :
            elif [ -n "${BASH_VERSION:-}" ]; then
                history -s "$resume_cmd" 2>/dev/null || :
            fi
        fi
    fi

    return $exit_code
}

_ahr_define_wrappers() {
    local _ahr_cmd
    for _ahr_cmd in omp pi claude code traex; do
        if [ -n "${BASH_VERSION:-}" ]; then
            if [ "$(type -t "$_ahr_cmd" 2>/dev/null)" = "function" ]; then
                continue
            fi
        elif [ -n "${ZSH_VERSION:-}" ]; then
            if (( $+functions[$_ahr_cmd] )); then
                continue
            fi
        fi

        eval "$_ahr_cmd() { ahr_run $_ahr_cmd \"\$@\"; }"
    done
}

_ahr_define_wrappers
