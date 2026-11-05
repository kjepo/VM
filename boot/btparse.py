#!/usr/bin/env python3
"""btparse.py - the scanner and parser of Boot: one pass, no syntax tree.

    python3 btparse.py prog.bt        print the stack code the parser emits
    python3 btparse.py -q prog.bt     only check the program
    python3 btparse.py -t prog.bt     print the tokens

This is the front end of btc.py, written as boot-spec.tex asks btc.py to be
written: one pass, no syntax tree, only integers, strings, dictionaries and
global variables, so that it can be translated into Boot almost line by line
(d.get(k) is Boot's d[k], and a dictionary with keys 0..n-1 is a list).
Where btc.py will emit VM16 code, this file emits a line of stack code:

    int n, str "s", nil       push a constant
    getl i x, setl i x        get or set local slot i (named x)
    getg i x, setg i x        get or set global slot i; globals are numbered
                              in order of first use, the built-ins first
    func f                    push the function f
    dict                      push a new, empty dictionary
    put                       d k v -> d, storing v under k
    index                     d k -> d[k]
    store                     d k v -> (nothing), storing v under k
    call n                    f a1 .. an -> the result
    neg not + - * / % == != < <= > >=
    jf L, jt L, jmp L, L:     jump if false, if true, always; a label
    pop, ret, halt
    iter i                    d -> (nothing), starting to iterate over d in
                              the hidden slots i and i+1
    next i L                  push the next key, or jump to L at the end

Each function is printed when it ends, with its parameter and local slot
counts. Then comes init: the stores of every function into its slot, the
initialisers of the global variables in program order, and the call of main.

A variable's name becomes visible after its initialiser, so var x = x; in a
function initialises the local x with the global x. The parameters and the
outermost block of a function are one scope. for (k in d) declares k in a
scope of its own around the loop.
"""
import sys

BUILTINS = {"getc": 0, "putc": 1, "putw": 1, "print": 1, "len": 1, "str": 1,
            "chr": 1, "type": 1, "error": 1, "exit": 1}
KEYWORDS = {"fun": 1, "var": 1, "if": 1, "else": 1, "while": 1, "for": 1,
            "in": 1, "return": 1, "break": 1, "continue": 1, "nil": 1,
            "true": 1, "false": 1}
TWO = {"==": 1, "!=": 1, "<=": 1, ">=": 1, "&&": 1, "||": 1}
ONE = {"(": 1, ")": 1, "{": 1, "}": 1, "[": 1, "]": 1, ",": 1, ";": 1,
       ":": 1, ".": 1, "=": 1, "<": 1, ">": 1, "+": 1, "-": 1, "*": 1,
       "/": 1, "%": 1, "!": 1}
CMP = {"==": 1, "!=": 1, "<": 1, "<=": 1, ">": 1, ">=": 1}
ESCAPES = {"n": 10, "t": 9, "r": 13, "0": 0, "\\": 92, "'": 39, '"': 34}

fname = ""
quiet = False

# ---------------------------------------------------------------------------
# Errors and output

def error_at(line, col, msg):
    print(fname + ":" + str(line) + ":" + str(col) + ": " + msg, file=sys.stderr)
    sys.exit(1)


def error(msg):
    """An error at the current token."""
    error_at(tline, tcol, msg)


target = {}     # the code being written: a function's, or init's
labels = 0


def emit(s):
    target[len(target)] = "    " + s


def newlabel():
    global labels
    labels = labels + 1
    return labels


def label(n):
    target[len(target)] = "L" + str(n) + ":"


def show(code):
    if not quiet:
        i = 0
        while code.get(i) is not None:
            print(code[i])
            i = i + 1


def quote(s):
    """s as a string literal."""
    out = '"'
    i = 0
    while i < len(s):
        c = ord(s[i])
        if c == 34 or c == 92:
            out = out + "\\" + s[i]
        elif c == 10:
            out = out + "\\n"
        elif c == 9:
            out = out + "\\t"
        elif c < 32 or c > 126:
            out = out + "\\x" + "0123456789abcdef"[c // 16] + "0123456789abcdef"[c % 16]
        else:
            out = out + s[i]
        i = i + 1
    return out + '"'

# ---------------------------------------------------------------------------
# Scanner: ch is the current character (-1 at the end), and scan() reads the
# next token into tok (its kind), val, tline and tcol. The kind is "name",
# "int", "str", "eof", or the text of a keyword or an operator.

src = b""
pos = 0
ch = 0
line = 1
col = 0
tok = ""
val = 0
tline = 1
tcol = 1


def nextch():
    global ch, pos, line, col
    if ch == 10:
        line = line + 1
        col = 0
    if pos < len(src):
        ch = src[pos]
        pos = pos + 1
        col = col + 1
    else:
        ch = -1
        col = col + 1


def peek():
    if pos < len(src):
        return src[pos]
    return -1


def is_letter(c):
    return (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or c == 95


def is_digit(c):
    return c >= 48 and c <= 57


def hexval(c):
    """The value of the hexadecimal digit c, or -1."""
    if is_digit(c):
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    if c >= 65 and c <= 70:
        return c - 55
    return -1


def char():
    """One character or escape of a literal, as a byte."""
    if ch == 92:
        nextch()
        e = ESCAPES.get(chr(ch)) if ch >= 0 else None
        if e is not None:
            nextch()
            return e
        if ch == 120:
            nextch()
            h = hexval(ch)
            nextch()
            l = hexval(ch)
            if h < 0 or l < 0:
                error_at(line, col, "\\x needs two hexadecimal digits")
            nextch()
            return h * 16 + l
        error_at(line, col, "unknown escape")
    c = ch
    nextch()
    return c


def scan():
    global tok, val, tline, tcol
    while True:
        if ch == 32 or ch == 9 or ch == 10 or ch == 13:
            nextch()
        elif ch == 47 and peek() == 47:
            while ch != 10 and ch >= 0:
                nextch()
        else:
            break
    tline = line
    tcol = col
    if ch < 0:
        tok = "eof"
    elif is_letter(ch):
        s = ""
        while is_letter(ch) or is_digit(ch):
            s = s + chr(ch)
            nextch()
        if KEYWORDS.get(s):
            tok = s
        else:
            tok = "name"
            val = s
    elif is_digit(ch):
        n = 0
        if ch == 48 and (peek() == 120 or peek() == 88):
            nextch()
            nextch()
            if hexval(ch) < 0:
                error_at(line, col, "expected a hexadecimal digit")
            while hexval(ch) >= 0:
                n = n * 16 + hexval(ch)
                if n > 0x7FFF:
                    error("number too large")
                nextch()
        else:
            while is_digit(ch):
                n = n * 10 + ch - 48
                if n > 0x7FFF:
                    error("number too large")
                nextch()
        if is_letter(ch) or is_digit(ch):
            error_at(line, col, "bad number")
        if n >= 0x4000:                 # modulo 2^15, as a signed number
            n = n - 0x8000
        tok = "int"
        val = n
    elif ch == 39:
        nextch()
        if ch == 39 or ch == 10 or ch < 0:
            error("empty character")
        val = char()
        if ch != 39:
            error("a character literal holds one character")
        nextch()
        tok = "int"
    elif ch == 34:
        nextch()
        s = ""
        while ch != 34:
            if ch == 10 or ch < 0:
                error("unterminated string")
            s = s + chr(char())
        nextch()
        tok = "str"
        val = s
    else:
        two = chr(ch) + chr(peek()) if peek() >= 0 else ""
        if TWO.get(two):
            nextch()
            nextch()
            tok = two
        elif ONE.get(chr(ch)):
            tok = chr(ch)
            nextch()
        else:
            error("unexpected character " + quote(chr(ch)))


def describe():
    """The current token, for an error message."""
    if tok == "name":
        return "name " + val
    if tok == "int":
        return "number " + str(val)
    if tok == "str":
        return "string " + quote(val)
    if tok == "eof":
        return "end of input"
    return "'" + tok + "'"


def expect(t):
    if tok != t:
        error("expected '" + t + "', found " + describe())
    scan()


nline = 1           # the position of the name name() read last
ncol = 1


def name():
    """Read a name and return it."""
    global nline, ncol
    if tok != "name":
        error("expected a name, found " + describe())
    s = val
    nline = tline
    ncol = tcol
    scan()
    return s

# ---------------------------------------------------------------------------
# Names. The locals are a stack of slots, lname[i] being the name in slot i
# ("" for a hidden one); a block truncates it to its size at the start. The
# globals are numbered in order of first use.

lname = {}
nloc = 0            # the slots in use
maxloc = 0          # the most in use at once in this function
scopebase = 0       # the first slot of the innermost scope

gslot = {}          # name -> slot number
gdecl = {}          # name -> "fn", "var" or "builtin"
gline = {}          # name -> "line:col" of its first use
gparams = {}        # function name -> number of parameters
fnames = {}         # the functions, in program order


def addlocal(s):
    global nloc, maxloc
    if s != "":
        if BUILTINS.get(s) is not None:
            error_at(nline, ncol, s + " is a built-in function")
        i = scopebase
        while i < nloc:
            if lname[i] == s:
                error_at(nline, ncol, s + " is already declared in this scope")
            i = i + 1
    lname[nloc] = s
    nloc = nloc + 1
    if nloc > maxloc:
        maxloc = nloc
    return nloc - 1


def endscope(n):
    """Drop the slots from n up."""
    global nloc
    while nloc > n:
        nloc = nloc - 1
        del lname[nloc]


def lookup(s):
    """The slot of the local s, or -1."""
    i = nloc - 1
    while i >= 0:
        if lname[i] == s:
            return i
        i = i - 1
    return -1


def gref(s):
    """The slot of the global s."""
    if gslot.get(s) is None:
        gslot[s] = len(gslot)
        gline[s] = str(tline) + ":" + str(tcol)
    return gslot[s]

# ---------------------------------------------------------------------------
# Expressions. A name or an indexing step is left pending, not emitted, until
# the next token shows whether it is read or assigned: flush() emits it as a
# read, and an assignment statement turns it into a write.

pkind = ""          # "", "local", "global" or "index"
pslot = 0
pname = ""
pline = 1           # the position of the pending name
pcol = 1


def flush():
    global pkind
    if pkind == "local":
        emit("getl " + str(pslot) + " " + pname)
    elif pkind == "global":
        emit("getg " + str(pslot) + " " + pname)
    elif pkind == "index":
        emit("index")
    pkind = ""


def pend(kind, slot, s):
    global pkind, pslot, pname, pline, pcol
    pkind = kind
    pslot = slot
    pname = s
    pline = tline
    pcol = tcol


def expr():
    """expr ::= and { "||" and }"""
    andexpr()
    if tok == "||":
        t = newlabel()
        end = newlabel()
        while tok == "||":
            flush()
            emit("jt L" + str(t))
            scan()
            andexpr()
        flush()
        emit("jt L" + str(t))
        emit("int 0")
        emit("jmp L" + str(end))
        label(t)
        emit("int 1")
        label(end)


def andexpr():
    """and ::= compare { "&&" compare }"""
    compare()
    if tok == "&&":
        f = newlabel()
        end = newlabel()
        while tok == "&&":
            flush()
            emit("jf L" + str(f))
            scan()
            compare()
        flush()
        emit("jf L" + str(f))
        emit("int 1")
        emit("jmp L" + str(end))
        label(f)
        emit("int 0")
        label(end)


def compare():
    """compare ::= sum [ ( "==" | "!=" | "<" | "<=" | ">" | ">=" ) sum ]"""
    sumexpr()
    if CMP.get(tok):
        op = tok
        flush()
        scan()
        sumexpr()
        flush()
        emit(op)
        if CMP.get(tok):
            error("comparisons do not chain")


def sumexpr():
    """sum ::= product { ( "+" | "-" ) product }"""
    product()
    while tok == "+" or tok == "-":
        op = tok
        flush()
        scan()
        product()
        flush()
        emit(op)


def product():
    """product ::= unary { ( "*" | "/" | "%" ) unary }"""
    unary()
    while tok == "*" or tok == "/" or tok == "%":
        op = tok
        flush()
        scan()
        unary()
        flush()
        emit(op)


def unary():
    """unary ::= ( "-" | "!" ) unary | postfix"""
    if tok == "-" or tok == "!":
        op = "neg" if tok == "-" else "not"
        scan()
        unary()
        flush()
        emit(op)
    else:
        postfix()


def postfix():
    """postfix ::= primary { "(" [ args ] ")" | "[" expr "]" | "." NAME }"""
    primary()
    while True:
        if tok == "(":
            flush()
            scan()
            n = 0
            if tok != ")":
                expr()
                flush()
                n = 1
                while tok == ",":
                    scan()
                    expr()
                    flush()
                    n = n + 1
            expect(")")
            emit("call " + str(n))
        elif tok == "[":
            flush()
            scan()
            expr()
            flush()
            expect("]")
            pend("index", 0, "")
        elif tok == ".":
            flush()
            scan()
            emit("str " + quote(name()))
            pend("index", 0, "")
        else:
            return


def primary():
    if tok == "name":
        i = lookup(val)
        if i >= 0:
            pend("local", i, val)
        else:
            pend("global", gref(val), val)
        scan()
    elif tok == "int":
        emit("int " + str(val))
        scan()
    elif tok == "str":
        emit("str " + quote(val))
        scan()
    elif tok == "nil":
        emit("nil")
        scan()
    elif tok == "true" or tok == "false":
        emit("int 1" if tok == "true" else "int 0")
        scan()
    elif tok == "(":
        scan()
        expr()
        flush()                         # so that (x) = 1 is not an assignment
        expect(")")
    elif tok == "{":
        dictexpr()
    elif tok == "[":
        listexpr()
    else:
        error("expected an expression, found " + describe())


def dictexpr():
    """dict ::= "{" [ entry { "," entry } ] "}"
    entry ::= ( NAME | STRING | INTEGER | CHARACTER ) ":" expr"""
    emit("dict")
    scan()
    if tok != "}":
        entry()
        while tok == ",":
            scan()
            entry()
    expect("}")


def entry():
    if tok == "name" or tok == "str":
        emit("str " + quote(val))
    elif tok == "int":
        emit("int " + str(val))
    else:
        error("expected a key, found " + describe())
    scan()
    expect(":")
    expr()
    flush()
    emit("put")


def listexpr():
    """list ::= "[" [ args ] "]", short for {0: x, 1: y, ...}"""
    emit("dict")
    scan()
    if tok != "]":
        n = 0
        listitem(n)
        while tok == ",":
            scan()
            n = n + 1
            listitem(n)
    expect("]")


def listitem(n):
    emit("int " + str(n))
    expr()
    flush()
    emit("put")

# ---------------------------------------------------------------------------
# Statements

brk = 0             # the labels of the innermost loop's end and next round,
cont = 0            # or 0 outside a loop


def block(newscope):
    """block ::= "{" { stmt } "}" """
    global scopebase
    base = scopebase
    n = nloc
    if newscope:
        scopebase = nloc
    expect("{")
    while tok != "}":
        if tok == "eof":
            error("expected '}', found end of input")
        stmt()
    scan()
    if newscope:
        endscope(n)
        scopebase = base


def stmt():
    global brk, cont
    if tok == "var":
        scan()
        s = name()
        if tok == "=":
            scan()
            expr()
            flush()
        else:
            emit("nil")
        emit("setl " + str(addlocal(s)) + " " + s)
        expect(";")
    elif tok == "{":
        block(True)
    elif tok == "if":
        ifstmt()
    elif tok == "while":
        top = newlabel()
        end = newlabel()
        scan()
        label(top)
        condition()
        emit("jf L" + str(end))
        b = brk
        c = cont
        brk = end
        cont = top
        block(True)
        brk = b
        cont = c
        emit("jmp L" + str(top))
        label(end)
    elif tok == "for":
        forstmt()
    elif tok == "return":
        scan()
        if tok == ";":
            emit("nil")
        else:
            expr()
            flush()
        emit("ret")
        expect(";")
    elif tok == "break" or tok == "continue":
        target_label = brk if tok == "break" else cont
        if target_label == 0:
            error(tok + " outside a loop")
        emit("jmp L" + str(target_label))
        scan()
        expect(";")
    else:
        assignment()


def condition():
    expect("(")
    expr()
    flush()
    expect(")")


def ifstmt():
    """if ::= "if" "(" expr ")" block [ "else" ( block | if ) ]"""
    scan()
    condition()
    other = newlabel()
    emit("jf L" + str(other))
    block(True)
    if tok == "else":
        end = newlabel()
        emit("jmp L" + str(end))
        label(other)
        scan()
        if tok == "if":
            ifstmt()
        elif tok == "{":
            block(True)
        else:
            error("expected '{' or 'if' after else, found " + describe())
        label(end)
    else:
        label(other)


def forstmt():
    """for ( NAME in expr ) block"""
    global brk, cont, scopebase
    scan()
    expect("(")
    s = name()
    expect("in")
    expr()
    flush()
    expect(")")
    base = scopebase
    n = nloc
    scopebase = nloc
    it = addlocal("")
    addlocal("")
    k = addlocal(s)
    top = newlabel()
    end = newlabel()
    emit("iter " + str(it))
    label(top)
    emit("next " + str(it) + " L" + str(end))
    emit("setl " + str(k) + " " + s)
    b = brk
    c = cont
    brk = end
    cont = top
    block(True)
    brk = b
    cont = c
    emit("jmp L" + str(top))
    label(end)
    endscope(n)
    scopebase = base


def assignment():
    """expr [ "=" expr ] ";" """
    global pkind
    expr()
    if tok == "=":
        if pkind == "":
            error("cannot assign to this expression")
        kind = pkind
        slot = pslot
        s = pname
        pkind = ""
        if kind == "global" and gdecl.get(s) == "builtin":
            error_at(pline, pcol, "cannot assign to the built-in function " + s)
        scan()
        expr()
        flush()
        if kind == "local":
            emit("setl " + str(slot) + " " + s)
        elif kind == "global":
            emit("setg " + str(slot) + " " + s)
        else:
            emit("store")
    else:
        flush()
        emit("pop")
    expect(";")

# ---------------------------------------------------------------------------
# Program

init = {}


def declare(s, kind):
    if gdecl.get(s) == "builtin":
        error_at(nline, ncol, s + " is a built-in function")
    if gdecl.get(s) is not None:
        error_at(nline, ncol, s + " is already declared")
    gdecl[s] = kind
    return gref(s)


def fndef():
    """fndef ::= "fun" NAME "(" [ params ] ")" block"""
    global target, nloc, maxloc, scopebase, lname
    scan()
    s = name()
    declare(s, "fn")
    at = str(nline) + ":" + str(ncol)
    fnames[len(fnames)] = s
    target = {}
    lname = {}
    nloc = 0
    maxloc = 0
    scopebase = 0
    expect("(")
    if tok != ")":
        addlocal(name())
        while tok == ",":
            scan()
            addlocal(name())
    np = nloc
    gparams[s] = np
    if s == "main" and np != 0:
        error_at(at.split(":")[0], at.split(":")[1], "main must have no parameters")
    expect(")")
    block(False)
    emit("nil")
    emit("ret")
    endscope(0)                         # so that globals see no locals
    if not quiet:
        print("fun " + s + " params " + str(np) + " locals " + str(maxloc))
    show(target)
    if not quiet:
        print("end " + s)
        print()


def globalvar():
    """vardecl ::= "var" NAME [ "=" expr ] ";", at the top level"""
    global target
    scan()
    s = name()
    slot = declare(s, "var")
    if tok == "=":
        target = init
        scan()
        expr()
        flush()
        emit("setg " + str(slot) + " " + s)
    expect(";")


def program():
    """program ::= { global }"""
    for s in BUILTINS:
        gdecl[s] = "builtin"
        gref(s)
    scan()
    while tok != "eof":
        if tok == "fun":
            fndef()
        elif tok == "var":
            globalvar()
        else:
            error("expected 'fun' or 'var', found " + describe())
    for s in gslot:
        if gdecl.get(s) is None:
            at = gline[s].split(":")
            error_at(at[0], at[1], s + " is not declared")
    if gdecl.get("main") != "fn":
        error("there is no function main")
    code = {}
    i = 0
    while fnames.get(i) is not None:
        code[len(code)] = "    func " + fnames[i]
        code[len(code)] = "    setg " + str(gslot[fnames[i]]) + " " + fnames[i]
        i = i + 1
    i = 0
    while init.get(i) is not None:
        code[len(code)] = init[i]
        i = i + 1
    code[len(code)] = "    getg " + str(gslot["main"]) + " main"
    code[len(code)] = "    call 0"
    code[len(code)] = "    halt"
    if not quiet:
        print("init")
    show(code)


def main():
    global fname, quiet, src
    args = sys.argv[1:]
    tokens = False
    if len(args) == 2 and (args[0] == "-q" or args[0] == "-t"):
        quiet = args[0] == "-q"
        tokens = args[0] == "-t"
        args = args[1:]
    if len(args) != 1 or args[0].startswith("-"):
        print(__doc__, file=sys.stderr)
        return 2
    fname = args[0]
    with open(fname, "rb") as f:
        src = f.read()
    nextch()
    if tokens:
        scan()
        while tok != "eof":
            v = ""
            if tok == "name" or tok == "int":
                v = " " + str(val)
            elif tok == "str":
                v = " " + quote(val)
            print(str(tline) + ":" + str(tcol) + " " + tok + v)
            scan()
        return 0
    program()
    return 0


if __name__ == "__main__":
    sys.exit(main())
