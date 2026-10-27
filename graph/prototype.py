#!/usr/bin/env python3
"""prototype.py - combinator graph reduction in Python, the model for graph.asm.

    python3 prototype.py fac.lam              compile, reduce, print the result
    python3 prototype.py -c fac.lam           also print the combinator term
    python3 prototype.py --ski fac.lam        use only S, K and I
    python3 prototype.py --trace prog.lam     print the program after each reduction
    python3 prototype.py fac.graph            reduce a graph written by lam2graph.py
    python3 prototype.py fac.morc             a MORC program (see morc.py)

Reads a program of definitions and an expression, compiles it with Turner's
bracket abstraction, writes it in the .graph format that graph.asm reads, and
reduces that graph lazily. The reducer makes exactly the same rewrites in the
same order as graph.asm, so the reduction counts must agree.
"""
import argparse
import sys

ARITY = {'I': 1, 'K': 2, 'S': 3, 'B': 3, 'C': 3, "S'": 4, 'B*': 4, "C'": 4,
         'Y': 1, 'IF': 3, '+': 2, '-': 2, '*': 2, '/': 2, '%': 2, '=': 2, '<': 2}


class App:
    __slots__ = ('f', 'a')

    def __init__(self, f, a):
        self.f, self.a = f, a


class Var:
    """A variable in the syntax tree. Combinators are plain strings."""
    __slots__ = ('x',)

    def __init__(self, x):
        self.x = x


class Global:
    """A reference to the n-th definition of the program, after compiling."""
    __slots__ = ('name', 'n')

    def __init__(self, name, n):
        self.name, self.n = name, n


class Lam:
    __slots__ = ('x', 'body')

    def __init__(self, x, body):
        self.x, self.body = x, body


class Error(Exception):
    pass


# ---------------------------------------------------------------------------
# Reader
# ---------------------------------------------------------------------------
# program = item ; item ; ...      an optional ; after the last item
# item    = name name ... = term   a definition: f x y = M is f = \x y.M
#         | term                   the program's value; only as the last item
# term    = sum [ cmp sum ]        cmp is = == != < <= > >=; they do not chain
# sum     = product { (+ | -) product }
# product = app { (* | / | %) app }
# app     = op atom ...            an operator first is the curried primitive
#         | atom atom ...          application, left-associative
# atom    = name | 42 | -42 | (term) | \x y ... . term
#         | if atom atom atom | if term then term else term | rec f . term
# -42 is a number unless it follows an operand, where - is subtraction: x-1
# is x - 1, and f (-1) passes -1.
# A name is a letter followed by letters, digits and _; "if", "then", "else"
# and "rec" are keywords. Without a final term, the program's value is main.
# In if c then a else b, the else branch extends as far right as it can.
KEYWORDS = ('if', 'then', 'else', 'rec')


def is_letter(c):
    return c is not None and c.isascii() and c.isalpha()


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
        """(definitions as a dict name -> term, the final term or None)"""
        defs, expr = {}, None
        while self.look() is not None:
            if expr is not None:
                self.error()                          # an item after the final term
            d = self.definition()
            if d:
                if d[0] in defs:
                    raise Error(d[0] + ' is defined twice')
                defs[d[0]] = d[1]
            else:
                expr = self.term()
            if self.look() == ';':
                self.i += 1
            elif self.look() is not None:
                self.error()
        if expr is None and not defs:
            self.error()
        return defs, expr

    def definition(self):
        """(name, term) if a definition starts here, else None."""
        start = self.i
        names = []
        while is_letter(self.look()):
            x = self.ident()
            if x in KEYWORDS:
                break
            names.append(x)
        if names and self.look() == '=' and self.s[self.i + 1:self.i + 2] != '=':
            self.i += 1
            t = self.term()
            for x in reversed(names[1:]):
                t = Lam(x, t)
            return names[0], t
        self.i = start
        return None

    def ident(self):
        j = self.i
        while self.i < len(self.s) and self.s[self.i].isascii() and \
                (self.s[self.i].isalnum() or self.s[self.i] == '_'):
            self.i += 1
        return self.s[j:self.i]

    def word(self, w):
        if not self.at_word(w):
            self.error()
        self.ident()

    def name(self):
        """A name that is not a keyword."""
        start = self.i
        if not is_letter(self.look()):
            self.error()
        x = self.ident()
        if x in KEYWORDS:
            self.i = start
            self.error()
        return x

    def term(self):
        a = self.sum()
        if self.at_op(*COMPARE):
            op = self.op()
            a = binary(op, a, self.sum())
        return a

    def sum(self):
        a = self.product()
        while self.at_op('+', '-'):
            op = self.op()
            a = binary(op, a, self.product())
        return a

    def product(self):
        a = self.app()
        while self.at_op('*', '/', '%'):
            op = self.op()
            a = binary(op, a, self.app())
        return a

    def app(self):
        a = section(self.op()) if self.at_op() else self.atom()
        while self.look() not in (None, ')', ';') and not self.at_op() and \
                not self.at_word('then', 'else'):
            a = App(a, self.atom())
        return a

    def at_op(self, *ops):
        """Whether an operator (one of ops, if given) comes next. A - before a
        digit that does not follow an operand starts a negative number."""
        c = self.look()
        if c is None or c not in '+-*/%=<>!':
            return False
        if c == '-' and self.s[self.i + 1:self.i + 2].isdigit() and not self.after_operand():
            return False
        op = self.s[self.i:self.i + 2] if self.s[self.i:self.i + 2] in ('==', '!=', '<=', '>=') else c
        return op in (ops or OPERATORS)

    def op(self):
        op = self.s[self.i:self.i + 2] if self.s[self.i:self.i + 2] in ('==', '!=', '<=', '>=') else self.s[self.i]
        if op not in OPERATORS:
            self.error()
        self.i += len(op)
        return op

    def after_operand(self):
        """Whether the text just before the next item ends an operand: a name
        that is not a keyword, a number, or a )."""
        j = self.i
        while j > 0 and ord(self.s[j - 1]) <= 32:
            j -= 1
        if j == 0:
            return False
        if self.s[j - 1] == ')':
            return True
        k = j
        while k > 0 and self.s[k - 1].isascii() and (self.s[k - 1].isalnum() or self.s[k - 1] == '_'):
            k -= 1
        return k < j and self.s[k:j] not in KEYWORDS

    def at_word(self, *words):
        """Whether the next item is one of the words."""
        c = self.look()
        if not is_letter(c):
            return False
        start = self.i
        x = self.ident()
        self.i = start
        return x in words

    def then_follows(self):
        """Whether "then" comes before the end of this if: before a ; or an
        unmatched ), or another if, at the same depth of brackets."""
        start, depth, found = self.i, 0, False
        while True:
            c = self.look()
            if c is None or c == ';' or (c == ')' and depth == 0):
                break
            if is_letter(c):
                x = self.ident()
                if depth == 0 and x in ('then', 'if'):
                    found = x == 'then'
                    break
                continue
            depth += {'(': 1, ')': -1}.get(c, 0)
            self.i += 1
        self.i = start
        return found

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
                if self.look() == '.' and names:
                    self.i += 1
                    break
                names.append(self.name())
            t = self.term()
            for x in reversed(names):
                t = Lam(x, t)
            return t
        if c == '-' and self.s[self.i + 1:self.i + 2].isdigit():
            self.i += 1
            return wrap(-self.number())
        if c.isdigit():
            return self.number()
        if is_letter(c):
            x = self.ident()
            if x == 'if':
                if not self.then_follows():
                    return App(App(App('IF', self.atom()), self.atom()), self.atom())
                c = self.term()
                self.word('then')
                a = self.term()
                self.word('else')
                return App(App(App('IF', c), a), self.term())
            if x == 'rec':
                f = self.name()
                if self.look() != '.':
                    self.error()
                self.i += 1
                return App('Y', Lam(f, self.term()))
            if x in KEYWORDS:
                self.i -= len(x)
                self.error()
            return Var(x)
        self.error()


def wrap(n):
    """n as a 15-bit signed number, as graph.asm stores it."""
    n &= 0x7FFF
    return n - 0x8000 if n & 0x4000 else n


COMPARE = ('=', '==', '!=', '<', '<=', '>', '>=')
OPERATORS = ('+', '-', '*', '/', '%') + COMPARE


def binary(op, a, b):
    """a op b as a term of the primitive operators (and : for MORC's lists)."""
    if op == ':':
        return App(App(Var(':'), a), b)
    if op == '==':
        op = '='
    if op == '>':                                     # a > b = b < a
        return App(App('<', b), a)
    if op in ('!=', '<=', '>='):                      # 1 - the opposite comparison
        opposite = {'!=': App(App('=', a), b), '<=': App(App('<', b), a),
                    '>=': App(App('<', a), b)}[op]
        return App(App('-', 1), opposite)
    return App(App(op, a), b)


def section(op):
    """The operator op as a function of two arguments: (+) or + alone."""
    if op in ('+', '-', '*', '/', '%', '=', '<'):
        return op
    if op == '==':
        return '='
    if op == ':':
        return Var(':')
    a, b = ' a', ' b'                                 # names no program can use
    return Lam(a, Lam(b, binary(op, Var(a), Var(b))))


def read_graph(text):
    """The graph in lam2graph.py's postfix format, as graph.asm reads it."""
    stack, glob, cells = [], [], 0
    for line in text.splitlines():
        for t in line.split('#', 1)[0].split():
            if t[0] in '%$=' and t[1:2].isdigit():   # a global: %count, $n or =n
                bad = [c for c in t[1:] if not c.isdigit()]
                if bad:
                    raise Error(f"syntax error at '{bad[0]}'")
                n = int(t[1:]) & 0xFFFF
                if t[0] == '%':
                    if cells:
                        raise Error('bad global')
                    glob = [App('I', 'I') for _ in range(n)]
                    cells += n
                elif n >= len(glob):
                    raise Error('bad global')
                elif t[0] == '$':
                    stack.append(glob[n])
                elif not stack or not isinstance(stack[-1], App):
                    raise Error('bad global')
                else:
                    w = stack.pop()
                    glob[n].f, glob[n].a = w.f, w.a
            elif t == '@':
                if len(stack) < 2:
                    raise Error("syntax error at '@'")
                a = stack.pop()
                stack.append(App(stack.pop(), a))
                cells += 1
            elif t in ARITY:
                stack.append(t)
            elif t[0].isdigit() or (t[0] == '-' and t[1:2].isdigit()):
                digits = t[1:] if t[0] == '-' else t
                bad = [c for c in digits if not c.isdigit()]
                if bad:
                    raise Error(f"syntax error at '{bad[0]}'")
                stack.append(wrap(int(t)))
            elif len(t) > 2:
                raise Error(f"syntax error at '{t[2]}'")
            else:
                raise Error('unknown combinator')
    if len(stack) != 1:
        raise Error('syntax error at end of input')
    return stack[0]


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


def compile_program(defs, expr, turner=True):
    """Compile every definition and the final term (or main). Returns the
    definitions reachable from the final term, as a list of (name, code) in the
    order of their numbers, and the final term's code. In the code, a free
    variable that names a definition is a Global leaf; any other is unbound."""
    if expr is None:
        if 'main' not in defs:
            raise Error('no main')
        expr = Var('main')
    code = {x: compile_(t, turner) for x, t in defs.items()}
    for c in code.values():
        resolve(c, defs, {})                          # report unbound variables
    index = {}
    main = resolve(compile_(expr, turner), defs, index)
    done = []
    while len(done) < len(index):                     # index grows as code is resolved
        x = list(index)[len(done)]
        done.append((x, resolve(code[x], defs, index)))
    return done, main


def resolve(e, defs, index):
    """e with each free variable replaced by a Global leaf, numbered in index
    in the order they are first met."""
    if isinstance(e, App):
        return App(resolve(e.f, defs, index), resolve(e.a, defs, index))
    if isinstance(e, Var):
        if e.x not in defs:
            raise Error('unbound variable ' + e.x)
        if e.x not in index:
            index[e.x] = len(index)
        return Global(e.x, index[e.x])
    return e


def emit(program):
    """The compiled program as lines of graph.asm's postfix format."""
    glob, main = program
    out = []
    if glob:
        out.append(f'%{len(glob)}')
    for n, (x, e) in enumerate(glob):
        if not isinstance(e, App):
            e = App('I', e)                           # =n needs a cell to copy
        out.append(f'# {x}')
        out += lines(postfix(e) + [f'={n}'])
    if glob:
        out.append('# the program')
    out += lines(postfix(main))
    return out


def postfix(e):
    """The tokens of e in postfix, without recursion."""
    out, todo = [], [e]
    while todo:
        e = todo.pop()
        if isinstance(e, App):
            todo += ['@', e.a, e.f]
        elif isinstance(e, Global):
            out.append(f'${e.n}')
        else:
            out.append(str(e))
    return out


def lines(tokens, width=72):
    out, line = [], ''
    for t in tokens:
        if line and len(line) + 1 + len(t) > width:
            out.append(line)
            line = t
        else:
            line = line + ' ' + t if line else t
    if line:
        out.append(line)
    return out


def compile_text(text, turner=True, morc=False):
    """Compile a .lam program, or a MORC program (see morc.py)."""
    if morc:
        from morc import Reader as MorcReader
        return compile_program(*MorcReader(text).program(), turner)
    return compile_program(*Reader(text).program(), turner)


def show_program(program):
    glob, main = program
    return [f'{x} = {show(e)}' for x, e in glob] + [show(main)]


def show(e):
    if isinstance(e, App):
        a = e.a
        return show(e.f) + ' ' + (f'({show(a)})' if isinstance(a, App) else show(a))
    if isinstance(e, Var):
        return e.x
    return e.name if isinstance(e, Global) else str(e)


def show_graph(e, path=()):
    """The graph e as a term: a shared cell is printed at each of its uses, and
    a reference back to an enclosing cell (a cycle made by Y) prints as @."""
    if not isinstance(e, App):
        return show(e)
    if any(e is p for p in path):
        return '@'
    path += (e,)
    a = e.a
    sa = show_graph(a, path)
    return show_graph(e.f, path) + ' ' + (f'({sa})' if isinstance(a, App) and sa != '@' else sa)


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
        self.trace = None       # called with the rule after each reduction
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
        rule = None
        while True:
            if rule and self.trace:
                self.trace(rule)
                rule = None
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
            rule = r
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


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('program', nargs='?', help='file to run (default: standard input)')
    ap.add_argument('-g', '--graph', action='store_true',
                    help='the input is a graph from lam2graph.py (implied by a .graph file)')
    ap.add_argument('-m', '--morc', action='store_true',
                    help='the input is a MORC program (implied by a .morc file)')
    ap.add_argument('-c', '--code', action='store_true', help='print the combinator term')
    ap.add_argument('--ski', action='store_true', help='compile to S, K and I only')
    ap.add_argument('--counts', action='store_true', help='print the reductions per combinator')
    ap.add_argument('--trace', action='store_true', help='print the program after each reduction')
    ap.add_argument('--depth', type=int, default=10000, help='the deepest nesting of whnf allowed')
    a = ap.parse_args()
    text = open(a.program).read() if a.program else sys.stdin.read()
    sys.setrecursionlimit(100000)
    m = Machine(a.depth)
    try:
        if not (a.graph or (a.program or '').endswith('.graph')):
            program = compile_text(text, not a.ski, a.morc or (a.program or '').endswith('.morc'))
            text = '\n'.join(emit(program))
            if a.code:
                print('\n'.join(show_program(program)))
                print(f'[{text.split().count("@")} cells]')
        code = read_graph(text)
        if a.trace:
            done = [0]

            def trace(rule):
                done[0] += 1
                print(f'{done[0]:5}  {rule:3} {show_graph(code)}')
            m.trace = trace
            print(f'{0:5}      {show_graph(code)}')
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
