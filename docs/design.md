# Design (Draft)

## Goals

- Implement a gmake-compatible engine in **pure mruby**.
- Support the subset of GNU Make used by CRuby’s build.
- Keep the system testable: deterministic parsing, isolated evaluator, and small I/O surface.

## Architecture

```
CLI (tools/rmake)
  -> Parser (Makefile -> AST)
  -> Evaluator (AST -> Rule Graph + Vars)
  -> Executor (Graph -> Jobs)
```

### Key Modules

- `RMake::Parser`
  - Tokenize and parse Makefile lines, handle line continuations and includes.
  - Emit a simple AST.

- `RMake::Evaluator`
  - Apply conditionals and variable assignments.
  - Expand variables/functions.
  - Build `Rule` objects and a dependency graph.

- `RMake::Graph`
  - Directed graph of targets and prerequisites.
  - Methods to topologically order jobs and detect cycles.

- `RMake::Executor`
  - Run recipes, with `-j` support.
  - Honor `@` and `-` prefixes.
  - Provide dry-run and verbose modes.

- `RMake::Shell`
  - Platform abstraction for command execution.
  - For mruby, use `Kernel.system` and `IO.popen` where available.

## Execution Model

1. Read root Makefile (`-f` overrides), process line continuations.
2. Parse statements into AST nodes.
3. Evaluate conditionals and build variable environment.
4. Build rule graph, resolve targets.
5. Execute target (default is first non-special rule).

## GNU Make Compatibility Strategy

- Start with CRuby-driven behavior tests.
- Add functions incrementally (focus on those used by CRuby).
- Keep function semantics modular to allow swaps if differences emerge.

## Risk Areas

- Variable expansion order and recursive vs simple variables.
- Pattern rules and automatic variables.
- Shell execution and quoting differences per platform.

