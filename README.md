# vcvars-bash

Use the Microsoft C++ toolset from Bash!

## vcvarsall.sh

This script load MSVC environment variables using `vcvarsall.bat` and exports
them.
It is intended to be evaluated (by Bash or any other POSIX-compatible shell,
since it writes a list of export commands to stdout).

Usage: `eval "$(vcvarsall.sh [vcvarsall.bat arguments])"`

See [Microsoft vcvarsall.bat syntax][1] for vcvarsall.bat arguments
documentation.

Example:
```bash
eval "$(./vcvarsall.sh x64)"
cmake -S ..  -B build -G "NMake Makefiles"
cmake --build build --config Release
```

## vcvarsrun.sh

Like `vcvarsall.sh`, but runs a command instead of exporting variables.

Usage: `vcvarsrun.sh [vcvarsall.bat arguments] -- command [arguments...]`

Example:
```bash
./vcvarsrun.sh x64 -- cl /nologo /EHsc /Fe:hello.exe hello.cpp
./vcvarsrun.sh x64 -- ./my_build_script.sh
```

## Compatibility

These scripts are designed to run on Windows with Bash.
They work with:
- Git Bash
- WSL
- MSYS2
- Cygwin

## Configuration (optional)

To work, these scripts must locate `vcvarsall.bat`.\
By default, it uses `vswhere.exe` (installed with Visual Studio) to
automatically find the latest Visual Studio installation.\
You can override this behavior by setting the `VSINSTALLDIR` environment
variable (e.g.
`VSINSTALLDIR='C:\Program Files\Microsoft Visual Studio\2022\Community'`).


[1]: https://learn.microsoft.com/en-us/cpp/build/building-on-the-command-line?view=msvc-170#vcvarsall-syntax
