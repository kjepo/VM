#!/usr/bin/env python3
"""lam2cam.py - translate a program with definitions into the input of cam.asm.

    python3 lam2cam.py fib.lam                print the core term
    python3 lam2cam.py fib.lam | ../vm16 cam.v16
    ./run fib.lam                             the same

The input is the syntax of ../graph (see ../graph/prototype.py): definitions
f x y = M separated by ;, then the program's value, an expression or main:

    fib n = if n < 2 then n else fib (n-1) + fib (n-2);
    fib 20

cam.asm reads the core syntax: single-letter variables, \\x.M, rec f.\\x.M,
if c t e and the prefix operators. The translation
- orders the definitions so that each comes after those it uses, and binds
  them around the final expression with applications: let f = F in M is
  (\\f.M) F;
- turns a definition that uses itself into rec f.F, which must be a function;
- puts a function that is used only once in place of its use, so fac 7 with
  fac n = ... becomes (rec a.\\b. ...) 7;
- names each variable after its binding depth, a, b, c, ..., so that no name
  is ever hidden by another (cam.asm folds case, so there are 26 names).
The CAM is strict, so definitions that call each other (mutual recursion),
recursive values that are not functions, and Y are rejected.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'graph'))
from prototype import App, Error, Lam, Reader, Var  # noqa: E402

LETTERS = 'abcdefghijklmnopqrstuvwxyz'


def free(t, bound=frozenset()):
    """The free variables of t."""
    if isinstance(t, Var):
        return set() if t.x in bound else {t.x}
    if isinstance(t, Lam):
        return free(t.body, bound | {t.x})
    if isinstance(t, App):
        return free(t.f, bound) | free(t.a, bound)
    return set()


def order(defs, expr):
    """The definitions expr needs, each after the ones it uses."""
    done, active, out = set(), [], []

    def visit(x):
        if x in done:
            return
        if x in active:
            cycle = active[active.index(x):]
            raise Error('the CAM cannot run mutually recursive definitions: '
                        + ', '.join(cycle))
        active.append(x)
        for y in sorted(free(defs[x]) - {x}):
            if y in defs:
                visit(y)
        active.pop()
        done.add(x)
        out.append(x)

    for x in sorted(free(expr)):
        if x not in defs:
            raise Error('unbound variable ' + x)
        visit(x)
    for x, t in defs.items():                        # also check unused ones
        for y in free(t) - {x}:
            if y not in defs:
                raise Error('unbound variable ' + y)
    return out


def uses(t, x, bound=frozenset()):
    """How many times the variable x occurs free in t."""
    if isinstance(t, Var):
        return t.x == x and x not in bound
    if isinstance(t, Lam):
        return uses(t.body, x, bound | {t.x})
    if isinstance(t, App):
        return uses(t.f, x, bound) + uses(t.a, x, bound)
    return 0


def program(defs, expr):
    """The program as one term, with Rec nodes for rec f.M, and the functions
    to put in place of their only use, as a dict name -> term."""
    if expr is None:
        if 'main' not in defs:
            raise Error('no main')
        expr = Var('main')
    names = order(defs, expr)
    terms, inline = {}, {}
    for x in names:
        t = defs[x]
        if x in free(t):
            if not isinstance(t, Lam):
                raise Error(x + ' is a recursive value, not a function')
            t = Rec(x, t)
        terms[x] = t
    for x in names:
        n = uses(expr, x) + sum(uses(defs[y], x) for y in names if y != x)
        if n == 1 and isinstance(terms[x], (Lam, Rec)):
            inline[x] = terms[x]
    bound = [x for x in names if x not in inline]
    for x in reversed(bound):
        expr = App(Lam(x, expr), terms[x])
    return expr, bound, inline


class Rec:
    __slots__ = ('f', 'body')

    def __init__(self, f, body):
        self.f, self.body = f, body


def show(t, env=(), atom=False, inline={}, nglobal=0):
    """t in cam.asm's syntax. env lists the bound names, innermost last, and
    its first nglobal are the definitions; None is a name that is hidden."""
    def letter(x):
        if len(env) >= len(LETTERS):
            raise Error('more than 26 nested variables')
        return LETTERS[len(env)]

    def wrap(s):
        return f'({s})' if atom else s

    if isinstance(t, int):
        return f'({t})' if t < 0 and atom else str(t)
    if isinstance(t, str):
        if t == 'IF':
            raise Error('if needs all three of its arguments on the CAM')
        if t == 'Y':
            raise Error('Y does not terminate on the CAM: use a definition or rec')
        return t                                     # an operator
    if isinstance(t, Var):
        for depth in range(len(env) - 1, -1, -1):
            if env[depth] == t.x:
                return LETTERS[depth]
        if t.x in inline:                            # hide the locals around the use
            hidden = env[:nglobal] + (None,) * (len(env) - nglobal)
            return show(inline[t.x], hidden, atom, inline, nglobal)
        raise Error('unbound variable ' + t.x)
    if isinstance(t, Lam):
        params = []
        while isinstance(t, Lam):
            params.append(letter(t.x))
            env += (t.x,)
            t = t.body
        return wrap('\\' + ' '.join(params) + '.' + show(t, env, False, inline, nglobal))
    if isinstance(t, Rec):
        f = letter(t.f)
        return wrap(f'rec {f}.' + show(t.body, env + (t.f,), False, inline, nglobal))
    if isinstance(t, App) and isinstance(t.f, App) and isinstance(t.f.f, App) \
            and t.f.f.f == 'IF':
        return wrap('if ' + ' '.join(show(u, env, True, inline, nglobal) for u in (t.f.f.a, t.f.a, t.a)))
    if isinstance(t, App):
        if t.f == 'Y' and isinstance(t.a, Lam):      # rec f.M from the .lam syntax
            return show(Rec(t.a.x, t.a.body), env, atom, inline, nglobal)
        f = show(t.f, env, not is_plain_app(t.f), inline, nglobal)
        return wrap(f + ' ' + show(t.a, env, True, inline, nglobal))
    raise Error(f'cannot translate {t!r}')


def is_plain_app(t):
    """t prints as an application, which needs no brackets as a function."""
    return isinstance(t, App) and not is_if(t) and not (t.f == 'Y' and isinstance(t.a, Lam))


def is_if(t):
    return isinstance(t, App) and isinstance(t.f, App) and isinstance(t.f.f, App) \
        and t.f.f.f == 'IF'


def translate(text):
    defs, expr = Reader(text).program()
    term, names, inline = program(defs, expr)
    lines = [f'# {x} = {LETTERS[i]}' for i, x in enumerate(names)]
    return '\n'.join(lines + [show(term, (), False, inline, len(names))]) + '\n'


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else None
    if path in ('-h', '--help') or len(sys.argv) > 2:
        print(__doc__, file=sys.stderr)
        return 2
    text = open(path).read() if path else sys.stdin.read()
    sys.setrecursionlimit(100000)
    try:
        sys.stdout.write(translate(text))
    except Error as e:
        print('error:', e, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
