#!/usr/bin/env python3
"""mex.py - a reference interpreter for Mex (see mex-spec.tex).

    python3 mex.py prog.mx < input       check prog.mx, then run it
    python3 mex.py -c prog.mx            only check it

The program is checked as the spec requires and turned into a tree of Python
closures, which runs the way compiled code would: the locals of a call live in
a frame of slots, a function made by fun keeps the values of the outer locals
it uses, and return f(...) is a tail call. A compile error is printed as
line:col: message on standard output, as mxparse.mx prints it, and a run-time
error on standard error; both exit with status 1.
"""
import sys

BUILTINS = ["hd", "tl", "sethd", "settl", "intern", "name", "keys", "size",
            "type", "getc", "putc", "putw", "print", "error", "exit"]
KEYWORDS = {"fun", "var", "if", "else", "while", "return", "break", "continue",
            "nil", "true", "false"}
CMPS = {"==", "!=", "<", "<=", ">", ">="}
ONES = set("(){}[],;:.=<>+-*/%!")
ESCAPES = {ord("n"): 10, ord("t"): 9, ord("r"): 13, ord("0"): 0, ord("\\"): 92,
           ord("'"): 39, ord('"'): 34}


class CompileError(Exception):
    def __init__(self, line, col, msg):
        self.line, self.col, self.msg = line, col, msg


def quote(s):
    """The symbol s as a literal."""
    out = '"'
    for c in s:
        n = ord(c)
        if c in '"\\':
            out += "\\" + c
        elif c == "\n":
            out += "\\n"
        elif c == "\t":
            out += "\\t"
        elif n < 32 or n > 126:
            out += "\\x%02x" % n
        else:
            out += c
    return out + '"'


# ---------------------------------------------------------------------------
# Values: nil is None, an integer an int, a symbol a str (so == on two symbols
# compares names, which is what interning gives), and the rest are below.

class Pair:
    __slots__ = ("hd", "tl")

    def __init__(self, hd, tl):
        self.hd, self.tl = hd, tl


class Table:
    __slots__ = ("d",)

    def __init__(self):
        self.d = {}


class Proto:
    """The compiled code of a function."""
    __slots__ = ("nparams", "nslots", "body")


class Fun:
    __slots__ = ("proto", "env")

    def __init__(self, proto, env):
        self.proto, self.env = proto, env


class Builtin:
    __slots__ = ("name", "n", "f")

    def __init__(self, name, n, f):
        self.name, self.n, self.f = name, n, f


class Ret:
    __slots__ = ("v",)

    def __init__(self, v):
        self.v = v


class TailCall:
    __slots__ = ("f", "args")

    def __init__(self, f, args):
        self.f, self.args = f, args


BREAK, CONTINUE = object(), object()


def rterr(msg):
    sys.stdout.flush()
    print("mex: run-time error: " + msg, file=sys.stderr)
    sys.exit(1)


def wrap(n):
    n &= 0x7FFF
    return n - 0x8000 if n & 0x4000 else n


def typename(v):
    if v is None:
        return "nil"
    if type(v) is int:
        return "int"
    if type(v) is str:
        return "sym"
    if type(v) is Pair:
        return "pair"
    if type(v) is Table:
        return "table"
    return "fun"


def ints(x, y, op):
    if type(x) is not int or type(y) is not int:
        rterr(op + " needs two integers, not " + typename(x) + " and " + typename(y))


def op_add(x, y):
    ints(x, y, "+")
    return wrap(x + y)


def op_sub(x, y):
    ints(x, y, "-")
    return wrap(x - y)


def op_mul(x, y):
    ints(x, y, "*")
    return wrap(x * y)


def quotient(x, y, op):
    ints(x, y, op)
    if y == 0:
        rterr("division by zero")
    q = abs(x) // abs(y)
    return q if (x < 0) == (y < 0) else -q


def op_div(x, y):
    return wrap(quotient(x, y, "/"))


def op_mod(x, y):
    return wrap(x - y * quotient(x, y, "%"))


def same(x, y):
    if type(x) is int and type(y) is int or type(x) is str and type(y) is str:
        return x == y
    return x is y


def comparison(op, test):
    def f(x, y):
        if type(x) is int and type(y) is int or type(x) is str and type(y) is str:
            return "true" if test(x, y) else None
        rterr(op + " needs two integers or two symbols")
    return f


OPS = {"+": op_add, "-": op_sub, "*": op_mul, "/": op_div, "%": op_mod,
       "==": lambda x, y: "true" if same(x, y) else None,
       "!=": lambda x, y: None if same(x, y) else "true",
       "<": comparison("<", lambda x, y: x < y),
       "<=": comparison("<=", lambda x, y: x <= y),
       ">": comparison(">", lambda x, y: x > y),
       ">=": comparison(">=", lambda x, y: x >= y)}


def call(f, args):
    while True:
        if type(f) is Builtin:
            if len(args) != f.n:
                rterr(f.name + " takes " + str(f.n) + " arguments, not " + str(len(args)))
            return f.f(*args)
        if type(f) is not Fun:
            rterr("calling a " + typename(f) + ", not a function")
        p = f.proto
        if len(args) != p.nparams:
            rterr("a function of " + str(p.nparams) + " parameters called with "
                  + str(len(args)) + " arguments")
        frame = args + [None] * (p.nslots - p.nparams)
        r = p.body(frame, f.env)
        if type(r) is TailCall:
            f, args = r.f, r.args
        elif type(r) is Ret:
            return r.v
        else:
            return None


# ---------------------------------------------------------------------------
# Built-in functions

def need(v, t, what):
    if type(v) is not t:
        rterr(what + " needs a " + {Pair: "pair", Table: "table", str: "symbol",
                                    int: "integer"}[t] + ", not " + typename(v))


def b_hd(p):
    need(p, Pair, "hd")
    return p.hd


def b_tl(p):
    need(p, Pair, "tl")
    return p.tl


def b_sethd(p, v):
    need(p, Pair, "sethd")
    p.hd = v


def b_settl(p, v):
    need(p, Pair, "settl")
    p.tl = v


def b_intern(l):
    cs = []
    while l is not None:
        need(l, Pair, "intern")
        if type(l.hd) is not int or not 0 <= l.hd <= 255:
            rterr("intern needs a list of character codes")
        cs.append(chr(l.hd))
        l = l.tl
    return "".join(cs)


def mklist(items):
    l = None
    for x in reversed(items):
        l = Pair(x, l)
    return l


def b_name(s):
    need(s, str, "name")
    return mklist([ord(c) for c in s])


def b_keys(t):
    need(t, Table, "keys")
    return mklist(list(t.d))


def b_size(t):
    need(t, Table, "size")
    return len(t.d)


out = sys.stdout.buffer


def b_getc():
    b = sys.stdin.buffer.read(1)
    return b[0] if b else -1


def b_putc(c):
    need(c, int, "putc")
    out.write(bytes([c % 256]))


def b_putw(n):
    need(n, int, "putw")
    n %= 0x8000
    out.write(bytes([n & 0xFF, n >> 8]))


def b_print(v):
    if type(v) is int:
        out.write(str(v).encode())
    elif type(v) is str:
        out.write(v.encode("latin-1"))
    else:
        rterr("print needs an integer or a symbol, not " + typename(v))


def b_error(s):
    need(s, str, "error")
    out.flush()
    sys.stderr.write(s + "\n")
    sys.exit(1)


def b_exit(n):
    need(n, int, "exit")
    out.flush()
    sys.exit(n)


BUILTIN_FUNS = {"hd": b_hd, "tl": b_tl, "sethd": b_sethd, "settl": b_settl,
                "intern": b_intern, "name": b_name, "keys": b_keys, "size": b_size,
                "type": typename, "getc": b_getc, "putc": b_putc, "putw": b_putw,
                "print": b_print, "error": b_error, "exit": b_exit}
BUILTIN_ARITY = {"getc": 0, "sethd": 2, "settl": 2}

# ---------------------------------------------------------------------------
# Scanner, the same as mxparse.mx's


class Scanner:
    def __init__(self, src):
        self.src, self.pos = src, 0
        self.ch, self.line, self.col = 0, 1, 0
        self.tok, self.val, self.tline, self.tcol = None, None, 1, 1
        self.nextch()

    def error(self, msg):
        raise CompileError(self.tline, self.tcol, msg)

    def nextch(self):
        if self.ch == 10:
            self.line += 1
            self.col = 0
        if self.pos < len(self.src):
            self.ch = self.src[self.pos]
            self.pos += 1
        else:
            self.ch = -1
        self.col += 1

    def peek(self):
        return self.src[self.pos] if self.pos < len(self.src) else -1

    @staticmethod
    def is_letter(c):
        return 97 <= c <= 122 or 65 <= c <= 90 or c == 95

    @staticmethod
    def is_digit(c):
        return 48 <= c <= 57

    @staticmethod
    def hexval(c):
        if 48 <= c <= 57:
            return c - 48
        if 97 <= c <= 102:
            return c - 87
        if 65 <= c <= 70:
            return c - 55
        return -1

    def litchar(self):
        if self.ch == 92:
            self.nextch()
            e = ESCAPES.get(self.ch)
            if e is not None:
                self.nextch()
                return e
            if self.ch == ord("x"):
                self.nextch()
                h = self.hexval(self.ch)
                self.nextch()
                lo = self.hexval(self.ch)
                if h < 0 or lo < 0:
                    raise CompileError(self.line, self.col, "\\x needs two hexadecimal digits")
                self.nextch()
                return h * 16 + lo
            raise CompileError(self.line, self.col, "unknown escape")
        c = self.ch
        self.nextch()
        return c

    def scan(self):
        while self.ch in (32, 9, 10, 13) or self.ch == 47 and self.peek() == 47:
            if self.ch == 47:
                while self.ch != 10 and self.ch >= 0:
                    self.nextch()
            else:
                self.nextch()
        self.tline, self.tcol = self.line, self.col
        ch = self.ch
        if ch < 0:
            self.tok = "eof"
        elif self.is_letter(ch):
            s = ""
            while self.is_letter(self.ch) or self.is_digit(self.ch):
                s += chr(self.ch)
                self.nextch()
            if s in KEYWORDS:
                self.tok = s
            else:
                self.tok, self.val = "name", s
        elif self.is_digit(ch):
            n = 0
            if ch == 48 and self.peek() in (120, 88):
                self.nextch()
                self.nextch()
                if self.hexval(self.ch) < 0:
                    raise CompileError(self.line, self.col, "expected a hexadecimal digit")
                while self.hexval(self.ch) >= 0:
                    n = n * 16 + self.hexval(self.ch)
                    if n > 0x7FFF:
                        self.error("number too large")
                    self.nextch()
            else:
                while self.is_digit(self.ch):
                    n = n * 10 + self.ch - 48
                    if n > 0x7FFF:
                        self.error("number too large")
                    self.nextch()
            if self.is_letter(self.ch) or self.is_digit(self.ch):
                raise CompileError(self.line, self.col, "bad number")
            self.tok, self.val = "int", wrap(n)
        elif ch == 39:
            self.nextch()
            if self.ch in (39, 10) or self.ch < 0:
                self.error("empty character")
            self.val = self.litchar()
            if self.ch != 39:
                self.error("a character literal holds one character")
            self.nextch()
            self.tok = "int"
        elif ch == 34:
            self.nextch()
            s = ""
            while self.ch != 34:
                if self.ch == 10 or self.ch < 0:
                    self.error("unterminated symbol")
                s += chr(self.litchar())
            self.nextch()
            self.tok, self.val = "sym", s
        elif self.peek() == 61 and chr(ch) in "=!<>":
            self.tok = chr(ch) + "="
            self.nextch()
            self.nextch()
        elif ch in (38, 124) and self.peek() == ch:
            self.tok = chr(ch) * 2
            self.nextch()
            self.nextch()
        elif chr(ch) in ONES:
            self.tok = chr(ch)
            self.nextch()
        else:
            self.error("unexpected character '" + chr(ch) + "'")

    def describe(self):
        if self.tok == "name":
            return "name " + self.val
        if self.tok == "int":
            return "number " + str(self.val)
        if self.tok == "sym":
            return "symbol " + quote(self.val)
        if self.tok == "eof":
            return "end of input"
        return "'" + self.tok + "'"

    def expect(self, t):
        if self.tok != t:
            self.error("expected '" + t + "', found " + self.describe())
        self.scan()

    def getname(self):
        if self.tok != "name":
            self.error("expected a name, found " + self.describe())
        s = self.val
        self.nline, self.ncol = self.tline, self.tcol
        self.scan()
        return s


# ---------------------------------------------------------------------------
# Parser and compiler to closures. Each function being compiled has a Ctx;
# the checks and their order are those of mxparse.mx.

class Info:
    __slots__ = ("name", "slot", "captured", "assigned")

    def __init__(self, name, slot):
        self.name, self.slot = name, slot
        self.captured = self.assigned = False


class Ctx:
    def __init__(self, parent):
        self.parent = parent
        self.locals = []                # Info, innermost last
        self.scope = 0                  # where the innermost scope starts
        self.nloc = self.maxloc = 0
        self.caps = {}                  # name -> index of a captured value
        self.capnames = []
        self.loops = 0


class Compiler(Scanner):
    def __init__(self, src):
        super().__init__(src)
        self.gslot = {}                 # name -> (line, col) of its first use
        self.gdecl = {}                 # name -> "builtin", "fun" or "var"
        self.gvals = {}
        self.funs = []                  # (name, Proto)
        self.inits = []                 # compiled initialisers of globals
        self.pend = None
        self.lastcall = None
        self.cx = None

    # names

    def addlocal(self, s, line, col):
        cx = self.cx
        if s in BUILTIN_FUNS:
            raise CompileError(line, col, s + " is a built-in function")
        for v in cx.locals[cx.scope:]:
            if v.name == s:
                raise CompileError(line, col, s + " is already declared in this scope")
        v = Info(s, cx.nloc)
        cx.locals.append(v)
        cx.nloc += 1
        cx.maxloc = max(cx.maxloc, cx.nloc)
        return v

    @staticmethod
    def findlocal(c, s):
        for v in reversed(c.locals):
            if v.name == s:
                return v
        return None

    def capture(self, c, s):
        if s in c.caps:
            return c.caps[s]
        if c.parent is None:
            return None
        v = self.findlocal(c.parent, s)
        if v is not None:
            if v.assigned:
                self.error(s + " is assigned, so it cannot be captured")
            v.captured = True
        elif self.capture(c.parent, s) is None:
            return None
        i = len(c.capnames)
        c.caps[s] = i
        c.capnames.append(s)
        return i

    def gref(self, s):
        if s not in self.gslot:
            self.gslot[s] = (self.tline, self.tcol)

    def resolve(self, s):
        """A getter for the variable s, which is left pending."""
        v = self.findlocal(self.cx, s)
        if v is not None:
            i = v.slot
            self.pend = ("local", i, s, self.tline, self.tcol)
            return lambda fr, en: fr[i]
        i = self.capture(self.cx, s)
        if i is not None:
            self.pend = ("cap", i, s, self.tline, self.tcol)
            return lambda fr, en: en[i]
        self.gref(s)
        self.pend = ("global", 0, s, self.tline, self.tcol)
        g = self.gvals
        return lambda fr, en: g.get(s)

    def flush(self):
        self.pend = None

    # expressions

    def expr(self):
        a = self.andexpr()
        while self.tok == "||":
            self.flush()
            self.scan()
            b = self.andexpr()
            self.flush()
            a = (lambda a, b: lambda fr, en: (lambda v: b(fr, en) if v is None else v)(a(fr, en)))(a, b)
        return a

    def andexpr(self):
        a = self.compare()
        while self.tok == "&&":
            self.flush()
            self.scan()
            b = self.compare()
            self.flush()
            a = (lambda a, b: lambda fr, en: None if a(fr, en) is None else b(fr, en))(a, b)
        return a

    def compare(self):
        a = self.consexpr()
        if self.tok in CMPS:
            f = OPS[self.tok]
            self.flush()
            self.scan()
            b = self.consexpr()
            self.flush()
            if self.tok in CMPS:
                self.error("comparisons do not chain")
            return lambda fr, en: f(a(fr, en), b(fr, en))
        return a

    def consexpr(self):
        a = self.sumexpr()
        if self.tok == ":":
            self.flush()
            self.scan()
            b = self.consexpr()
            self.flush()
            return lambda fr, en: Pair(a(fr, en), b(fr, en))
        return a

    def binary(self, ops, operand):
        a = operand()
        while self.tok in ops:
            f = OPS[self.tok]
            self.flush()
            self.scan()
            b = operand()
            self.flush()
            a = (lambda f, a, b: lambda fr, en: f(a(fr, en), b(fr, en)))(f, a, b)
        return a

    def sumexpr(self):
        return self.binary(("+", "-"), self.product)

    def product(self):
        return self.binary(("*", "/", "%"), self.unary)

    def unary(self):
        if self.tok == "-":
            self.scan()
            a = self.unary()
            self.flush()

            def neg(fr, en):
                v = a(fr, en)
                if type(v) is not int:
                    rterr("- needs an integer, not " + typename(v))
                return wrap(-v)
            return neg
        if self.tok == "!":
            self.scan()
            a = self.unary()
            self.flush()
            return lambda fr, en: "true" if a(fr, en) is None else None
        return self.postfix()

    def postfix(self):
        a = self.primary()
        while True:
            if self.tok == "(":
                self.flush()
                self.scan()
                args = []
                if self.tok != ")":
                    args.append(self.expr())
                    self.flush()
                    while self.tok == ",":
                        self.scan()
                        args.append(self.expr())
                        self.flush()
                self.expect(")")
                a = self.callnode(a, args)
            elif self.tok == "[":
                self.flush()
                self.scan()
                k = self.expr()
                self.flush()
                self.expect("]")
                a = self.indexnode(a, k)
            elif self.tok == ".":
                self.flush()
                self.scan()
                s = self.getname()
                a = self.indexnode(a, lambda fr, en: s)
            else:
                return a

    def callnode(self, f, args):
        def node(fr, en):
            return call(f(fr, en), [x(fr, en) for x in args])
        self.lastcall = (node, f, args)
        return node

    def indexnode(self, t, k):
        self.pend = ("index", t, k, self.tline, self.tcol)

        def node(fr, en):
            tv = t(fr, en)
            need(tv, Table, "indexing")
            return tv.d.get(key(k(fr, en)))
        return node

    def primary(self):
        tok = self.tok
        if tok == "name":
            g = self.resolve(self.val)
            self.scan()
            return g
        if tok in ("int", "sym"):
            v = self.val
            self.scan()
            return lambda fr, en: v
        if tok in ("nil", "false"):
            self.scan()
            return lambda fr, en: None
        if tok == "true":
            self.scan()
            return lambda fr, en: "true"
        if tok == "(":
            self.scan()
            a = self.expr()
            self.flush()
            self.expect(")")
            return a
        if tok == "{":
            return self.tablexpr()
        if tok == "[":
            return self.listexpr()
        if tok == "fun":
            self.scan()
            return self.lambdaexpr()
        self.error("expected an expression, found " + self.describe())

    def tablexpr(self):
        self.scan()
        entries = []
        if self.tok != "}":
            entries.append(self.entry())
            while self.tok == ",":
                self.scan()
                entries.append(self.entry())
        self.expect("}")

        def node(fr, en):
            t = Table()
            for k, v in entries:
                x = v(fr, en)
                if x is None:
                    t.d.pop(k, None)
                else:
                    t.d[k] = x
            return t
        return node

    def entry(self):
        if self.tok not in ("name", "sym", "int"):
            self.error("expected a key, found " + self.describe())
        k = self.val
        self.scan()
        self.expect(":")
        v = self.expr()
        self.flush()
        return k, v

    def listexpr(self):
        self.scan()
        items = []
        if self.tok != "]":
            items.append(self.expr())
            self.flush()
            while self.tok == ",":
                self.scan()
                items.append(self.expr())
                self.flush()
        self.expect("]")
        return lambda fr, en: mklist([x(fr, en) for x in items])

    def lambdaexpr(self):
        outer = self.cx
        self.cx = Ctx(outer)
        p = self.funbody()
        names = self.cx.capnames
        self.cx = outer
        getters = []
        for s in names:
            getters.append(self.resolve(s))
            self.flush()
        return lambda fr, en: Fun(p, [g(fr, en) for g in getters])

    def funbody(self):
        """function ::= "(" [ params ] ")" block"""
        self.expect("(")
        if self.tok != ")":
            s = self.getname()
            self.addlocal(s, self.nline, self.ncol)
            while self.tok == ",":
                self.scan()
                s = self.getname()
                self.addlocal(s, self.nline, self.ncol)
        p = Proto()
        p.nparams = self.cx.nloc
        self.expect(")")
        p.body = self.block(False)
        p.nslots = self.cx.maxloc
        return p

    # statements

    def block(self, newscope):
        cx = self.cx
        saved = (len(cx.locals), cx.scope, cx.nloc)
        if newscope:
            cx.scope = len(cx.locals)
        self.expect("{")
        stmts = []
        while self.tok != "}":
            if self.tok == "eof":
                self.expect("}")
            stmts.append(self.stmt())
        self.scan()
        if newscope:
            del cx.locals[saved[0]:]
            cx.scope, cx.nloc = saved[1], saved[2]

        def run(fr, en):
            for s in stmts:
                r = s(fr, en)
                if r is not None:
                    return r
            return None
        return run

    def stmt(self):
        tok = self.tok
        if tok == "var":
            self.scan()
            s = self.getname()
            line, col = self.nline, self.ncol
            if self.tok == "=":
                self.scan()
                e = self.expr()
                self.flush()
            else:
                e = lambda fr, en: None
            i = self.addlocal(s, line, col).slot
            self.expect(";")

            def setl(fr, en):
                fr[i] = e(fr, en)
            return setl
        if tok == "{":
            return self.block(True)
        if tok == "if":
            return self.ifstmt()
        if tok == "while":
            self.scan()
            c = self.condition()
            self.cx.loops += 1
            body = self.block(True)
            self.cx.loops -= 1

            def loop(fr, en):
                while c(fr, en) is not None:
                    r = body(fr, en)
                    if r is BREAK:
                        break
                    if r is not None and r is not CONTINUE:
                        return r
                return None
            return loop
        if tok == "return":
            self.scan()
            if self.tok == ";":
                self.scan()
                return lambda fr, en: Ret(None)
            e = self.expr()
            self.flush()
            self.expect(";")
            if self.lastcall is not None and self.lastcall[0] is e:
                _, f, args = self.lastcall
                return lambda fr, en: TailCall(f(fr, en), [x(fr, en) for x in args])
            return lambda fr, en: Ret(e(fr, en))
        if tok in ("break", "continue"):
            if self.cx.loops == 0:
                self.error(tok + " outside a loop")
            self.scan()
            self.expect(";")
            r = BREAK if tok == "break" else CONTINUE
            return lambda fr, en: r
        return self.assignment()

    def condition(self):
        self.expect("(")
        c = self.expr()
        self.flush()
        self.expect(")")
        return c

    def ifstmt(self):
        self.scan()
        c = self.condition()
        a = self.block(True)
        b = None
        if self.tok == "else":
            self.scan()
            if self.tok == "if":
                b = self.ifstmt()
            elif self.tok == "{":
                b = self.block(True)
            else:
                self.error("expected '{' or 'if' after else, found " + self.describe())
        if b is None:
            return lambda fr, en: a(fr, en) if c(fr, en) is not None else None
        return lambda fr, en: a(fr, en) if c(fr, en) is not None else b(fr, en)

    def assignment(self):
        e = self.expr()
        if self.tok == "=":
            if self.pend is None:
                self.error("cannot assign to this expression")
            kind, slot, s, line, col = self.pend
            self.pend = None
            if kind == "global" and self.gdecl.get(s) == "builtin":
                raise CompileError(line, col, "cannot assign to the built-in function " + s)
            if kind == "cap":
                raise CompileError(line, col, s + " is captured, so it cannot be assigned")
            if kind == "local":
                v = self.findlocal(self.cx, s)
                if v.captured:
                    raise CompileError(line, col, s + " is captured, so it cannot be assigned")
                v.assigned = True
            self.scan()
            r = self.expr()
            self.flush()
            self.expect(";")
            if kind == "local":
                def setl(fr, en):
                    fr[slot] = r(fr, en)
                return setl
            if kind == "global":
                g = self.gvals

                def setg(fr, en):
                    g[s] = r(fr, en)
                return setg
            t, k = slot, s

            def store(fr, en):
                tv = t(fr, en)
                need(tv, Table, "indexing")
                kv = key(k(fr, en))
                v = r(fr, en)
                if v is None:
                    tv.d.pop(kv, None)
                else:
                    tv.d[kv] = v
            return store
        self.flush()
        self.expect(";")

        def pop(fr, en):
            e(fr, en)
        return pop

    # program

    def declare(self, s, kind, line, col):
        if self.gdecl.get(s) == "builtin":
            raise CompileError(line, col, s + " is a built-in function")
        if s in self.gdecl:
            raise CompileError(line, col, s + " is already declared")
        self.gdecl[s] = kind
        self.gref(s)

    def program(self):
        for s in BUILTINS:
            self.gdecl[s] = "builtin"
            self.gref(s)
            self.gvals[s] = Builtin(s, BUILTIN_ARITY.get(s, 1), BUILTIN_FUNS[s])
        initctx = Ctx(None)
        self.scan()
        while self.tok != "eof":
            if self.tok == "fun":
                self.scan()
                s = self.getname()
                line, col = self.nline, self.ncol
                self.declare(s, "fun", line, col)
                self.cx = Ctx(None)
                p = self.funbody()
                if s == "main" and p.nparams != 0:
                    raise CompileError(line, col, "main must have no parameters")
                self.funs.append((s, p))
            elif self.tok == "var":
                self.scan()
                s = self.getname()
                self.declare(s, "var", self.nline, self.ncol)
                if self.tok == "=":
                    self.cx = initctx
                    self.scan()
                    e = self.expr()
                    self.flush()
                    self.inits.append((s, e))
                self.expect(";")
            else:
                self.error("expected 'fun' or 'var', found " + self.describe())
        for s, (line, col) in self.gslot.items():
            if s not in self.gdecl:
                raise CompileError(line, col, s + " is not declared")
        if self.gdecl.get("main") != "fun":
            self.error("there is no function main")

    def run(self):
        for s, p in self.funs:
            self.gvals[s] = Fun(p, [])
        for s, e in self.inits:
            self.gvals[s] = e([], [])
        call(self.gvals["main"], [])


def key(k):
    if k is None:
        rterr("nil cannot be a key")
    return k


def main():
    args = sys.argv[1:]
    check = args[:1] == ["-c"]
    if check:
        args = args[1:]
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    with open(args[0], "rb") as f:
        c = Compiler(f.read())
    try:
        c.program()
    except CompileError as e:
        out.write(("%s:%s: %s\n" % (e.line, e.col, e.msg)).encode("latin-1"))
        return 1
    if not check:
        sys.setrecursionlimit(20000)
        c.run()
        out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
