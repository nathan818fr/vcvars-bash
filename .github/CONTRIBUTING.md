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
