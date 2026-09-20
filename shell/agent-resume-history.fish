# Agent Resume History (AHR) for Fish

function _ahr_is_interactive
    if test -n "$AHR_FORCE_INTERACTIVE"
        return 0
    end
    test -t 0 -a -t 1
end

function _ahr_should_bypass
    set -l agent $argv[1]
    set -e argv[1]

    # If no args, it is interactive start
    if test (count $argv) -eq 0
        return 1
    end

    # Check for help / version
    for arg in $argv
        switch $arg
            case -h --help -v --version -V
                return 0
        end
    end

    # Agent-specific bypass rules
    switch $agent
        case omp
            # Bypass resume/fork/non-interactive
            # --resume, -r, --fork, -p, --print, --pipe, exec, run
            for arg in $argv
                switch $arg
                    case -r --resume --fork -p --print --pipe
                        return 0
                end
            end
            if contains -- $argv[1] exec run
                return 0
            end

        case pi
            # pi --session, -s, --resume, -r, --continue, -c, --fork, -p, --print, --pipe
            for arg in $argv
                switch $arg
                    case -s --session -r --resume -c --continue --fork -p --print --pipe
                        return 0
                end
            end

        case claude
            # claude --resume, -r, --continue, -c, -p, --print
            for arg in $argv
                switch $arg
                    case -r --resume -c --continue -p --print
                        return 0
                end
            end

        case code
            # code resume, code exec, code -p
            if test (count $argv) -ge 1
                switch $argv[1]
                    case resume exec
                        return 0
                end
            end
            for arg in $argv
                switch $arg
                    case -p --prompt
                        return 0
                end
            end

        case traex
            # traex resume, traex fork, traex exec
            if test (count $argv) -ge 1
                switch $argv[1]
                    case resume fork exec
                        return 0
                end
            end
            for arg in $argv
                switch $arg
                    case -p --prompt
                        return 0
                end
            end
    end

    return 1
end

function ahr_run --description "Run an agent command wrapped with history resume tracking"
    set -l agent $argv[1]
    set -e argv[1]

    # Existing Fish functions are cloned before AHR defines its public wrapper.
    # Tracked runs compose through that clone. Bypass calls go straight to the
    # executable so helper functions that depend on AHR_RUN_FILE are not invoked
    # without a marker.
    set -l original_function "_ahr_original_$agent"
    set -l executable (command -v $agent 2>/dev/null)
    set -l runner $executable
    if functions -q $original_function
        set runner $original_function
    end
    if test -z "$runner"
        echo "ahr: command not found: $agent" >&2
        return 127
    end

    # Non-interactive or bypass requested -> run the executable directly.
    if not _ahr_is_interactive; or _ahr_should_bypass $agent $argv
        if test -n "$executable"
            $executable $argv
        else
            $runner $argv
        end
        return $status
    end

    # Resolve AHR root directory
    set -l ahr_root
    if test -n "$AHR_HOME"
        set ahr_root "$AHR_HOME"
    else
        set ahr_root "$HOME/.local/share/agent-resume-history"
    end

    # Create marker via lib/agent-resume-history.sh
    set -l marker
    if test -f "$ahr_root/lib/agent-resume-history.sh"
        set marker (sh -c ". \"$ahr_root/lib/agent-resume-history.sh\" && ahr_create_marker")
    end

    if test -z "$marker"
        $runner $argv
        return $status
    end
    # Preserve the original arguments while adding AHR's adapter flags.
    set -l extra_args
    switch $agent
        case omp pi
            if test -f "$ahr_root/adapters/pi-session.ts"
                set extra_args -e "$ahr_root/adapters/pi-session.ts"
            end
        case claude
            if test -f "$ahr_root/adapters/claude-settings.json"
                set extra_args --settings "$ahr_root/adapters/claude-settings.json"
            end
        case code traex
            # Code and Traex use global SessionStart hooks installed in hooks.json
            set extra_args
    end

    # Execute with AHR_RUN_FILE exported
    set -lx AHR_RUN_FILE "$marker"
    $runner $extra_args $argv
    set -l exit_code $status

    # Read and remove marker safely using central lib
    set -l uuid
    if test -f "$ahr_root/lib/agent-resume-history.sh"
        set uuid (sh -c ". \"$ahr_root/lib/agent-resume-history.sh\" && ahr_read_and_remove_marker \"$marker\"")
    else
        # Safety fallback
        rm -f "$marker" 2>/dev/null
    end

    # If valid UUID recorded, append exact resume command to fish history
    if test -n "$uuid"
        set -l resume_cmd
        switch $agent
            case omp
                set resume_cmd "omp --resume $uuid"
            case pi
                set resume_cmd "pi --session $uuid"
            case claude
                set resume_cmd "claude --resume $uuid"
            case code
                set resume_cmd "code resume $uuid"
            case traex
                set resume_cmd "traex resume $uuid"
        end

        if test -n "$resume_cmd"
            builtin history append "$resume_cmd" 2>/dev/null; or history append "$resume_cmd" 2>/dev/null
        end
    end

    return $exit_code
end

# Compose once with pre-existing Fish functions, then expose AHR wrappers.
begin
    set -q _ahr_wrapped_commands; or set -g _ahr_wrapped_commands
    for cmd in omp pi claude code traex
        if contains -- $cmd $_ahr_wrapped_commands
            continue
        end

        set -l original_function "_ahr_original_$cmd"
        if functions -q $cmd
            functions --copy $cmd $original_function
            functions --erase $cmd
        end

        function $cmd --inherit-variable cmd --wraps $cmd
            ahr_run $cmd $argv
            return $status
        end
        set -a _ahr_wrapped_commands $cmd
    end
end
