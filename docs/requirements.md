# MVP Requirements (Draft)

This document captures the **minimum GNU Make compatibility** required to build CRuby.
We will refine this after sampling CRuby’s `Makefile` and `ext/*/Makefile` usage.

## Target Workflows

- `./configure && make`
- `make -jN` (parallel builds)
- `make install` (optional, lower priority for MVP)

## Required GNU Make Features (initial guess)

Rules and prerequisites
- Explicit rules: `target: prereq1 prereq2`
- Multiple targets in a rule line
- Phony targets: `.PHONY`
- Pattern rules: `%.o: %.c`
- Suffix rules (optional, can be mapped to patterns)
- Order-only prerequisites: `target: normal | order-only`

Variables and functions
- Recursive and simple variables: `VAR = ...`, `VAR := ...`
- Appending: `VAR += ...`
- Substitution: `$(VAR:%.c=%.o)` or `$(VAR:.c=.o)`
- Built-in vars: `$@`, `$<`, `$^`, `$*`, `$?`
- `$(shell ...)` (limited)
- `$(wildcard ...)`, `$(patsubst ...)`, `$(subst ...)`
- `$(if ...)`, `$(filter ...)`, `$(filter-out ...)`
- `$(dir ...)`, `$(notdir ...)`, `$(basename ...)`, `$(suffix ...)`
- `$(addprefix ...)`, `$(addsuffix ...)`, `$(sort ...)`, `$(strip ...)`

Include
- `include` and `-include` (missing file is ok for `-include`)

Execution
- Command recipes with `@` and `-` prefixes
- `make -n` (dry-run) optional for MVP
- `make -jN` (parallel) required for real-world speed

Conditionals
- `ifeq`, `ifneq`, `ifdef`, `ifndef`, `else`, `endif`

Specials
- `.DEFAULT` and `.SUFFIXES` (optional)
- `.DELETE_ON_ERROR` (optional)

## Non-goals (MVP)

- Full GNU Make compatibility.
- Jobserver integration.
- `eval`, `define`, `call` beyond what CRuby needs.

