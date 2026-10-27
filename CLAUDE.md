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
- `vm16asm.py` is the assembler for the syntax in spec appendix B. Run `python vm16asm.py prog.asm [-o prog.v16] [-l prog.lst]`. A program needs an `.org` and a `.stacks dsp, rsp` line. `.include "file"` inserts another source file (path relative to the including file); errors name the file and line. `fact8.asm` is a sample program that prints 8! with recursion and decimal output.
- `secd.asm` is the interpreted SECD machine from the tutorial, written in VM16 assembly.
  - It reads a λ-term from stdin and prints the result, then the transition and collection counts. Example: `python3 vm16asm.py secd.asm && ./vm16 secd.v16 < fac.lam`.
  - Input syntax: single-letter variables, `\x y.M`, signed 16-bit number constants (`-5`), `#` comments, plus two extensions:
    - Curried primitives `+ - * / % = <`. `=` and `<` return Church booleans, and a partial application prints as `(+ 3)`.
    - `if c t e`, which evaluates only the chosen branch. `if` is a keyword, so `i f` needs the space.
  - Integer support: the If rule rewrites `if c t e` to `c : SEL(t,e)` on C, and the Sel rule pops the condition and pushes one branch. A PRIM cell keeps its operator character in the tag's high byte, so compare only the low byte when testing for `T_PRIM`. The true and false results of `=`/`<` are static closures outside the heap. Types from `T_IF` up hold two pointers, which `gc_scan` relies on. `fac-int.lam` is the integer counterpart of `fac.lam`.
  - Heap objects are 3-word cells (tag, A, B). A Cheney copying collector runs only at the start of a transition, when all live data is reachable from the S, E, C and D globals. So code inside a rule may hold heap pointers in registers, but each transition must allocate no more than `RESERVE` cells.
  - Its transition counts must equal `secd23.c`'s (`fac 0..4` → 51, 151, 341, 626, 1026). That makes them a check whenever the rules change. Programs that use no integers or `if` must keep exactly the same output and counts, so compare against an image assembled from the previous commit.
- `CAM/cam.asm` is the Categorical Abstract Machine in VM16 assembly. One program reads the same syntax as `secd.asm`, plus `rec f.\x.M`, compiles it to CAM bytecode at `CODE` (0x3000), and runs it. `CAM/README.md` documents the instruction set and the compilation scheme, and `CAM/cam-tutorial.tex` is a tutorial in the style of `secd-tutorial.tex` (build with `latexmk -pdf`). Its traces and measurements were taken from `cam.v16`, so rerun them if the compiler or the instruction set changes.
  - Commands: `sh CAM/test.sh` runs the checks, and `python3 CAM/camdis.py prog.lam` shows the compiled code. `camdis.py` reads `CODE` and the opcode numbers from `cam.asm`, but its `NAMES` table must follow the `OP_*` order.
  - Numbers are tagged odd words (`2n+1`, 15 bits). The collector tells pointers from numbers and code addresses by parity and range alone.
  - Allocating instructions call `reserve` (two cells) before popping anything, so a collection only ever sees the term and the stack as roots.
  - The CAM stack grows down towards the heap. `APP` compares the data stack pointer with `r13` (`STACK_LIMIT`) and fails with "out of stack", because every unbounded recursion passes through `APP`.
  - The image must load at or above 0x2000, or the Z80 build rejects it.
- `graph/` is a lazy combinator graph reducer, in two parts. `graph/lam2graph.py` (Python) reads the syntax of `CAM/cam.asm` (`rec f.M` may have any `M`) extended with multi-letter names and `;`-separated definitions `f x y = M` followed by an expression or a `main` definition. It also accepts infix operators (`n * fac (n-1)`, `==`), with an operator at the start of an application still the curried primitive and `-5` a number unless it follows an operand; and `if c then a else b` beside `if c t e`: the reader looks ahead for `then` at the same bracket depth (before `;`, an unmatched `)` or another `if`) to choose the form. Each definition is compiled separately and linked by pointer (Turner's way), not abstracted, and only definitions reachable from the program are emitted. It compiles with Turner's bracket abstraction (S K I B C S' B* C', plus Y and IF), and writes a `.graph` file. `graph/graph.asm` (VM16) loads the graph and reduces it in place, with the spine on the data stack. The plan is to rewrite the compiler later as a `.lam` program run on `graph.v16`. `graph/README.md` explains the design and the measurements, and `graph/graph-tutorial.tex` is a tutorial in the style of the CAM one (build with `latexmk -pdf`). Its traces come from `prototype.py --trace` and its measurements from `graph.v16`, so rerun them if the compiler or the rules change. The comparison tables split VM16 instructions into setup (up to the first entry of `run` in `secd.asm`, `next` in `cam.asm`, `whnf` in `graph.asm`) and run, because only the SECD machine and the CAM compile on VM16.
  - `graph/morc.py` reads MORC (Mora Recursive Calculator), a second syntax for the same language: `fn name params = expr;` definitions with value `main`, infix operators with the usual precedences, `if … then … else`, `\x -> e`, `true`/`false` (1/0) and Scott-encoded lists `h : t`/`nil` (built-in definitions named `:` and `nil`, emitted only when used). It produces the same syntax tree as the `.lam` reader, so nothing after the reader changes. `.morc` files, or `--morc`, select it in `lam2graph.py` and `prototype.py`. `graph/morc.tex` is a paper on the language and its translation (build with `latexmk -pdf`); its listings, traces and numbers come from the tools, so rerun them if the compiler changes.
  - Commands: `graph/run prog.lam` (or `prog.morc`) compiles and runs a program, `sh graph/test.sh` runs the checks, `python3 graph/lam2graph.py -t prog.lam` prints the compiled term, and `python3 graph/prototype.py [-c] [--ski] [--trace] prog.lam|prog.graph` runs the Python model.
  - The `.graph` format is postfix text: combinator names (as in `names`) and numbers are tokens, `f a @` is an application, and `#` starts a comment. The loader pushes each token on the data stack, and exactly one word must be left at the end. Definitions add `%n` (first: allocate n cells at `HEAP1`, `HEAP1+4`, ...), `$k` (push definition k's cell) and `=k` (pop a cell and copy its two words into definition k's cell, so references need no indirection).
  - `lam2graph.py` imports the reader and the compiler from `prototype.py`, so there is one compiler. `prototype.py` reduces with the same rewrites in the same order as `graph.asm`, and `test.sh` requires the same result and reduction count from both, on the same `.graph` text. Change them together, including `read_graph`'s error messages, which must match the loader's.
  - `graph/lib.asm` holds what is not graph reduction: `fail`/`syntax_error`/`stack_full`, `heap_init`/`cons`/`collect`/`gc` (Cheney over two-word cells whose first word is never 0, with the data stack as the only root), `nextc`/`skipws`/`is_digit`/`is_end`/`read_u16` (input through `LOOK`), and `print_s16`/`print_u16`/`print_u32`/`print_str`. `graph.asm` includes it after its own code and defines `HEAP1`, `HEAP2`, `SEMI`, `RESERVE` and `STACK_TOP`; `r10` is the heap pointer and `r11` the semispace end minus `RESERVE` throughout. Moving code can change instruction counts slightly, because `forward` rejects odd words (including odd code addresses on the stack) faster than even ones.
  - Cells are two words `(fun, arg)` with no tag. Numbers are odd, combinators are small even codes (used directly as offsets into `rules`, `arity2` and `names`), and a cell is an even word ≥ `HEAP_LO`.
  - The data stack is the collector's only root. A rule that allocates checks `r11` (the end of the semispace minus three cells) before it reads its arguments, and IF and the operators reload the spine after each nested `whnf`. The loader never collects.
- `vm16-test.py` contains a Python reference interpreter (`RefVM`) written from the spec. It runs every test program on both `RefVM` and an implementation, then compares registers, stack pointers, memory, output and the result.
  - C build: `python vm16-test.py --c ./vm16`.
  - Z80 build: `python vm16-test.py --z80 vm16-z80.bin vm16-z80.lst`. This needs the PyPI package `z80`.
  - When the spec changes, update `RefVM` and every implementation together.
