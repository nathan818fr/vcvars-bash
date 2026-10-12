# Contributing

Tools and tasks are managed with [mise](https://mise.jdx.dev/) (see
`.config/mise.toml`):
```bash
mise install          # install bats, shellcheck and shfmt
mise run test         # unit tests (any OS)
mise run lint         # shellcheck + shfmt
mise run fmt          # format the scripts
mise run integration  # integration tests (Windows only, needs Visual Studio)
```

All of them run on GitHub Actions for each push and pull request.

To compare the performance of `vcvarsall.sh` versions, e.g. `mise run bench -- main HEAD` (Windows only, not run on
GitHub Actions), see `test/bench.sh -h`.
