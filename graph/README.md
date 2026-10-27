# Combinator graph reduction on VM16

Combinator graph reduction in the style of Turner's SASL and Miranda implementations (1979), in two parts:
- **`lam2graph.py`**, in Python, reads a λ-term and removes every λ by bracket abstraction, using Turner's combinators S K I B C S′ B* C′. It writes the resulting graph to a `.graph` file.
- **`graph.asm`**, in VM16 assembly, reads the graph, reduces it lazily, updating it in place, with a copying garbage collector. It prints the result, then the number of reductions and of garbage collections.

```sh
./run fac.lam                               # compile and run: 5040
python3 lam2graph.py fac.lam                # -> fac.graph
python3 ../vm16asm.py graph.asm             # -> graph.v16 (run does this when needed)
../vm16 graph.v16 < fac.graph               # 5040
python3 lam2graph.py -t fac.lam             # the compiled term, with brackets
python3 prototype.py fac.graph              # reduce the graph in Python
python3 prototype.py --trace fac.lam        # the graph after every reduction
sh test.sh                                  # 68 checks, against both
```

The plan is to write the compiler in the language itself later, compile it with `lam2graph.py`, and run it on `graph.v16`.

| File | What it is |
|---|---|
| `run` | Compiles a `.lam` program with `lam2graph.py` and runs it on `graph.v16` |
| `lam2graph.py` | The compiler: λ-term to a `.graph` file |
| `graph.asm` | Loader, reducer and garbage collector |
| `prototype.py` | The compiler and the same reducer in Python. It makes the same rewrites in the same order, so its reduction counts must equal `graph.asm`'s. It runs a `.lam` or a `.graph` file |
| `fac.lam` | 7! with `rec` |
| `fib.lam` | fib(20), the same program as `../CAM/fib.lam` |
| `church.lam` | 5! with Church numerals, booleans and Y, as in a textbook: no thunks |
| `primes.lam` | The 100th prime, taken from an infinite list of primes |
| `test.sh` | Runs small programs on `graph.v16` and `prototype.py` and compares the results and counts |
| `graph-tutorial.tex`, `.pdf` | A tutorial introduction to combinator graph reduction, in the style of the SECD and CAM tutorials |

## Input

`lam2graph.py` reads the same syntax as `../CAM/cam.asm`:

```
(rec f.\n. if (= n 0) 1 (* n (f (- n 1)))) 7
```

- Variables are single letters, and `\x y.M` means `\x.\y.M`.
- Numbers are 15-bit signed integers (−16384 to 16383). Arithmetic wraps around.
- `+ - * / % = <` are curried primitives. `/` and `%` truncate towards zero. `=` and `<` return 1 or 0.
- `if c t e` chooses by the number `c`; 0 is false.
- `rec f.M` is `M`, where `f` refers to `M` itself. Unlike the CAM, `M` needs not be a function: `rec l.\c n.c 1 l` is an infinite list of ones.
- `if` and `rec` are keywords, so applying `i` to `f` needs a space: `i f`.
- `#` starts a comment.

## Compiling: bracket abstraction

`[x] e` is a term without `x` that, applied to `x`, gives `e`. The compiler compiles the body of each λ first, then abstracts its variable:

```
[x] x       = I
[x] e       = K e                    (e any other variable, number or combinator)
[x] (e f)   = S ([x] e) ([x] f)
```

Plain S/K/I code grows quickly. Turner's rules shrink it as each `S` is built:

```
S (K p) (K q)   = K (p q)            S (B p q) (K r)  = C' p q r
S (K p) I       = p                  S p (K q)        = C p q
S (K p) (B q r) = B* p q r           S (B p q) r      = S' p q r
S (K p) q       = B p q
```

`if c t e` becomes `IF c t e`, and `rec f.M` becomes `Y (\f.M)`. This is `fac.lam` compiled:

```
Y (B* (S (C' IF (C = 0) 1)) (S *) (C B (C - 1))) 7
```

The term has 16 application cells. Reading it as a function of `f` and then `n`:
- `C = 0` is `\n. = n 0`;
- `C - 1` is `\n. - n 1`;
- `C B (C - 1)` is `\f n. f (- n 1)`;
- the rest assembles `if (= n 0) 1 (* n (f (- n 1)))`.

| Program | S, K, I only | Turner |
|---|---|---|
| `fac.lam` reductions | 216 | 90 |
| `fib.lam` reductions | 547,279 | 240,800 |
| `primes.lam` reductions | 2,047,673 | 155,171 |

(`python3 prototype.py --ski` compiles with S, K and I only.)

## The graph format

A `.graph` file holds the compiled term in postfix. A combinator (`I K S B C S' B* C' Y IF + - * / % = <`) or a number is a token, and `f a @` is `f` applied to `a`; `#` starts a comment. This is `fac.graph`:

```
# fac.lam
Y B* S C' IF @ C = @ 0 @ @ 1 @ @ @ S * @ @ C B @ C - @ 1 @ @ @ @ 7 @
```

`graph.asm` loads it with the data stack: each token pushes a word, and `@` pops two and pushes a new cell. Exactly one word, the root, must be left at the end.

## The graph in memory

Every heap cell is an application node of two words, `(fun, arg)`, with no tag. Every other value fits in one word:
- **numbers** are odd words `2n+1`;
- **combinators** are small even codes;
- a word is **a cell** exactly when it is even and at least `HEAP_LO`.

Cells are two words instead of the CAM's three, and the garbage collector needs no type information.

## Reducing

`whnf` follows the function parts from the root down to the head, pushing each cell on the VM16 data stack. These cells form the *spine*. If the head is a combinator and the spine holds all its arguments, the redex is rewritten, and the reducer continues from its root:

```
I x        = x                      Y f         = f (Y f)
K x y      = x                      S' k f g x  = k (f x) (g x)
S f g x    = f x (g x)              B* k f g x  = k (f (g x))
B f g x    = f (g x)                C' k f g x  = k (f x) g
C f g x    = f x g                  IF c t e    = t, or e if c is 0
+ a b      = the sum, after reducing a and b (likewise - * / % = <)
```

- **Rewriting in place.** The root cell of the redex is overwritten with the result. Every other reference to that expression sees the result, so nothing is evaluated twice. This is lazy evaluation, call-by-need.
- **Indirections.** A result that is not an application, such as the `x` of `K x y`, is stored as `I x`. The reducer then makes the parent cell point straight at `x`.
- **Y needs no unrolling.** `Y f` turns its own cell into `f` applied to itself, a cycle, so recursion costs nothing per call.
- **Strict operators.** `IF` and the operators need the values of their arguments, so they call `whnf` recursively.

### What laziness buys

- **No thunks for conditionals.** `church.lam` is factorial written as in a textbook, with Church booleans and Y. Both the SECD machine and the CAM evaluate both branches, so the recursion never stops. `../fac.lam` has to use Z and wrap each branch in `\d.`. Here the program works as written.
- **Unused arguments are never evaluated.** `(\x y.y) (/ 1 0) 5` gives 5.
- **Infinite data.** `primes.lam` keeps an infinite list of numbers and an infinite list of primes, and computes only as much of them as `nth` looks at.

### What it costs

- **Thunks build up.** A lazy accumulator such as `f (- n 1) (+ a 1)` builds a chain of 3,000 unevaluated additions, and evaluating it at the end runs out of stack. The test suite has an example. Comparing `a` with something on each round forces it and runs in constant space.
- **Many small steps.** Each variable is routed to where it is needed by `B` and `C` steps, and a value passes through `I`. In fib(20), `C` and `I` are 36% of the reductions, and `+` only 5%.

## Garbage collection

The collector is Cheney's, over two 18 KB semispaces. The data stack holds every live pointer, so it is the only root:
- **Spine cells.** The current cells of the spine are on it.
- **Room before reading.** An allocating rule makes sure there is room for three cells before it reads its arguments, so no pointer is ever held only in a register when a collection happens.
- **Words that are not pointers.** The other words on the stack are numbers, saved spine bases and handler addresses. None of them points into the heap, and the collector leaves them alone.

## Compared with the SECD machine and the CAM

The same programs on `../secd.asm`, `../CAM/cam.asm` and `graph.asm`, in VM16 instructions. The count is split in two, because the machines do different amounts of work before their first step:
- **setup:** the SECD machine and the CAM read the source text and compile it on VM16. The graph reducer only loads a graph that `lam2graph.py` compiled in Python.
- **run:** everything after that, including printing the result. This is the fair comparison.

| Program | Machine | Steps | Collections | Setup | Run |
|---|---|---|---|---|---|
| 7!, `rec` (`fac.lam`) | CAM | 171 instructions | 0 | 6,998 | 3,133 |
| | graph | 90 reductions | 0 | 2,438 | 6,679 |
| 7!, `Z` (`../fac-int.lam`) | SECD | 322 transitions | 0 | 8,791 | 20,947 |
| | CAM | 346 instructions | 0 | 11,040 | 6,555 |
| | graph | 151 reductions | 0 | 3,838 | 9,865 |
| fib(20) (`fib.lam`) | SECD, with `Z` | 45,423 transitions | 702 | 4,297 | 61,157,464 |
| | CAM | 448,762 instructions | 16 | 5,732 | 7,029,349 |
| | graph | 240,800 reductions | 45 | 3,207 | 16,795,429 |
| | VM16 assembly | | | | 175,169 |
| 5!, Church (`../fac.lam`) | SECD | 52,044 transitions | 49 | 20,175 | 4,065,860 |
| | CAM | 73,681 instructions | 10 | 28,259 | 1,476,892 |
| | graph | 16,987 reductions | 2 | 13,742 | 913,953 |
| 5!, Church, no thunks (`church.lam`) | graph only | 16,957 reductions | 2 | 12,741 | 912,201 |
| 100th prime (`primes.lam`) | graph only | 155,171 reductions | 43 | 14,327 | 10,709,760 |

Setup ends where each machine's main loop is first entered (`run` in `secd.asm`, `next` in `cam.asm`, `whnf` in `graph.asm`).

**Strict, first-order programs.** On `fac` and fib(20), the graph reducer runs 1.5–2.4 times slower than the CAM.
- It takes fewer steps, but each costs about 70 VM16 instructions, against about 15 for a CAM instruction.
- About 25 of those 70 go to unwinding the spine (2.5 cells per reduction in fib, at 9 instructions each), and 13 to checking the arity and dispatching.

**Higher-order programs.** On Church numerals it is the fastest of the three: 1.6 times faster than the CAM and 4.4 times faster than the SECD machine.
- Sharing means a numeral that is used several times is built only once.
- The CAM and the SECD machine build closures and environments for every application. A combinator rule only rearranges its arguments.

**On a Z80.** The Z80 VM16 interpreter and the C one give identical final memory for the graphs of `fac.lam`, `../fac.lam` and smaller tests.
- On a 4 MHz Z80, `fac.lam` takes 0.67 s and `../fac.lam` 69 s.
- fib(20) would take about 20 minutes, estimated from 288 Z80 cycles per VM16 instruction.

**Size.** `graph.v16` is 2,255 bytes. The reducer, its rules and the arithmetic take about 940 bytes of that. The rest is the loader, the garbage collector, printing and messages. The reader and compiler that were in VM16 before took about 1,000 bytes.

## Where to go from here

- **Faster reduction.** The reducer re-unwinds from the root after every rewrite, and checks for stack overflow on every push. Keeping the spine across rewrites and checking the stack once per reduction would remove much of the 70-instruction cost.
- **Better abstraction.** Kiselyov's 2018 algorithm, or more combinators, would shrink the code. Supercombinators (Hughes 1982), compiled to G-machine code, are the step after that, toward how lazy functional languages were implemented in the 1980s.
- **Lazy output.** A program whose result is an infinite list of characters, printed as it is computed. This is how Turner's languages did I/O.
