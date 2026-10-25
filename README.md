# VM16: a minimal portable 16-bit virtual machine

VM16 is a small register-and-stack virtual machine. It is meant to be implemented in a few hundred lines of assembly language on 8- and 16-bit processors such as the Z80, 6502 and 8086. It is still powerful enough to write a memory allocator, a garbage collector, hash tables, and interpreters for higher-level abstract machines such as Landin's SECD machine or a combinator graph reducer.

This repository holds the specification, two interpreters (portable C and Z80 assembly), an assembler, a test suite, and an SECD machine written in VM16 assembly. It also has a tutorial on the SECD machine itself.

The full specification is [`vm16-spec.pdf`](vm16-spec.pdf), built from [`vm16-spec.tex`](vm16-spec.tex). This README summarises it.

## Quick start

```sh
cc -O2 -Wall -Wextra -o vm16 vm16.c      # build the interpreter
python3 vm16asm.py fact8.asm             # assemble a sample program -> fact8.v16
./vm16 fact8.v16                         # prints: 8! = 40320

python3 vm16asm.py secd.asm              # the SECD machine, written in VM16 assembly
./vm16 secd.v16 < fac.lam                # prints 120: 5! with Church numerals
echo '(\a b.a) 4 3' | ./vm16 secd.v16    # prints 4
```

## Repository contents

| File | What it is |
|---|---|
| `vm16-spec.tex`, `.pdf` | The VM16 specification, version 0.1 |
| `vm16.c` | Portable C interpreter and reference implementation |
| `vm16-z80.asm` | Z80 interpreter: 918 bytes |
| `vm16asm.py` | Assembler for the syntax in appendix B of the spec |
| `vm16-test.py` | Differential tests: each implementation against a Python model of the spec |
| `fact8.asm` | Sample program: computes and prints 8! |
| `secd.asm`, `fac.lam` | The SECD machine in VM16 assembly, and a factorial program for it |
| `secd-tutorial.tex`, `.pdf` | A tutorial introduction to the SECD machine |
| `secd.c`, `secd23.c` | The original C SECD machine, and the fixed version used by the tutorial |

## Design principles

1. **Small to implement.** An interpreter should fit in 1–2 KB of native code on an 8-bit processor. Every instruction decodes simply.
2. **Identical on every host.** There is no flags register; conditional branches compare registers directly. Results never depend on the host's flags, word size or byte order.
3. **Untyped.** The machine knows words, bytes and addresses only. Heap allocation, garbage collection and data structures are libraries written in VM16 code.
4. **Precise roots.** Return addresses live on a separate return stack. A garbage collector can then scan the data stack without mistaking a return address for a pointer.
5. **Good for writing interpreters.** Indirect jumps and calls through registers support jump-table dispatch.
6. **An escape hatch.** `SYS` gives access to host services, and to native versions of performance-critical routines.

## The machine

- **Registers:** sixteen general-purpose 16-bit registers `r0`–`r15`. There are also three hidden registers: the program counter PC, the data stack pointer DSP and the return stack pointer RSP. The register file is not part of the address space.
- **Memory:** 64 KB, byte-addressed. VM addresses are host addresses. Words are 16-bit little-endian and need not be aligned, and addresses wrap: the word at `0xFFFF` takes its high byte from `0x0000`. The host reports the region the program may use with `SYS 2`.
- **Stacks:** a data stack and a return stack, both in memory, growing down, one word per item. The stack pointer holds the address of the last item pushed.
- **Arithmetic:** all arithmetic is modulo 2¹⁶.

### Instruction encoding

Each instruction is a one-byte opcode followed by 0–3 operand bytes, 1–4 bytes in total, never aligned. A register operand byte holds *twice* the register number (`r5` is `0x0A`). An interpreter can then use the byte directly as an offset into a register file of 2-byte entries. Branch offsets are signed bytes, relative to the next instruction.

### Instruction set

| Opcodes | Mnemonics | Meaning |
|---|---|---|
| `00`–`03` | `HALT`, `NOP`, `LI ra, imm16`, `MOV ra, rb` | halt with exit status `r0`; no operation; load immediate; move |
| `04`–`07` | `LW`, `SW`, `LB`, `SB` `ra, [rb+imm8]` | load/store word or byte, at base register plus an unsigned offset (0–255) |
| `08`–`09` | `LWA`, `SWA` `ra, imm16` | load/store word at an absolute address |
| `10`–`16` | `ADD`, `SUB`, `AND`, `OR`, `XOR`, `MUL`, `DIVU` `ra, rb` | `ra ← ra op rb`; `DIVU` also puts the remainder in `r15` |
| `18`–`1D` | `NOT`, `NEG`, `SHL`, `SHR`, `SAR` `ra`; `ADDI ra, simm8` | one-register operations, shifts by one; add a signed immediate |
| `20`–`25` | `BEQ`, `BNE`, `BLT`, `BGE`, `BLTU`, `BGEU` `ra, rb, rel8` | compare and branch, signed or unsigned |
| `26`–`29` | `BZ`, `BNZ` `ra, rel8`; `JMP imm16`; `JR ra` | branch if zero or not zero; jump; jump to the address in a register |
| `30`–`35` | `PUSH`, `POP`, `GETDSP`, `SETDSP`, `GETRSP`, `SETRSP` `ra` | data stack, and access to both stack pointers |
| `38`–`3A` | `CALL imm16`, `CALLR ra`, `RET` | subroutine call (to an address or through a register) and return |
| `3F` | `SYS imm8` | system call |

There are 43 instructions in all; every other opcode is reserved and traps. Some edge cases are pinned down: division by zero gives quotient `0xFFFF` and remainder equal to the dividend. If `DIVU`'s destination is `r15`, the quotient wins over the remainder.

### System calls

| Call | Effect |
|---|---|
| `SYS 0` (`PUTC`) | write the low byte of `r0` |
| `SYS 1` (`GETC`) | `r0` ← next input byte, or `0xFFFF` at end of input |
| `SYS 2` (`MEMINFO`) | `r0`, `r1` ← first and last usable address |
| `SYS 3` (`DEBUG`) | implementation-defined diagnostic |

Services 4–31 are reserved for future standard calls. Services 32–127 are left to each implementation, for example for native versions of library routines.

### Errors

Executing a reserved opcode, or calling an unassigned `SYS` service, must stop the machine with an error. Invalid register operands, memory access outside the usable region and stack overflow are undefined behaviour, so a fast interpreter can skip those checks. A *checking* implementation reports them with standard trap codes, 1–6.

### Program images

A program image is a 14-byte header followed by the body. The header holds the magic bytes `V16\0`, then five little-endian words: load address, body length, entry point, and the initial DSP and RSP.

## Assembly language

```asm
; print_u16: print r0 as an unsigned decimal number (from fact8.asm)
print_u16:
        LI      r1, 10
        LI      r2, 0                   ; number of digits
pu_div: DIVU    r0, r1                  ; r0 = r0 / 10, r15 = r0 mod 10
        PUSH    r15
        ADDI    r2, 1
        BNZ     r0, pu_div
pu_out: POP     r0
        ADDI    r0, '0'
        SYS     0
        ADDI    r2, -1
        BNZ     r2, pu_out
        RET
```

The assembler supports:
- labels, memory operands `[rb]` and `[rb+n]`;
- decimal and `0x` numbers, character literals such as `'\n'`, and expressions with `+ - * ( )`;
- the directives `.org`, `.equ`, `.byte`, `.word`, `.ascii`, `.space`, `.entry` and `.stacks dsp, rsp`.

`python3 vm16asm.py prog.asm -l prog.lst` also writes a listing with addresses and bytes.

The recommended calling convention passes arguments in `r0`–`r3` and returns the result in `r0`. Registers `r0`–`r7` and `r15` may be changed by a call; `r8`–`r14` must be preserved.

## Implementations

### C (`vm16.c`)

```
./vm16 [-c] [-s] [-r LO-HI] [-d DUMPFILE] IMAGE
```

| Option | Effect |
|---|---|
| `-c` | checking mode (traps on bad registers, memory and stack accesses) |
| `-s` | print the instruction count and speed |
| `-r` | set the usable region (default `0000-FFFF`) |
| `-d` | dump the final state, for the tests |

The exit status is `r0 & 255` after `HALT`, and `128 + code` after a trap.

- **Dispatch:** computed goto under GCC/Clang. `-DVM16_NO_GOTO` selects a standard C `switch` instead, which compiles cleanly with `-std=c11 -pedantic`.
- **Speed:** on an Apple M-series Mac it runs roughly a billion VM instructions per second.

### Z80 (`vm16-z80.asm`)

- **Size:** 918 bytes: 746 bytes of code, a 128-byte dispatch table, and 44 bytes for registers and state.
- **Design:** `BC` holds the VM program counter, `IX` points at the dispatch loop, and every handler ends in `jp (ix)`.
- **Speed:** about 250 T-states per VM instruction on average, roughly 16,000 VM instructions per second at 4 MHz.
- **Building:** assemble with [zasm](https://k1.spdns.de/zasm/): `zasm -uwy vm16-z80.asm vm16-z80.lst vm16-z80.bin`.
- **Porting:** the console I/O routines are a 16-byte host layer at the end of the file.

### Tests (`vm16-test.py`)

```sh
python3 vm16-test.py --c ./vm16
python3 vm16-test.py --z80 vm16-z80.bin vm16-z80.lst     # needs: pip install z80
```

Every test program runs both on the implementation and on a Python model written directly from the spec. All registers, both stack pointers, all usable memory, the output and the exit status or trap must match. The tests cover every instruction with random and edge-case operands, branches in both directions, unaligned memory, calls and stacks, system calls, reserved opcodes and image loading.

## The SECD machine on VM16

`secd.asm` is Landin's SECD machine, the interpreted version from the tutorial, written in about 2 KB of VM16 assembly. It reads a λ-term from standard input, evaluates it, and prints the result followed by the number of transitions and garbage collections:

```
$ echo '(\f x.f (f (f x))) + 0' | ./vm16 secd.v16
3
[20 transitions, 0 collections]
```

**Input syntax:**
- variables are single letters, and `\x y.M` means `\x.\y.M`;
- application associates to the left;
- numbers are constants, and `+` is the successor primitive, so `n + 0` turns a Church numeral `n` into a number;
- `#` starts a comment.

**Implementation:**
- Every heap object is a 3-word cell.
- A Cheney copying garbage collector runs between transitions, when all live data is reachable from the S, E, C and D registers.
- Its transition counts are identical to those of the C machine in `secd23.c` that the tutorial measures.
- The same image runs unchanged on the Z80 interpreter, where `fac.lam` takes about five minutes at 4 MHz.

## The SECD tutorial

[`secd-tutorial.pdf`](secd-tutorial.pdf) is an 18-page tutorial on the SECD machine for readers who know the basic λ-calculus. It covers:
- environments, closures and the dump;
- the transition rules, with step-by-step traces;
- what the machine computes;
- Church encodings and recursion under call-by-value;
- a C implementation and a pointer-sharing bug;
- compiling for the machine;
- related machines (CEK, Krivine, CAM).
