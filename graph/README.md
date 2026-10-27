# Combinator graph reduction on VM16

Combinator graph reduction in the style of Turner's SASL and Miranda implementations (1979), in two parts:
- **`lam2graph.py`**, in Python, reads a λ-term and removes every λ by bracket abstraction, using Turner's combinators S K I B C S′ B* C′. It writes the resulting graph to a `.graph` file.
- **`graph.asm`**, in VM16 assembly, reads the graph, reduces it lazily, updating it in place, with a copying garbage collector. It prints the result, then the number of reductions and of garbage collections.

```sh
./run fac.lam                               # compile and run: 5040
./run fac.morc                              # the same program in MORC
python3 lam2graph.py fac.lam                # -> fac.graph
python3 ../vm16asm.py graph.asm             # -> graph.v16 (run does this when needed)
../vm16 graph.v16 < fac.graph               # 5040
python3 lam2graph.py -t fac.lam             # the compiled term, with brackets
python3 prototype.py fac.graph              # reduce the graph in Python
python3 prototype.py --trace fac.lam        # the graph after every reduction
sh test.sh                                  # 162 checks, against both
```

The plan is to write the compiler in the language itself later, compile it with `lam2graph.py`, and run it on `graph.v16`.

| File | What it is |
|---|---|
| `run` | Compiles a `.lam` program with `lam2graph.py` and runs it on `graph.v16` |
| `lam2graph.py` | The compiler: a `.lam` or `.morc` program to a `.graph` file |
| `morc.py` | The reader for MORC, a syntax with infix operators, `if … then … else` and lists |
| `morc.tex`, `.pdf` | A paper on MORC: its grammar, and how a program is translated to a graph and run |
| `graph.asm` | Loader and reducer. It includes `lib.asm` |
| `lib.asm` | The parts that are not about graph reduction: the garbage collector for two-word cells, character input, printing and error messages |
| `prototype.py` | The compiler and the same reducer in Python. It makes the same rewrites in the same order, so its reduction counts must equal `graph.asm`'s. It runs a `.lam` or a `.graph` file |
| `fac.lam` | 7!, with `fac` calling itself by name |
| `fib.lam` | fib(20), the same function as `../CAM/fib.lam`, calling itself by name |
| `church.lam` | 5! with Church numerals, booleans and Y, as in a textbook: no thunks. Written as definitions |
| `primes.lam` | The 100th prime, taken from an infinite list of primes. Written as definitions |
| `fac.morc`, `fib.morc`, `primes.morc` | The same programs in MORC |
| `test.sh` | Runs small programs on `graph.v16` and `prototype.py` and compares the results and counts |
| `graph-tutorial.tex`, `.pdf` | A tutorial introduction to combinator graph reduction, in the style of the SECD and CAM tutorials |

## Input

`lam2graph.py` reads the syntax of `../CAM/cam.asm`, extended with longer names and definitions:

```
(rec f.\n. if (= n 0) 1 (* n (f (- n 1)))) 7
```

or

```
iszero n = = n 0;
fac n = if (iszero n) 1 (* n (fac (- n 1)));
fac 7
```

- A program is a series of definitions, each ended by `;`, followed by the expression to evaluate. Without that expression, the program evaluates `main`.
- A definition `f x y = M` means `f = \x y.M`. Definitions may refer to each other in any order, and to themselves, so recursion needs no `rec`.
- At the start of an item, `name name ... =` begins a definition; write `(=)` to pass `=` as an argument there.
- Names are a letter followed by letters, digits and `_`. `\x y.M` means `\x.\y.M`, and `\xy.M` has one parameter, `xy`.
- Numbers are 15-bit signed integers (−16384 to 16383). Arithmetic wraps around.
- `+ - * / % = <` are curried primitives. `/` and `%` truncate towards zero. `=` and `<` return 1 or 0.
- Operators can also be written infix, with the usual precedences: application binds tightest, then `* / %`, then `+ -`, then the comparisons `== != < <= > >=` (and `=`, the same as `==`), which do not chain. So `if n == 0 then 1 else n * fac (n-1)` works.
- An operator at the start of an application is the curried primitive, as before: `* n (f (- n 1))`, `(+ 1)`. To pass an operator as an argument, put it in brackets: `foldr (+) 0`.
- `-5` is a negative number unless it follows an operand, where `-` is subtraction: `n-1` is `n - 1`, and `f (-1)` passes -1.
- `if c t e`, or `if c then t else e`, chooses by the number `c`; 0 is false. In the second form the condition and the `then` branch may be applications without brackets (`if = n 0 then 1 else * n (f (- n 1))`), and the `else` branch extends as far right as it can.
- `rec f.M` is `M`, where `f` refers to `M` itself. Unlike the CAM, `M` needs not be a function: `rec l.\c n.c 1 l` is an infinite list of ones.
- `if`, `then`, `else` and `rec` are keywords.
- `#` starts a comment.

## MORC

MORC, the Mora Recursive Calculator, is a second syntax for the same language, with `fn` before each definition, `\x -> e` for lambdas, and lists. `lam2graph.py` reads it from a `.morc` file, or with `--morc`:

```
fn fac n = if n = 0 then 1 else n * fac (n - 1);
fn main = fac 7;
```

- A program is a series of definitions, `fn name params = expr;`, and its value is `main`.
- Application binds tightest, then `* / %`, then `+ -`, then `:` (right-associative), then the comparisons `= != < <= > >=`, which do not chain. `==` is the same as `=`. `\x y -> e` and `if c then a else b` extend as far right as possible, so `1 + if c then 2 else 3` needs no brackets.
- `-x` is negation. `(+)`, `(<)`, `(:)` and so on are the operators as functions.
- `true` and `false` are 1 and 0, which is what the comparisons return and `if` tests.
- `h : t` and `nil` are lists, Scott-encoded as in `primes.lam`: `h : t = \c n. c h t` and `nil = \c n. n`. A list is taken apart by applying it to a function of its head and tail and to a default: `l (\h t -> ...) 0`.
- Names are a letter followed by letters, digits and `_`; `fn if then else true false nil` are keywords. `#` starts a comment.

A MORC program compiles to the same terms as its `.lam` version: `fac.morc` and `fib.morc` take exactly as many reductions as `fac.lam` and `fib.lam`. `primes.morc` takes 177,761 instead of 154,682, because its test `x % h != 0` does one more subtraction than `primes.lam`'s `% x h`.

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

`if c t e` becomes `IF c t e`, and `rec f.M` becomes `Y (\f.M)`. This is `(rec f.\n. if (= n 0) 1 (* n (f (- n 1)))) 7` compiled:

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
| `fac.lam` reductions | 192 | 87 |
| `fib.lam` reductions | 503,481 | 240,795 |
| `church.lam` reductions | 47,445 | 16,918 |
| `primes.lam` reductions | 2,016,222 | 154,682 |

(`python3 prototype.py --ski` compiles with S, K and I only.)

### Definitions

Each definition is compiled on its own, with the names of other definitions left as leaves, and each name then becomes a pointer to its definition's cell. A recursive definition is a cycle, as `Y` makes, and bracket abstraction never has to route a definition's name to where it is used. This is how Turner's SASL and Miranda linked a script of definitions. `python3 lam2graph.py -t` prints one line per definition:

```
fac = S (C' IF iszero 1) (S * (B fac (C - 1)))
iszero = C = 0
fac 7
```

Only the definitions the program can reach are written. Written with definitions instead of one big λ-term, `church.lam` takes 52 cells instead of 98 and `primes.lam` 65 instead of 107, plus one cell per definition.

## The graph format

A `.graph` file holds the compiled term in postfix. A combinator (`I K S B C S' B* C' Y IF + - * / % = <`) or a number is a token, and `f a @` is `f` applied to `a`; `#` starts a comment. This is the `rec` factorial above:

```
Y B* S C' IF @ C = @ 0 @ @ 1 @ @ @ S * @ @ C B @ C - @ 1 @ @ @ @ 7 @
```

`graph.asm` loads it with the data stack: each token pushes a word, and `@` pops two and pushes a new cell. Exactly one word, the root, must be left at the end.

A program with definitions uses three more tokens:
- `%n`, first, makes n cells for the definitions;
- `$k` pushes the cell of definition k;
- `=k` pops a cell and copies its two words into the cell of definition k. Every `$k`, before or after, then points at the definition itself, not at an indirection.

```
%2
# fac
S C' IF @ $1 @ 1 @ @ S * @ B $0 @ C - @ 1 @ @ @ @ =0
# iszero
C = @ 0 @ =1
# the program
$0 7 @
```

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

The collector is Cheney's, over two 18 KB semispaces. It is in `lib.asm`, which works for any heap of two-word cells whose first word is never 0. The data stack holds every live pointer, so it is the only root:
- **Spine cells.** The current cells of the spine are on it.
- **Room before reading.** An allocating rule makes sure there is room for three cells before it reads its arguments, so no pointer is ever held only in a register when a collection happens.
- **Words that are not pointers.** The other words on the stack are numbers, saved spine bases and handler addresses. None of them points into the heap, and the collector leaves them alone.

## Compared with the SECD machine and the CAM

The same programs on `../secd.asm`, `../CAM/cam.asm` and `graph.asm`, in VM16 instructions. The count is split in two, because the machines do different amounts of work before their first step:
- **setup:** the SECD machine and the CAM read the source text and compile it on VM16. The graph reducer only loads a graph that `lam2graph.py` compiled in Python.
- **run:** everything after that, including printing the result. This is the fair comparison.

| Program | Machine | Steps | Collections | Setup | Run |
|---|---|---|---|---|---|
| 7! (`fac.lam`) | CAM, `rec` | 171 instructions | 0 | 6,998 | 3,133 |
| | graph, by name | 87 reductions | 0 | 2,725 | 6,509 |
| 7!, `Z` (`../fac-int.lam`) | SECD | 322 transitions | 0 | 8,791 | 20,947 |
| | CAM | 346 instructions | 0 | 11,040 | 6,555 |
| | graph | 151 reductions | 0 | 4,010 | 9,865 |
| fib(20) (`fib.lam`) | SECD, with `Z` | 45,423 transitions | 702 | 4,297 | 61,157,464 |
| | CAM | 448,762 instructions | 16 | 5,732 | 7,029,349 |
| | graph, by name | 240,795 reductions | 45 | 3,420 | 16,796,731 |
| | VM16 assembly | | | | 175,169 |
| 5!, Church (`../fac.lam`) | SECD | 52,044 transitions | 49 | 20,175 | 4,065,860 |
| | CAM | 73,681 instructions | 10 | 28,259 | 1,476,892 |
| | graph | 16,987 reductions | 2 | 14,384 | 914,239 |
| 5!, Church, no thunks (`church.lam`) | graph only | 16,918 reductions | 2 | 9,616 | 910,174 |
| 100th prime (`primes.lam`) | graph only | 154,682 reductions | 43 | 11,288 | 10,692,216 |

Setup ends where each machine's main loop is first entered (`run` in `secd.asm`, `next` in `cam.asm`, `whnf` in `graph.asm`).

**Strict, first-order programs.** On `fac` and fib(20), the graph reducer runs 1.5–2.4 times slower than the CAM.
- It takes fewer steps, but each costs about 70 VM16 instructions, against about 15 for a CAM instruction.
- About 25 of those 70 go to unwinding the spine (2.5 cells per reduction in fib, at 9 instructions each), and 13 to checking the arity and dispatching.

**Higher-order programs.** On Church numerals it is the fastest of the three: 1.6 times faster than the CAM and 4.4 times faster than the SECD machine.
- Sharing means a numeral that is used several times is built only once.
- The CAM and the SECD machine build closures and environments for every application. A combinator rule only rearranges its arguments.

**On a Z80.** The Z80 VM16 interpreter and the C one give identical final memory for the graphs of `fac.lam`, `../fac.lam` and smaller tests.
- On a 4 MHz Z80, `fac.lam` takes 0.68 s and `../fac.lam` 69 s.
- fib(20) would take about 20 minutes, estimated from 288 Z80 cycles per VM16 instruction.

**Size.** `graph.v16` is 2,451 bytes. The reducer, its rules and the arithmetic take about 940 bytes of that. `lib.asm` (the garbage collector, input, printing and errors) takes 698 bytes, and the rest is the loader, the tables and the messages. The reader and compiler that were in VM16 before took about 1,000 bytes.

## Where to go from here

- **Faster reduction.** The reducer re-unwinds from the root after every rewrite, and checks for stack overflow on every push. Keeping the spine across rewrites and checking the stack once per reduction would remove much of the 70-instruction cost.
- **Better abstraction.** Kiselyov's 2018 algorithm, or more combinators, would shrink the code. Supercombinators (Hughes 1982), compiled to G-machine code, are the step after that, toward how lazy functional languages were implemented in the 1980s.
- **Lazy output.** A program whose result is an infinite list of characters, printed as it is computed. This is how Turner's languages did I/O.
