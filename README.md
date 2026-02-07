# rmake

`rmake` is a **make-compatible build runner** implemented in **mruby** with the explicit goal of
building CRuby across platforms using a single make engine.

This repository is intentionally minimal today: we’re defining the MVP scope and scaffolding a
clean, testable architecture so we can grow compatibility in a controlled way.

## Goal

- Run enough of CRuby’s Makefiles to build a default CRuby on supported platforms.
- Prefer compatibility with standard make behavior first, then GNU Make where it matters.
- Keep the implementation small and testable; native extensions are used only when needed.

## Quick Start (dev)

This is a mruby gem-style layout.

- `mrbgem.rake` defines the gem.
- `mrblib/` contains the mruby sources.
- `tools/rmake` is the CLI entrypoint (invoked via `mruby tools/rmake`).

## Rake Tasks

Use the top-level `Rakefile` for both tests and packaging:

```sh
rake -T
```

Main tasks:

- `rake test` (same as `rake test:all`)
- `rake test:unit`
- `rake test:micro`
- `rake test:gnu`
- `rake build` (same as `rake build:rmake`)
- `rake build:rmake_no_clean`
- `rake rmake:clean`

### Build mruby

`rmake` ships a local mruby build under `mruby/` and includes `mruby-file-stat` for fast `File.mtime`.
`File.mtime` support is required.

```sh
cd mruby
make clean all
```

### Run

```sh
/path/to/mruby/bin/mruby tools/rmake [options] [target] [VAR=VALUE]
```

Options:

- `-f FILE` Read FILE as a makefile
- `-j N`    Run N jobs in parallel
- `-n`      Dry-run (print commands without running)
- `-q`      Question mode (exit 0/1/2 without running recipes)
- `-d`      Trace target evaluation and skips

## Single Binary (rmake)

Build a standalone `rmake` binary (contains mruby + rmake bytecode):

```sh
rake build:rmake
```

Output:

- `dist/rmake-<os>-<arch>` (or `.exe` on Windows)

Optional env vars:

- `RMAKE_NO_CLEAN=1` skip `mruby` clean before build
- `RMAKE_OUT_TAG=<tag>` override output suffix
- `CC=<compiler>` override C compiler for launcher link
- `RMAKE_EXTRA_LDFLAGS="..."` extra linker flags
- `RMAKE_TOOLCHAIN=<toolchain>` force mruby toolchain (`gcc`, `clang`, etc)

## Status

- Parser/evaluator/executor are in `mrblib/` with a growing test suite.
- Standard make compatibility is the current focus before GNU make extensions.

## Supported (today)

- Variable assignments: `=`, `:=`, `+=`
- Conditionals: `ifeq`, `ifneq`, `else ifeq`, `else ifneq`, `else`, `endif`
- Includes: `include`, `-include`, `!include`
- Targets and recipes, order-only prerequisites (`|`)
- Suffix rules like `.c.o:`
- `.PHONY`, `.PRECIOUS`, `.DELETE_ON_ERROR`
- VPATH search for prerequisites
- `-j` parallel builds (when `Process.spawn` is available)
- `-n` dry-run prints commands (even for `@` lines, like GNU make)
- `-d` trace mode for debugging

## Not Yet Supported

- GNU make functions like `$(if ...)`, `$(or ...)`, `$(and ...)`, `$(filter ...)`, `$(eval ...)`, `$(call ...)`
- Pattern rules (`%`) and advanced automatic variables
- `.ONESHELL`, `.SECONDEXPANSION`, and other GNU make extensions

## Tests

```sh
rake test
```

`test/run_gnumake_compat.rb` downloads GNU make's `run_make_tests.pl` at runtime
(default URLs:
`https://cgit.git.savannah.gnu.org/cgit/make.git/plain/tests/run_make_tests.pl`,
`https://raw.githubusercontent.com/mirror/make/master/tests/run_make_tests.pl`).
If `tmp/run_make_tests.pl` exists, it is used as-is and no download is attempted.
Set `RUN_MAKE_TESTS_FETCH=0` to forbid downloads (missing local file then fails).

`tmp/` and `work/` are scratch directories. They are intentionally ignored by git
and can be removed at any time.

`test/run_all.rb` is the integrated suite runner. It executes:

- local regression tests (`test/run.rb`)
- gmake micro-compat tests (`test/run_gnumake_compat.rb`)
- GNU `run_make_tests.pl` selected categories via `test/rmake-make-driver.pl`

Useful env vars:

- `GNU_MAKE_TESTS_DIR=/path/to/make/tests` to use a pre-existing GNU test tree
- `RMAKE_GNU_TESTS_FETCH=0` to disable automatic clone of GNU make tests
- `RMAKE_GNU_CATEGORIES=cat1,cat2,...` to run a subset of GNU categories
- `RMAKE_GNU_PROGRESS_SEC=20` to print periodic progress while GNU categories run
- `RMAKE_GNU_TIMEOUT=1200` to set timeout seconds for GNU categories step

## CI Artifacts

`.github/workflows/build-rmake.yml` builds `rmake` artifacts for:

- Linux x86_64
- macOS x86_64
- macOS arm64
- Windows x86_64

## Next

- Tighten standard make compatibility and fixture coverage
- Implement minimal GNU make functions required by CRuby build
