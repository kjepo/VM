#!/usr/bin/env python3
"""prototype.py - combinator graph reduction in Python, the model for graph.asm.

    python3 prototype.py fac.lam              compile, reduce, print the result
    python3 prototype.py -c fac.lam           also print the combinator term
    python3 prototype.py --ski fac.lam        use only S, K and I

Reads the same syntax as graph.asm, compiles it with Turner's bracket
abstraction and reduces the graph lazily. The reducer makes exactly the same
rewrites in the same order as graph.asm, so the reduction counts must agree.
"""
import argparse
import sys

ARITY = {'I': 1, 'K': 2, 'S': 3, 'B': 3, 'C': 3, "S'": 4, 'B*': 4, "C'": 4,
         'Y': 1, 'IF': 3, '+': 2, '-': 2, '*': 2, '/': 2, '%': 2, '=': 2, '<': 2}
OPS = '+-*/%=<'


class App:
    __slots__ = ('f', 'a')

    def __init__(self, f, a):
        self.f, self.a = f, a


class Var:
    """A variable in the syntax tree. Combinators are plain strings."""
    __slots__ = ('x',)

    def __init__(self, x):
        self.x = x


class Lam:
    __slots__ = ('x', 'body')

    def __init__(self, x, body):
        self.x, self.body = x, body


class Error(Exception):
    pass


# ---------------------------------------------------------------------------
# Reader: the syntax of ../CAM/cam.asm, with rec f.M for any M
# ---------------------------------------------------------------------------
class Reader:
    def __init__(self, text):
        self.s, self.i = text, 0

    def look(self):
        while self.i < len(self.s):
            c = self.s[self.i]
            if c == '#':
                while self.i < len(self.s) and self.s[self.i] != '\n':
                    self.i += 1
            elif ord(c) <= 32:
                self.i += 1
            else:
                return c
        return None

    def error(self):
        c = self.look()
        raise Error('syntax error at ' + ("end of input" if c is None else f"'{c}'"))

    def program(self):
        t = self.term()
        if self.look() is not None:
            self.error()
        return t

    def term(self):
        t = self.atom()
        while self.look() not in (None, ')'):
            t = App(t, self.atom())
        return t

    def number(self):
        n = 0
        while self.i < len(self.s) and self.s[self.i].isdigit():
            n = (n * 10 + int(self.s[self.i])) & 0xFFFF
            self.i += 1
        return wrap(n)

    def atom(self):
        c = self.look()
        if c is None:
            self.error()
        if c == '(':
            self.i += 1
            t = self.term()
            if self.look() != ')':
                self.error()
            self.i += 1
            return t
        if c == '\\':
            self.i += 1
            names = []
            while True:
                c = self.look()
                if c == '.' and names:
                    self.i += 1
                    break
                if c is None or not c.isalpha():
                    self.error()
                names.append(c)
                self.i += 1
            t = self.term()
            for x in reversed(names):
                t = Lam(x, t)
            return t
        if c in OPS:
            self.i += 1
            if c == '-' and self.i < len(self.s) and self.s[self.i].isdigit():
                return wrap(-self.number())
            return c
        if c.isdigit():
            return self.number()
        if c.isalpha():
            self.i += 1
            nxt = self.s[self.i] if self.i < len(self.s) else ''
            if c == 'i' and nxt == 'f':
                self.i += 1
                return App(App(App('IF', self.atom()), self.atom()), self.atom())
            if c == 'r' and nxt == 'e':
                self.i += 1
                if self.s[self.i:self.i + 1] != 'c':
                    self.error()
                self.i += 1
                f = self.look()
                if f is None or not f.isalpha():
                    self.error()
                self.i += 1
                if self.look() != '.':
                    self.error()
                self.i += 1
                return App('Y', Lam(f, self.term()))
            return Var(c)
        self.error()


def wrap(n):
    """n as a 15-bit signed number, as graph.asm stores it."""
    n &= 0x7FFF
    return n - 0x8000 if n & 0x4000 else n


# ---------------------------------------------------------------------------
# Compiler: bracket abstraction
# ---------------------------------------------------------------------------
def compile_(t, turner):
    if isinstance(t, Lam):
        return abstract(t.x, compile_(t.body, turner), turner)
    if isinstance(t, App):
        return App(compile_(t.f, turner), compile_(t.a, turner))
    return t


def abstract(x, e, turner):
    """[x] e, for e without lambdas."""
    if isinstance(e, App):
        return opt_s(abstract(x, e.f, turner), abstract(x, e.a, turner), turner)
    if isinstance(e, Var) and e.x == x:
        return 'I'
    return App('K', e)


def is_app(e, head):
    return isinstance(e, App) and isinstance(e.f, str) and e.f == head


def opt_s(a, b, turner):
    """S a b, simplified with Turner's rules (only the K rule for plain SKI)."""
    if is_app(a, 'K'):
        p = a.a
        if is_app(b, 'K'):                            # S (K p) (K q) = K (p q)
            return App('K', App(p, b.a))
        if not turner:
            return App(App('S', a), b)
        if b == 'I':                                  # S (K p) I = p
            return p
        if isinstance(b, App) and is_app(b.f, 'B'):   # S (K p) (B q r) = B* p q r
            return App(App(App('B*', p), b.f.a), b.a)
        return App(App('B', p), b)                    # S (K p) q = B p q
    if turner and isinstance(a, App) and is_app(a.f, 'B'):
        if is_app(b, 'K'):                            # S (B p q) (K r) = C' p q r
            return App(App(App("C'", a.f.a), a.a), b.a)
        return App(App(App("S'", a.f.a), a.a), b)     # S (B p q) r = S' p q r
    if turner and is_app(b, 'K'):                     # S p (K q) = C p q
        return App(App('C', a), b.a)
    return App(App('S', a), b)


def check_free(e):
    if isinstance(e, App):
        check_free(e.f)
        check_free(e.a)
    elif isinstance(e, Var):
        raise Error('unbound variable ' + e.x)


def show(e):
    if isinstance(e, App):
        a = e.a
        return show(e.f) + ' ' + (f'({show(a)})' if isinstance(a, App) else show(a))
    return e.x if isinstance(e, Var) else str(e)


# ---------------------------------------------------------------------------
# Reducer
# ---------------------------------------------------------------------------
class Machine:
    def __init__(self, limit=10000):
        self.steps = 0
        self.cells = 0          # cells allocated by reductions
        self.depth = 0          # nesting of whnf
        self.maxdepth = 0
        self.limit = limit
        self.counts = {}

    def app(self, f, a):
        self.cells += 1
        return App(f, a)

    def number(self, e, what='an operator'):
        v = self.whnf(e)
        if not isinstance(v, int):
            raise Error(what + ' needs a number')
        return v

    def whnf(self, r):
        """Reduce the graph r to weak head normal form, updating it in place."""
        self.depth += 1
        self.maxdepth = max(self.maxdepth, self.depth)
        if self.depth > self.limit:
            raise Error('out of stack')
        spine = []
        while True:
            if isinstance(r, App):
                spine.append(r)
                r = r.f
                continue
            if isinstance(r, int):
                if spine:
                    raise Error('only a function can be applied')
                break
            n = ARITY[r]
            if len(spine) < n:                        # a partial application
                if spine:
                    r = spine[0]
                break
            self.steps += 1
            self.counts[r] = self.counts.get(r, 0) + 1
            s = spine[-n:]
            s.reverse()                               # s[0] = innermost
            arg = [c.a for c in s]
            root = s[-1]
            if r == 'I':
                spine.pop()
                r = arg[0]
                if r is root:
                    raise Error('a value defined as itself')
                if spine:
                    spine[-1].f = r                   # shorten the parent's pointer
                continue
            if r == 'Y':                              # Y f = f (Y f), as a cycle
                root.f, root.a = arg[0], root
            elif r == 'S':
                root.f, root.a = self.app(arg[0], arg[2]), self.app(arg[1], arg[2])
            elif r == 'B':
                root.f, root.a = arg[0], self.app(arg[1], arg[2])
            elif r == 'C':
                root.f, root.a = self.app(arg[0], arg[2]), arg[1]
            elif r == "S'":
                root.f = self.app(arg[0], self.app(arg[1], arg[3]))
                root.a = self.app(arg[2], arg[3])
            elif r == 'B*':
                root.f, root.a = arg[0], self.app(arg[1], self.app(arg[2], arg[3]))
            elif r == "C'":
                root.f, root.a = self.app(arg[0], self.app(arg[1], arg[3])), arg[2]
            else:                                     # the result is an indirection
                if r == 'K':
                    v = arg[0]
                elif r == 'IF':
                    v = arg[1] if self.number(arg[0], 'if') != 0 else arg[2]
                else:
                    a = self.number(arg[0])
                    b = self.number(arg[1])
                    v = arith(r, a, b)
                root.f, root.a = 'I', v
                del spine[-n:]
                r = v
                if spine:
                    spine[-1].f = r
                continue
            del spine[-n:]
            r = root
        self.depth -= 1
        return r


def arith(op, a, b):
    if op in '/%':
        if b == 0:
            raise Error('division by zero')
        q = abs(a) // abs(b) * (1 if (a < 0) == (b < 0) else -1)
        return wrap(q if op == '/' else a - q * b)
    return {'+': lambda: wrap(a + b), '-': lambda: wrap(a - b), '*': lambda: wrap(a * b),
            '=': lambda: int(a == b), '<': lambda: int(a < b)}[op]()


def size(e):
    return 1 + size(e.f) + size(e.a) if isinstance(e, App) else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('program', nargs='?', help='file to run (default: standard input)')
    ap.add_argument('-c', '--code', action='store_true', help='print the combinator term')
    ap.add_argument('--ski', action='store_true', help='compile to S, K and I only')
    ap.add_argument('--counts', action='store_true', help='print the reductions per combinator')
    ap.add_argument('--depth', type=int, default=10000, help='the deepest nesting of whnf allowed')
    a = ap.parse_args()
    text = open(a.program).read() if a.program else sys.stdin.read()
    sys.setrecursionlimit(100000)
    m = Machine(a.depth)
    try:
        code = compile_(Reader(text).program(), not a.ski)
        check_free(code)
        if a.code:
            print(show(code))
            print(f'[{size(code)} cells]')
        v = m.whnf(code)
        print(v if isinstance(v, int) else '<function>')
    except Error as e:
        print('error:', e)
        return 1
    except RecursionError:
        print('error: out of stack')
        return 1
    print(f'[{m.steps} reductions, {m.cells} cells allocated, nesting {m.maxdepth}]')
    if a.counts:
        for k, v in sorted(m.counts.items(), key=lambda kv: -kv[1]):
            print(f'  {k:3} {v}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
