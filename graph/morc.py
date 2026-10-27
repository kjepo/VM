"""morc.py - the reader for MORC, the Mora Recursive Calculator.

A MORC program is a series of definitions; its value is main:

    fn fac n = if n = 0 then 1 else n * fac (n - 1);
    fn main = fac 7;

Grammar (the usual precedences, loosest first):

    program    ::= definition { definition }
    definition ::= "fn" IDENT { IDENT } "=" expr ";"     (the last ; may be left out)
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
"""
import re

from prototype import App, COMPARE, Error, Lam, Var, binary, section, wrap

KEYWORDS = ('fn', 'if', 'then', 'else', 'true', 'false', 'nil')
OPERATORS = ('+', '-', '*', '/', '%', ':') + COMPARE
TOKEN = re.compile(r'\s+|#[^\n]*|(?P<tok>[A-Za-z][A-Za-z0-9_]*|\d+|->|==|!=|<=|>=|[-+*/%=<>:;()\\])')

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
        defs = {}
        while True:
            self.expect('fn')
            f = self.name()
            params = []
            while self.look() != '=':
                params.append(self.name())
            self.i += 1
            body = self.expr()
            for x in reversed(params):
                body = Lam(x, body)
            if f in defs:
                raise Error(f + ' is defined twice')
            defs[f] = body
            if self.look() is None:
                break
            self.expect(';')
            if self.look() is None:
                break
        for x, t in BUILTINS.items():
            defs.setdefault(x, t)
        return defs, None

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
            t not in ('then', 'else', 'fn')

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
