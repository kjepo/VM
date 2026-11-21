# Interaction nets

A tutorial on Lafont's interaction nets (`inet-tutorial.tex`, build with
`latexmk -pdf`) and the small reducer that produced its traces and counts.

- `inet.py` reads rules and nets in term notation (`.inet`) or a λ-term
  (`.lam`, run on the rules in `lambda.inet`), reduces, and prints the result
  and the number of interactions per rule. Options: `-t` trace, `-r SEED`
  random order, `-n LIMIT`, `-q`, `-d DIR` (a Graphviz file per step); for
  `.lam`, `-c` checks the result against normal-order reduction and `-l`
  reduces only what the readback needs.
- `nat.inet` (unary `Add`, `Mul`, `Max`, `Dup`, `Era`) with `add.inet`,
  `mul.inet`, `max.inet`, `fib.inet` (fib 3; the pending `Add` agents are
  the stack frames), and `inf.inet` (garbage that never stops growing).
- `combinators.inet`: Lafont's interaction combinators; `selfapp.inet`
  encodes `(\x. x x) (\y. y)` with them.
- `lambda.inet`: `Lam`, `App`, labelled fans `Dup{i}`, `Era`. Fans get a
  fresh label per binder, which is wrong when a fan copies a copy of itself:
  `lam/shared.lam` and `lam/omega.lam` show it, `lam/twotwo.lam` is the same
  computation done correctly.
- `./draw PROG DIR [options]` draws one picture per interaction
  (`DIR/step-NNN.png`, with the pair about to fire in red) and an animated
  `DIR/steps.gif`. Agents are triangles with the principal port at the apex;
  one agent of each active pair is turned over. Needs Graphviz and
  ImageMagick. `pictures/` holds `fib`, `add` and `selfapp`.
- `sh test.sh` checks every count quoted in the tutorial.
