# Contributing

Thanks for helping improve Agent Resume History.

## Before changing code

- Keep the public `AHR_*` environment variables and `ahr_*` shell functions stable.
- Preserve unrelated user shell content and hook configuration.
- Keep installer validation ahead of every filesystem mutation.
- Never make tests or development commands write to your real home directory. Use isolated temporary `HOME` and `AHR_HOME` values.
- Keep the implementation portable across macOS and Linux, Bash 3.2+, Zsh, and Fish.

## Development setup

Install Bash, Zsh, Fish, Python 3, and Bun. Clone the repository, then run the recorder under each supported POSIX-style shell and the other three suites from its root:

```bash
sh tests/recorder-test.sh
bash tests/recorder-test.sh
zsh tests/recorder-test.sh
./tests/adapters-test.sh
./tests/shell-test.sh
./tests/e2e-test.sh
```

The suites use mock agent executables and make no LLM API calls.

## Pull requests

Keep each change focused. Describe the user-visible behavior, platforms exercised, and exact commands run. Add or adjust tests for observable contracts and safety boundaries rather than implementation details. Do not commit generated caches, local environment files, credentials, personal paths, or test output.

Changes to installation or uninstallation must demonstrate:

1. invalid prerequisites/configuration fail before mutation;
2. dry-run makes zero filesystem changes;
3. verify is read-only and returns nonzero on machine-checkable failures;
4. unrelated rc content, functions, JSON keys, and hooks survive;
5. uninstall removes only AHR-managed deltas.
