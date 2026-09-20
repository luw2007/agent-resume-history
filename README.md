# Agent Resume History

Agent Resume History (AHR) turns the end of an interactive agent session into a one-keystroke resume flow:

```text
$ omp
…work in the session…
$ exit
$ <press Up>
omp --resume 019d1234-5678-7000-8000-123456789abc
```

AHR wraps supported agent commands in your interactive shell. When a new session starts, a small adapter records its UUID in a private temporary marker. After the agent exits, the wrapper appends the exact resume command to shell history while preserving the agent's exit status.

## Support matrix

| Agent CLI | Recorded resume command | Bash | Zsh | Fish |
| --- | --- | :---: | :---: | :---: |
| OMP (`omp`) | `omp --resume UUID` | Yes | Yes | Yes |
| Pi (`pi`) | `pi --session UUID` | Yes | Yes | Yes |
| Claude Code (`claude`) | `claude --resume UUID` | Yes | Yes | Yes |
| Codex CLI (`code`) | `code resume UUID` | Yes | Yes | Yes |
| TraeCode CLI (`traex`) | `traex resume UUID` | Yes | Yes | Yes |

macOS and Linux are supported. AHR only records fresh interactive sessions. Help, version, print/non-interactive, explicit resume, continue, and fork invocations bypass recording.

## Requirements

- Bash 3.2 or newer to run the installer
- Python 3 for safe JSON hook merging and the native hook helper
- Fish, Bash, and Zsh (all three are installer prerequisites because one install configures and verifies every supported shell)
- Bun for OMP/Pi's TypeScript lifecycle adapter
- At least one supported agent CLI for an end-user smoke test

Missing installer prerequisites are fatal; installation never silently skips them. Agent CLIs themselves may be installed later.

## Install v0.1.0

The public GitHub owner is not encoded in this pre-release tree. After publication, set `REPO` to the real `luw2007/agent-resume-history`. Do not pipe a network response into a shell.

### Clone and inspect the release tag

```bash
REPO=luw2007/agent-resume-history
VERSION=v0.1.0
git clone "https://github.com/$REPO.git"
cd agent-resume-history
git checkout --detach "$VERSION"
./install.sh --dry-run
./install.sh
```

### Pinned release archive

```bash
REPO=luw2007/agent-resume-history
VERSION=v0.1.0
workdir="$(mktemp -d)"
curl --fail --location \
  "https://github.com/$REPO/archive/refs/tags/$VERSION.tar.gz" \
  --output "$workdir/agent-resume-history-$VERSION.tar.gz"
tar -xzf "$workdir/agent-resume-history-$VERSION.tar.gz" -C "$workdir"
cd "$workdir/agent-resume-history-${VERSION#v}"
./install.sh --dry-run
./install.sh
```

The default install directory is `~/.local/share/agent-resume-history`. Set an absolute `AHR_HOME` before installation to use another location:

```bash
AHR_HOME="$HOME/tools/agent-resume-history" ./install.sh --dry-run
AHR_HOME="$HOME/tools/agent-resume-history" ./install.sh
```

Use the same `AHR_HOME` for `--verify`, uninstall, and future shell sessions.

## Preview and verify

`--dry-run` performs the same prerequisite, source-artifact, destination, shell-block, and existing hook-JSON validation as installation. It prints each source and target action in deterministic order. It creates no directories, backups, temporary files, or configuration files.

```bash
./install.sh --dry-run
```

`--verify` is read-only. It checks the installed artifact tree, executable bits, managed shell source blocks, and the exact structural hook registration in every supported hook file. It exits nonzero for machine-checkable failures.

```bash
./install.sh --verify
```

Codex and Traex hook trust is private application state. AHR cannot inspect it honestly, so verification reports it as a manual follow-up rather than a pass.

## Files changed by installation

A normal install copies these runtime directories under `AHR_HOME`:

- `bin/`
- `lib/`
- `adapters/`
- `shell/`

It adds one delimited AHR block to these shell files, creating a missing file only after all preflight checks pass:

- `~/.bashrc`
- `~/.bash_profile` only when it already exists
- `~/.zshrc`
- `~/.config/fish/config.fish`

It additively merges one `hooks.SessionStart` entry into each of these JSON files while preserving unrelated keys and hooks:

- `~/.code/hooks.json`
- `~/.codex/hooks.json`
- `~/.trae/cli/hooks.json`
- `~/.trae/hooks.json`

Installation is idempotent. Existing invalid JSON, malformed AHR blocks, missing prerequisites, unreadable source artifacts, unsafe symlink destinations, or unwritable destinations fail before the first filesystem mutation.

## Existing shell functions

Fish can faithfully copy functions. If `omp`, `pi`, `claude`, `code`, or `traex` is already a Fish function when AHR is sourced, AHR copies it once to a private `_ahr_original_<name>` function and composes around it. Re-sourcing does not wrap it again.

Bash and Zsh do not offer a portable, faithful function-copy mechanism across supported versions. AHR therefore leaves an existing function of the same name untouched. To opt that function into AHR, call the public runner explicitly:

```bash
omp() { ahr_run omp "$@"; }
```

Aliases and executable commands are resolved normally.

## Approve native hooks

Codex and Traex may require approval for non-managed hooks. Open each installed CLI and run:

```text
/hooks
```

Review the command. It must point to:

```text
~/.local/share/agent-resume-history/bin/agent-resume-history-hook
```

Approve it if prompted. With a custom `AHR_HOME`, the hook command expands that environment variable at runtime.

## First smoke test

1. Restart the shell, or source the rc file that the installer reported.
2. Start a fresh interactive session with `omp`.
3. Exit the agent.
4. Press Up once.
5. Confirm the recalled command is exactly `omp --resume UUID`.
6. Press Enter to resume.

Repeat with another supported CLI if desired. If Codex or Traex does not add history, complete `/hooks` approval first.

## Troubleshooting

### `--dry-run` rejects a hooks file

Repair the reported JSON file. AHR deliberately refuses to overwrite or reinterpret invalid JSON. Nothing is mutated when preflight fails.

### `--verify` reports a missing shell block

Run `./install.sh` again with the same `HOME` and `AHR_HOME`, then restart the shell. The installer is idempotent.

### A command is not wrapped in Bash or Zsh

Check for an existing function:

```bash
type omp
```

If it is a function, use the explicit `ahr_run` composition shown above. Fish composes existing functions automatically.

### OMP or Pi does not record a session

Confirm `bun --version` succeeds and run `./install.sh --verify`. The lifecycle adapter intentionally ignores child/non-UI sessions and non-resumable sessions.

### Codex or Traex does not record a session

Run `/hooks`, review and approve the AHR hook, then start a new session. `--verify` cannot inspect private trust state.

### History contains no resume entry

AHR requires an interactive shell and a fresh interactive agent run. Explicit resume, continue, fork, help, version, and print/non-interactive commands are intentionally excluded.

## Uninstall

From the checked-out release tree, with the same `AHR_HOME` used to install:

```bash
./uninstall.sh
```

Uninstall removes only the exact AHR-managed shell blocks, exact AHR hook registrations, allowlisted AHR runtime artifacts, and managed directories that are empty afterward. It preserves unrelated shell content, functions, JSON keys, hooks, and files under a custom `AHR_HOME`; a non-empty custom install directory remains in place. It refuses malformed managed blocks, invalid hook JSON, and user-writable symlink components rather than guessing.

## Development

Run the recorder under each supported POSIX-style shell, then run the other three suites from the repository root:

```bash
sh tests/recorder-test.sh
bash tests/recorder-test.sh
zsh tests/recorder-test.sh
./tests/adapters-test.sh
./tests/shell-test.sh
./tests/e2e-test.sh
```

The E2E suite uses isolated temporary `HOME` and `AHR_HOME` directories, mock agent executables, real shell processes, and the real AHR adapters. It makes zero LLM API calls.

## Evidence boundary

Automated tests prove recorder validation, adapter behavior, shell history integration, bypass behavior, isolated install/verify/uninstall behavior, idempotency, and preservation of unrelated configuration. They do not prove compatibility with every future agent CLI version, inspect Codex/Traex private trust registries, perform paid model calls, or validate a future GitHub owner/repository and release archive before those publication inputs exist.

## License

MIT. See [LICENSE](LICENSE).
