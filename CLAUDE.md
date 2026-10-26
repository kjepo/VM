# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A single-file C implementation of an SECD machine (Stack, Environment, Control, Dump) evaluating untyped lambda calculus, following Field & Harrison, *Functional Programming*. There is no build system, test suite, parser or input. The program to run is built by hand in `main()`.

There are two versions:
- `secd.c` is the original. It crashes (see "Known pitfalls in `secd.c`") and does not build as C23.
- `secd23.c` is the fixed version. It builds as C17 or C23, and `pred`, `iszero` and `fac` give correct results. Work in this file unless told otherwise.

## Build and run

```sh
cc -std=c23 -Wall -o secd23 secd23.c
./secd23
```

`secd.c` needs `-std=c17` or earlier, because it has local variables named `true` and `false`, which are keywords in C23. `secd23.c` renames them `tru` and `fls`.

Each machine step prints the rule fired (`ID`, `LAM`, `APP`) plus a full state dump via `dbg()`, so output gets large fast. Pipe it through `head` or `timeout` when experimenting.

## Architecture

- **Three cell types, each with an intrusive `next` pointer:** `EXP` (lambda terms: `ID`, `LAM`, `APP`, plus the `AT` "apply" marker), `WHNF` (values: `INT`, `PRIM`, `CLOSURE`) and `ENV` (name→value bindings). The stack is a linked list of `WHNF` cells and the control is a linked list of `EXP` cells, both threaded through `next`. There are no separate list nodes.
- **`STATE`** holds S/E/C plus `dump`, a pointer to the saved `STATE`, so the dump is a chain of states.
- **Identifiers are single `char`s.** Variable lookup (`valueof`) is a linear search of the `ENV` list and calls `exit(1)` when a name is unbound.
- **Transition rules** are in the `while` loop in `main()`, labelled with the book's case numbers:
  - 1a `ID`: push the variable's value.
  - 1b `LAM`: push a closure.
  - 1c `APP`: rewrite control to `rand; rator; @; rest`.
  - 1d `AT`: apply the closure (1dii) by pushing a dump frame. Primitive application (1di) is an empty stub. `PRIM`/`primop` exist but are not used yet.
  - 2: control is empty, so pop the dump.
- **Church encodings** (`Z` combinator, booleans, numerals, `succ`, `plus`, `times`, `pred`, `iszero`, `H`/`fac`) are built in `main()` with `mklam`/`mkapp`/`mkid`. Choose what runs by setting `machine->control`.
- Memory is never freed. The `MK*` macros abort when `malloc` fails.

## Rules that keep `secd23.c` correct

- **Never write `next` on a cell that might be shared.** Lambda terms are reused freely (`tru`, `succ` and `pred` appear inside several definitions), and the stack and control lists are threaded through the cells' own `next` fields. So case 1c pushes `copyexp` copies of the rator and rand, and `push` stores a `copywhnf` copy. A value bound in the environment is also a copy with `next = 0`. Otherwise `print_whnf`, which follows `next`, would print the rest of the stack as part of the value.
- **The machine evaluates arguments eagerly.** With Church booleans, both branches of a conditional are evaluated before one is chosen. `H` therefore wraps each branch in `λd.` and applies the chosen one to a dummy argument. Without that, `fac` recurses forever.
- **To read a result:** booleans print as closures `<\y.x,...>` (true) or `<\y.y,...>` (false). Numerals print as nested closures, so the easiest check is `iszero` after k applications of `pred`.
- The per-step `dbg()` dump gets very large on long runs such as `fac 3`. Drop it when you only need the final state.

## Known pitfalls in `secd.c`

- **Shared `EXP` nodes are corrupted by evaluation.** Case 1c writes `next` on the original rator and rand nodes. When a subtree is used twice (`succ` in `mkapp(succ, one)` where `one = mkapp(succ, zero)`), the control list becomes a cycle, and the program segfaults within a few steps.
- **The `mk*` constructors never initialize `next`.**
- Case 1d does not check that the stack holds a function and an argument.
- `pred` is wrong: its code has `g h` where the comment has `g f`, and it nests the applications differently. `H` never calls `f` and evaluates both branches eagerly. `iszero` differs from its comment but behaves the same way.

## VM16

VM16 is a small 16-bit register-and-stack virtual machine. The plan is to run an SECD machine or a combinator reducer on top of it on 8-bit CPUs.

- `vm16-spec.tex` is the specification. It is the source of truth for opcodes, encoding and semantics. Build with `latexmk -pdf vm16-spec.tex`.
- `vm16-z80.asm` is the Z80 interpreter. Assemble with `zasm -uwy vm16-z80.asm vm16-z80.lst vm16-z80.bin`. The code is placed at `0x0100`, and the dispatch table, register file and VM state share that first page. Z80 `BC` holds the VM PC and `IX` points at `next`. The host-specific I/O routines are the last section of the file.
- `vm16.c` is the portable C interpreter, used as the reference implementation. Build with `cc -O2 -Wall -Wextra -o vm16 vm16.c`. It uses computed goto under GCC/Clang. Add `-DVM16_NO_GOTO` for a standard-C `switch` instead, which must still compile cleanly with `-std=c11 -pedantic`. Run `./vm16 [-c] [-s] [-r LO-HI] [-d DUMP] IMAGE`. `-c` turns on checking mode (trap codes 2, 4, 5, 6), and `-d` writes the final state for the tests.
- `vm16asm.py` is the assembler for the syntax in spec appendix B. Run `python vm16asm.py prog.asm [-o prog.v16] [-l prog.lst]`. A program needs an `.org` and a `.stacks dsp, rsp` line. `fact8.asm` is a sample program that prints 8! with recursion and decimal output.
- `secd.asm` is the interpreted SECD machine from the tutorial, written in VM16 assembly.
  - It reads a λ-term from stdin and prints the result, then the transition and collection counts. Example: `python3 vm16asm.py secd.asm && ./vm16 secd.v16 < fac.lam`.
  - Input syntax: single-letter variables, `\x y.M`, signed 16-bit number constants (`-5`), `#` comments, plus two extensions:
    - Curried primitives `+ - * / % = <`. `=` and `<` return Church booleans, and a partial application prints as `(+ 3)`.
    - `if c t e`, which evaluates only the chosen branch. `if` is a keyword, so `i f` needs the space.
  - Integer support: the If rule rewrites `if c t e` to `c : SEL(t,e)` on C, and the Sel rule pops the condition and pushes one branch. A PRIM cell keeps its operator character in the tag's high byte, so compare only the low byte when testing for `T_PRIM`. The true and false results of `=`/`<` are static closures outside the heap. Types from `T_IF` up hold two pointers, which `gc_scan` relies on. `fac-int.lam` is the integer counterpart of `fac.lam`.
  - Heap objects are 3-word cells (tag, A, B). A Cheney copying collector runs only at the start of a transition, when all live data is reachable from the S, E, C and D globals. So code inside a rule may hold heap pointers in registers, but each transition must allocate no more than `RESERVE` cells.
  - Its transition counts must equal `secd23.c`'s (`fac 0..4` → 51, 151, 341, 626, 1026). That makes them a check whenever the rules change. Programs that use no integers or `if` must keep exactly the same output and counts, so compare against an image assembled from the previous commit.
- `vm16-test.py` contains a Python reference interpreter (`RefVM`) written from the spec. It runs every test program on both `RefVM` and an implementation, then compares registers, stack pointers, memory, output and the result.
  - C build: `python vm16-test.py --c ./vm16`.
  - Z80 build: `python vm16-test.py --z80 vm16-z80.bin vm16-z80.lst`. This needs the PyPI package `z80`.
  - When the spec changes, update `RefVM` and every implementation together.
