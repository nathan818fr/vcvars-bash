# vcvars-bash

[![Test](https://github.com/nathan818fr/vcvars-bash/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/nathan818fr/vcvars-bash/actions/workflows/test.yml?query=branch%3Amain)

Use the Microsoft C++ toolset (MSVC) from Bash on Windows: Git Bash, MSYS2, Cygwin and WSL.

```bash
eval "$(./vcvarsall.sh x64)"
cl /nologo /EHsc /Fe:hello.exe hello.cpp
```

## Installation

In a project (e.g. for its build scripts or CI), download `vcvarsall.sh` from the latest release into it:
```bash
curl -fsSLO https://github.com/nathan818fr/vcvars-bash/releases/latest/download/vcvarsall.sh
chmod +x vcvarsall.sh
```
To also use `vcvarsrun.sh`, download it the same way, next to `vcvarsall.sh`.

For your own shell, clone the repository and add it to your `PATH` (e.g. in `~/.bashrc`):
```bash
git clone https://github.com/nathan818fr/vcvars-bash.git ~/.local/share/vcvars-bash
export PATH="$HOME/.local/share/vcvars-bash:$PATH"
```

Requirements: Visual Studio 2017 or later (or the Build Tools) with the C++ workload, and Bash 4.4+.

## Usage

### vcvarsall.sh

Loads the MSVC environment with `vcvarsall.bat` and prints it as `export` commands, to evaluate in the current shell (Bash, zsh or any POSIX shell):
```bash
eval "$(./vcvarsall.sh [vcvarsall.bat arguments])"
```

Arguments are passed to `vcvarsall.bat` as-is (e.g. `x64`, `x86`, `x64_arm64`, `-vcvars_ver=14.4`), see the [vcvarsall.bat syntax][1].

CMake with NMake (recommended):
```bash
eval "$(./vcvarsall.sh x64)"
cmake -S . -B build -G "NMake Makefiles"
cmake --build build --config Release
```

CMake with Ninja (set `cl` as the compiler, so that CMake doesn't pick another one):
```bash
eval "$(./vcvarsall.sh x64)"
cmake -S . -B build -G Ninja -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl
cmake --build build --config Release
```

Other build systems work the same way: evaluate `vcvarsall.sh`, then build, making sure `cl` is used as the compiler.

### vcvarsrun.sh

Runs a command with the MSVC environment, without changing the current shell:
```bash
./vcvarsrun.sh [vcvarsall.bat arguments] -- command [arguments...]
```

Examples:
```bash
./vcvarsrun.sh x64 -- cl /nologo /EHsc /Fe:hello.exe hello.cpp
./vcvarsrun.sh x64 -- ./my_build_script.sh
```

## Configuration

All optional. Run `./vcvarsall.sh` without arguments for the full help.

| Variable        | Description                                                                      |
|-----------------|----------------------------------------------------------------------------------|
| `VSINSTALLDIR`  | Visual Studio installation to use (default: the latest found by `vswhere.exe`)   |
| `VSWHEREPATH`   | Path to `vswhere.exe` (default: from `PATH`, then its standard location)         |
| `VSWHEREARGS`   | Arguments to select the installation with `vswhere.exe` (default: `-products *`) |
| `VCVARS_SILENT` | Set to `1` to hide the `vcvarsall.bat` banner (still printed if it fails)        |

## Testing

Each change is tested on GitHub Actions:
- **Unit tests** ([bats](https://github.com/bats-core/bats-core)), on Linux and on each Windows environment.
- **Integration tests** against a real Visual Studio installation, on Git Bash, MSYS2, Cygwin and WSL2: compiling and running x64 and x86 programs, `vcvarsrun.sh`, round trips of special and non-ASCII characters, error cases.
- **Lint** with ShellCheck and shfmt.

Performance is also benchmarked (`test/bench.sh`) to compare versions and catch regressions: starting a process is slow on Git Bash, MSYS2 and Cygwin (which emulate `fork`), and even slower with an antivirus scanning each one, so every extra process the script runs can add a noticeable delay.

## Contributing

See [CONTRIBUTING.md](.github/CONTRIBUTING.md) for how to run the tests and linters.

## License

[MIT](LICENSE)

[1]: https://learn.microsoft.com/en-us/cpp/build/building-on-the-command-line?view=msvc-170#vcvarsall-syntax
