"""morc.py - the reader for MORC, the Mora Recursive Calculator.

A MORC program is a series of definitions; its value is main:

    fun fac 0 = 1;
    fun fac n = n * fac (n - 1);
    fun main = fac 7;

Grammar (the usual precedences, loosest first):

    program    ::= definition { definition }
    definition ::= "fun" IDENT { pattern } "=" expr ";"  (the last ; may be left out)
    pattern    ::= IDENT | "_" | NUM | "-" NUM | "true" | "false" | "nil"
                 | "(" pattern [ ":" pattern ] ")"      : is right-associative
    expr       ::= "\\" IDENT { IDENT } "->" expr
                 | "if" expr "then" expr "else" expr
                 | compare
    compare    ::= cons [ ("=" | "==" | "!=" | "<" | "<=" | ">" | ">=") cons ]
    cons       ::= sum [ ":" cons ]                      right-associative
    sum        ::= [ "-" ] product { ("+" | "-") product }
    product    ::= app { ("*" | "/" | "%") app }
    app        ::= atom { atom }                         application binds tightest
    atom       ::= IDENT | NUM | "true" | "false" | "nil"
                 | "(" expr ")" | "(" op ")"             (+) is the function +
                 | "\\" ... | "if" ...                    a lambda or if extends as far
                                                         right as possible

Names are a letter followed by letters, digits and _. # starts a comment.

The reader returns the same syntax tree as the .lam reader in prototype.py:
a + b is the curried primitive + applied to a and b, true and false are 1
and 0 (what = and < return, and what IF tests), and lists are Scott-encoded,
h : t = \\c n. c h t and nil = \\c n. n, as two built-in definitions named
":" and "nil" that are only written to the graph when they are used.

A function may be defined by several clauses, one after the other, with the
same number of patterns. They are tried from the top, and the patterns of a
clause from the left, and each argument is evaluated only as far as the
patterns need it. match() turns the clauses into one term of the same core
(Wadler's match compiler): a list pattern becomes an application of the list,
l (\\h t -> ...) (...), and a number pattern an if. The compiler rejects a
clause that can never be used, and clauses that do not cover every argument.
"""
import re

from prototype import App, COMPARE, Error, Lam, Var, binary, section, wrap

KEYWORDS = ('fun', 'if', 'then', 'else', 'true', 'false', 'nil')
OPERATORS = ('+', '-', '*', '/', '%', ':') + COMPARE
TOKEN = re.compile(r'\s+|#[^\n]*|(?P<tok>[A-Za-z][A-Za-z0-9_]*|\d+|->|==|!=|<=|>=|[-+*/%=<>:;()\\_])')

# The built-in definitions for lists.
BUILTINS = {
    ':': Lam('h', Lam('t', Lam('c', Lam('n', App(App(Var('c'), Var('h')), Var('t')))))),
    'nil': Lam('c', Lam('n', Var('n'))),
}


def tokenize(text):
    out, i = [], 0
    while i < len(text):
        m = TOKEN.match(text, i)
        if not m:
            raise Error(f"syntax error at '{text[i]}'")
        if m.group('tok'):
            out.append(m.group('tok'))
        i = m.end()
    return out


class Reader:
    def __init__(self, text):
        self.toks, self.i = tokenize(text), 0

    def look(self, k=0):
        return self.toks[self.i + k] if self.i + k < len(self.toks) else None

    def error(self):
        t = self.look()
        raise Error('syntax error at ' + ("end of input" if t is None else f"'{t}'"))

    def expect(self, t):
        if self.look() != t:
            self.error()
        self.i += 1

    def name(self):
        t = self.look()
        if t is None or not t[0].isalpha() or t in KEYWORDS:
            self.error()
        self.i += 1
        return t

    def program(self):
        """(definitions as a dict name -> term, None): the value is main."""
        clauses, last = {}, None                      # name -> [(patterns, body)]
        while True:
            self.expect('fun')
            f = self.name()
            pats = []
            while self.look() != '=':
                pats.append(self.pattern())
            self.i += 1
            body = self.expr()
            if f in clauses and (f != last or not pats):
                raise Error(f + ' is defined twice')
            if f in clauses and len(pats) != len(clauses[f][0][0]):
                raise Error('the clauses of ' + f + ' have different numbers of patterns')
            names = []
            for p in pats:
                names += variables(p)
            for x in names:
                if names.count(x) > 1:
                    raise Error(x + ' appears twice in a clause of ' + f)
            clauses.setdefault(f, []).append((pats, body))
            last = f
            if self.look() is None:
                break
            self.expect(';')
            if self.look() is None:
                break
        defs = {f: match(f, c) for f, c in clauses.items()}
        for x, t in BUILTINS.items():
            defs.setdefault(x, t)
        return defs, None

    def pattern(self):
        """A pattern: ('var', x), ('any',), ('num', n), ('nil',) or ('cons', p, q)."""
        t = self.look()
        if t == '(':
            self.i += 1
            p = self.cons_pattern()
            self.expect(')')
            return p
        if t == '_':
            self.i += 1
            return ('any',)
        if t == '-' and self.look(1) is not None and self.look(1).isdigit():
            self.i += 1
            return ('num', self.number(negative=True))
        if t is not None and t.isdigit():
            return ('num', self.number())
        if t in ('true', 'false'):
            self.i += 1
            return ('num', 1 if t == 'true' else 0)
        if t == 'nil':
            self.i += 1
            return ('nil',)
        return ('var', self.name())

    def cons_pattern(self):
        p = self.pattern()
        if self.look() == ':':                        # h : t, a : b : rest
            self.i += 1
            p = ('cons', p, self.cons_pattern())
        return p

    def expr(self):
        t = self.look()
        if t == '\\':
            self.i += 1
            params = [self.name()]
            while self.look() != '->':
                params.append(self.name())
            self.i += 1
            body = self.expr()
            for x in reversed(params):
                body = Lam(x, body)
            return body
        if t == 'if':
            self.i += 1
            c = self.expr()
            self.expect('then')
            a = self.expr()
            self.expect('else')
            return App(App(App('IF', c), a), self.expr())
        a = self.cons()
        if self.look() in COMPARE:
            op = self.look()
            self.i += 1
            a = binary(op, a, self.cons())
        return a

    def cons(self):
        a = self.sum()
        if self.look() == ':':
            self.i += 1
            a = binary(':', a, self.cons())
        return a

    def sum(self):
        if self.look() == '-':                        # unary minus
            self.i += 1
            if self.look() is not None and self.look().isdigit():
                a = self.product_rest(self.number(negative=True))
            else:
                a = App(App('-', 0), self.product())
        else:
            a = self.product()
        while self.look() in ('+', '-'):
            op = self.look()
            self.i += 1
            a = binary(op, a, self.product())
        return a

    def product(self):
        return self.product_rest(self.app())

    def product_rest(self, a):
        while self.look() in ('*', '/', '%'):
            op = self.look()
            self.i += 1
            a = binary(op, a, self.app())
        return a

    def app(self):
        a = self.atom()
        while self.starts_atom():
            a = App(a, self.atom())
        return a

    def starts_atom(self):
        t = self.look()
        return t is not None and (t[0].isalnum() or t in ('(', '\\')) and \
            t not in ('then', 'else', 'fun')

    def number(self, negative=False):
        n = int(self.look()) & 0xFFFF
        self.i += 1
        return wrap(-n if negative else n)

    def atom(self):
        t = self.look()
        if t is None:
            self.error()
        if t in ('\\', 'if'):
            return self.expr()
        if t == '(':
            if self.look(1) in OPERATORS and self.look(2) == ')':
                self.i += 3
                return section(self.toks[self.i - 2])
            self.i += 1
            a = self.expr()
            self.expect(')')
            return a
        if t.isdigit():
            return self.number()
        if t == 'true':
            self.i += 1
            return 1
        if t == 'false':
            self.i += 1
            return 0
        if t == 'nil':
            self.i += 1
            return Var('nil')
        return Var(self.name())


# ---------------------------------------------------------------------------
# Pattern matching
# ---------------------------------------------------------------------------
# match() first checks the clauses with useful() (Maranget's algorithm): each
# clause must match some argument that the clauses above it do not, and some
# clause must match every argument. It then compiles them with Wadler's
# algorithm. A row is (patterns, renaming, k): the patterns still to match,
# the pattern variables bound so far (name -> the fresh variable holding the
# value), and the number of the clause. Matching starts with one row per
# clause and one fresh variable per parameter, and takes a column at a time.

ANY = ('any',)


def variables(p):
    if p[0] == 'var':
        return [p[1]]
    if p[0] == 'cons':
        return variables(p[1]) + variables(p[2])
    return []


def useful(f, rows, q):
    """Whether some argument matches the patterns q but none of the rows."""
    if not q:
        return not rows
    heads = [r[0] for r in rows if r[0][0] not in ('var', 'any')]
    kinds = {p[0] == 'num' for p in heads + [q[0]] if p[0] not in ('var', 'any')}
    if len(kinds) > 1:
        raise Error('the patterns of ' + f + ' mix numbers and lists')
    if q[0][0] not in ('var', 'any'):
        return useful(f, specialize(rows, q[0]), specialize([q], q[0])[0])
    tags = {p[0] for p in heads}
    if tags == {'nil', 'cons'}:                       # every list is covered
        return any(useful(f, specialize(rows, c), specialize([q], c)[0])
                   for c in (('nil',), ('cons', ANY, ANY)))
    return useful(f, [r[1:] for r in rows if r[0][0] in ('var', 'any')], q[1:])


def specialize(rows, c):
    """The rows that can match constructor c in the first column, with the
    first pattern replaced by c's fields."""
    out = []
    for r in rows:
        p = r[0]
        if p[0] in ('var', 'any'):
            out.append([ANY] * (2 if c[0] == 'cons' else 0) + r[1:])
        elif p[0] == 'cons' == c[0]:
            out.append([p[1], p[2]] + r[1:])
        elif p[0] == c[0] and (p[0] != 'num' or p[1] == c[1]):
            out.append(r[1:])
    return out


def match(f, clauses):
    """The clauses of f, [(patterns, body)], as one term."""
    for k, (ps, _) in enumerate(clauses):
        if not useful(f, [c[0] for c in clauses[:k]], ps):
            raise Error(f'clause {k + 1} of {f} can never be used')
    if useful(f, [c[0] for c in clauses], [ANY] * len(clauses[0][0])):
        raise Error('the clauses of ' + f + ' do not cover every case')
    count = [0]

    def fresh():
        count[0] += 1
        return f' u{count[0]}'

    def rows_body(rows, us, dflt):
        if not us:                                    # the first row matches
            if not rows:
                return dflt
            _, names, k = rows[0]
            return subst(clauses[k][1], {x: Var(u) for x, u in names.items()})
        groups = []                                   # runs of variables and of constructors
        for r in rows:
            var = r[0][0][0] in ('var', 'any')
            if groups and groups[-1][0] == var:
                groups[-1][1].append(r)
            else:
                groups.append((var, [r]))
        e = dflt
        for var, g in reversed(groups):               # each run falls through to the next
            if isinstance(e, (App, Lam)):
                d = fresh()
                inner = column(var, g, us, Var(d))
                if uses(inner, d) <= 1:
                    e = subst(inner, {d: e})
                else:
                    e = App(Lam(d, inner), e)         # shared, evaluated at most once
            else:
                e = column(var, g, us, e)
        return e

    def column(var, rows, us, dflt):
        u, rest = us[0], us[1:]
        if var:
            return rows_body([(ps[1:], dict(names, **({ps[0][1]: u} if ps[0][0] == 'var' else {})), k)
                              for ps, names, k in rows], rest, dflt)
        if rows[0][0][0][0] == 'num':                    # if u = n1 then ... else if u = n2 ...
            nums = []
            for ps, _, _ in rows:
                if ps[0][1] not in nums:
                    nums.append(ps[0][1])
            e = dflt
            for n in reversed(nums):
                same = [(ps[1:], names, k) for ps, names, k in rows if ps[0][1] == n]
                e = App(App(App('IF', binary('=', Var(u), n)), rows_body(same, rest, dflt)), e)
            return e
        h, t = fresh(), fresh()                       # u (\h t -> ...) (...)
        conses = [([ps[0][1], ps[0][2]] + ps[1:], names, k) for ps, names, k in rows if ps[0][0] == 'cons']
        nils = [(ps[1:], names, k) for ps, names, k in rows if ps[0][0] == 'nil']
        return App(App(Var(u), Lam(h, Lam(t, rows_body(conses, [h, t] + rest, dflt)))),
                   rows_body(nils, rest, dflt))

    us = [fresh() for _ in clauses[0][0]]
    e = rows_body([(ps, {}, k) for k, (ps, _) in enumerate(clauses)], us, 0)
    for u in reversed(us):                            # 0 above is never reached
        e = Lam(u, e)
    return e


def subst(e, m):
    """e with each free Var x in m replaced by m[x]."""
    if isinstance(e, Var):
        return m.get(e.x, e)
    if isinstance(e, App):
        return App(subst(e.f, m), subst(e.a, m))
    if isinstance(e, Lam):
        if e.x in m:
            m = {x: v for x, v in m.items() if x != e.x}
        return Lam(e.x, subst(e.body, m))
    return e


def uses(e, x):
    """How many times the variable x occurs free in e."""
    if isinstance(e, Var):
        return e.x == x
    if isinstance(e, App):
        return uses(e.f, x) + uses(e.a, x)
    if isinstance(e, Lam):
        return 0 if e.x == x else uses(e.body, x)
    return 0
