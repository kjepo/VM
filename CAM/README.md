# The Categorical Abstract Machine on VM16

`cam.asm` is the Categorical Abstract Machine (CAM) of Cousineau, Curien and Mauny (1985), written in VM16 assembly. One VM16 program does everything:
- reads a λ-term from standard input;
- compiles it to CAM code in memory;
- runs that code, with a copying garbage collector;
- prints the result, then the number of CAM instructions executed and of garbage collections.

```sh
./run fac.lam                            # 5040 (assembles cam.v16 if needed)
python3 lam2cam.py fac.lam               # the core term that cam.asm reads
python3 ../vm16asm.py cam.asm            # -> cam.v16
echo '(rec f.\n. if (= n 0) 1 (* n (f (- n 1)))) 7' | ../vm16 cam.v16
python3 camdis.py fac.lam                # the result, then the compiled CAM code
sh test.sh                               # 55 checks
```

| File | What it is |
|---|---|
| `cam.asm` | Reader, compiler, CAM interpreter and garbage collector |
| `lam2cam.py` | Translates a program with definitions (the syntax of `../graph`) into the core term `cam.asm` reads |
| `run` | Translates a program and runs it on `cam.v16` |
| `fac.lam`, `fib.lam` | 7! and fib(21), as definitions |
| `camdis.py` | Runs a program and disassembles the CAM code it compiled to |
| `test.sh` | Runs small programs and checks their results |
| `cam-tutorial.tex`, `.pdf` | A tutorial introduction to the CAM, needing no category theory |

## Programs with definitions

`run` and `camdis.py` take the syntax of `../graph`, with multi-letter names, definitions separated by `;`, and a final expression (or a definition of `main`):

```
fib n = if n < 2 then n else fib (n-1) + fib (n-2);
fib 21
```

`lam2cam.py` turns that into the core syntax below, which `cam.asm` compiles on VM16:
- The definitions the program uses are ordered so that each comes after those it uses, and bound around the final expression: `let f = F in M` is `(\f.M) F`.
- A definition that uses itself becomes `rec f.F`.
- A function used only once is put in place of its use. So `fac.lam` becomes `(rec a.\b.if (= b 0) 1 (* b (a (- b 1)))) 7`, the same program as before, with the same 171 instructions.
- Each variable is named after its binding depth (`a`, `b`, …), so no name hides another. `cam.asm` folds case, so at most 26 variables can be nested.

The CAM is strict, so some programs that run on the graph reducer cannot run here:
- definitions that call each other (`even`/`odd`) are rejected, because `REC` makes one recursive closure;
- a recursive value that is not a function (`ones = 1 : ones`) is rejected;
- a program that relies on laziness, such as `../graph/primes.lam` with its infinite list, or `../graph/church.lam` with `Y`, runs out of memory or stack.

## Input

The core syntax is the same as `../secd.asm`, plus `rec`:

```
(rec f.\n. if (= n 0) 1 (* n (f (- n 1)))) 7
```

- Variables are single letters, and `\x y.M` means `\x.\y.M`.
- Numbers are 15-bit signed integers (−16384 to 16383). Arithmetic wraps around.
- `+ - * / % = <` are curried primitives. `/` and `%` truncate towards zero. `=` and `<` return 1 or 0.
- `if c t e` evaluates only the branch it chooses; 0 is false. Compound parts need brackets.
- `rec f.\x.M` is a recursive function: inside `M`, `f` refers to the function itself.
- `if` and `rec` are keywords, so applying `i` to `f` needs a space: `i f`.
- `#` starts a comment.

## The machine

The CAM has three registers:
- **term**: the current environment, or the value just computed;
- **code**: the address of the next instruction;
- **stack**: in this implementation, the VM16 data stack.

**Values:**
- Numbers are tagged words `2n+1`, so they are odd and never allocated.
- `()`, the empty environment, is 0.
- Pairs and closures are heap cells.

An environment is a chain of pairs, `((((), vₙ) …), v₁)`. The variable with de Bruijn index i is found by i `fst` steps and then one `snd`. The compiler works out the indices, so no names are left at run time.

**Instructions:**

| Instruction | Effect |
|---|---|
| `ACC i` | term ← fstⁱ; snd of term (variable i) |
| `PUSH` | push term |
| `SWAP` | exchange term and the top of the stack |
| `CONS` | term ← (pop, term) |
| `CUR end` | term ← closure [following code : term]; continue at `end` |
| `APP` | term = ([C : s], t): term ← (s, t), push the return address, continue at C |
| `RET` | continue at the popped return address |
| `QUOTE n` | term ← n |
| `BRANCH else` | pop the saved environment into term; go to `else` if the old term was 0 |
| `JUMP addr` | continue at `addr` |
| `REC end` | term ← k, a closure [following code : (term, k)] that contains itself |
| `ADD SUB MUL DIV MOD EQ LT` | term ← pop *op* term |
| `STOP` | print term and halt |

`ACC i` abbreviates the original CAM's `Fst`…`Fst; Snd`.

**Compilation:**

```
⟦x⟧             = ACC i                                   (i = position of x)
⟦n⟧             = QUOTE n
⟦\x.M⟧          = CUR end; ⟦M⟧; RET; end:
⟦M N⟧           = PUSH; ⟦M⟧; SWAP; ⟦N⟧; CONS; APP
⟦op M N⟧        = PUSH; ⟦M⟧; SWAP; ⟦N⟧; op                (CONS fused into op)
⟦op⟧            = ⟦\a b.op a b⟧
⟦if c t e⟧      = PUSH; ⟦c⟧; BRANCH else; ⟦t⟧; JUMP end; else: ⟦e⟧; end:
⟦rec f.\x.M⟧    = REC end; ⟦M⟧; RET; end:
```

There are two departures from the original CAM:
- **Fused operators.** The original applies an operator to a pair, so it needs `CONS` and then the operator. Here the operator takes its left operand straight from the stack, which saves a cell per operation.
- **`rec` as an instruction.** Recursion isn't in the categorical combinators. The `REC` instruction builds a cyclic closure, as Caml's `let rec` does.

This is `fac.lam` compiled, as `camdis.py` prints it. The body of `REC` is indented:

```
3000  PUSH
3001  REC 302A                  f = rec f.\n. ...
3004    PUSH                    if ...
3005    PUSH                      = n 0
3006    ACC 0
3008    SWAP
3009    QUOTE 0
300C    EQ
300D    BRANCH 3016
3010    QUOTE 1                 then 1
3013    JUMP 3029
3016    PUSH                    else * n (f (- n 1))
3017    ACC 0                     n
3019    SWAP
301A    PUSH                      f (- n 1)
301B    ACC 1                       f
301D    SWAP
301E    PUSH                        - n 1
301F    ACC 0
3021    SWAP
3022    QUOTE 1
3025    SUB
3026    CONS
3027    APP
3028    MUL
3029    RET
302A  SWAP                      apply it to 7
302B  QUOTE 7
302E  CONS
302F  APP
3030  STOP
```

## Garbage collection

The collector is Cheney's copying collector over two 16 KB semispaces. Its roots are the term and the stack. Before allocating, an instruction makes sure there is room for two cells, so a collection never happens partway through an instruction.

Return addresses on the stack, and code addresses in closures, point outside the heap, and numbers are odd. The collector can therefore tell them apart from heap pointers without any extra tags.

The stack grows down towards the heap. Only a recursion can make it grow without bound, and every recursion goes through `APP`, so `APP` checks the depth and stops the program with "out of stack" before the stack reaches the heap. A recursion such as `+ 1 (f (- n 1))` can nest about 1,900 calls deep.

## Compared with the SECD machine

These are the same programs on `../secd.asm` (interpreted SECD, using `Z` for recursion) and on the CAM.

| Program | Machine | Steps | Collections | VM16 instructions | Z80 at 4 MHz |
|---|---|---|---|---|---|
| 7!, integers | SECD (`../fac-int.lam`) | 322 transitions | 0 | 29,738 | 2.2 s |
| | CAM, same program | 346 instructions | 0 | 17,595 | 1.2 s |
| | CAM with `rec` (`fac.lam`) | 171 instructions | 0 | 10,131 | 0.7 s |
| 5!, Church numerals | SECD (`../fac.lam`) | 52,044 transitions | 49 | 4,086,035 | about 5 min |
| | CAM, same program | 73,681 instructions | 10 | 1,505,151 | 102 s |

The VM16 counts include reading and compiling the program.

**Why the CAM is faster:**
- **Variable lookup.** A CAM variable is a fixed path of `fst` steps worked out at compile time. The SECD machine compares names along the environment list.
- **Fewer and smaller cells.** An SECD application builds three CONS cells for the control list and a three-cell dump frame. A CAM application allocates one pair, and its return address is a single word on the stack.
- **Unboxed numbers.** CAM numbers are tagged words. The SECD machine allocates an `INT` cell for every result.

**The cost:**
- **Code size.** `cam.v16` is 3,117 bytes, against 2,763 for `secd.v16`, because it contains a compiler.
- **Number range.** Numbers have 15 bits instead of 16.

The Z80 interpreter, `../vm16-z80.asm`, and the C interpreter produce identical final memory for these runs.
