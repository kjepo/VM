#!/usr/bin/env python3
"""inet.py -- a small interaction net reducer for the tutorial.

Usage:
    python3 inet.py [options] prog.inet     rules and a net, in term notation
    python3 inet.py [options] prog.lam      a lambda-term, run on lambda.inet

Options:
    -t, --trace     print the net after every interaction
    -r, --random N  pick active pairs in random order, with seed N
    -q, --quiet     print only the counts
    -c, --check     (.lam only) compare with a normal-order reference
    -l, --lazy      (.lam only) reduce only what the readback needs
    -n, --limit N   stop after N interactions (default 1000000)
    -d, --dot DIR   write the net before each interaction, and the final
                    net, as Graphviz files DIR/step-000.dot, ...

Term notation (Lafont; Fernandez and Mackie). An agent with its principal
port pointing up is written  A(t1, ..., tn), where t1..tn are what its
auxiliary ports are connected to. A lower-case name is a wire: it occurs
exactly twice in a rule and at most twice in a net. An equation t ~ u
connects the two principal ports (or wires) t and u. A file holds

    Add(r, y) >< Z       => r ~ y
    Add(r, y) >< S(x)    => r ~ S(w), x ~ Add(w, y)
    r ~ Add(r1, S(Z)), r1 ~ ... -- equations not in a rule form the net

Agents may carry a label, Dup{i}. In a rule, Dup{i} >< Dup{i} matches only
equal labels; rules are tried in the order written, so put that case
before Dup{i} >< Dup{j}. Wires that occur once in the net form its
interface, and the result is printed as equations on them. '#' starts a
comment, and a line ending in ',' continues on the next line.
"""

import os
import random
import re
import sys

sys.setrecursionlimit(100000)

# ---------------------------------------------------------------- the net


class Agent:
    __slots__ = ("name", "label", "ports", "alive")

    def __init__(self, name, arity, label=None):
        self.name = name
        self.label = label
        self.ports = [None] * (arity + 1)  # ports[i] = (agent, j) of the peer
        self.alive = True

    def __repr__(self):
        lab = "" if self.label is None else "{%s}" % self.label
        return "%s%s#%x" % (self.name, lab, id(self) & 0xFFFF)


class Free(Agent):
    """An interface wire end. It never interacts."""

    def __init__(self, name):
        Agent.__init__(self, name, 0)


class Net:
    def __init__(self, rules):
        self.rules = rules
        self.redexes = []
        self.free = {}        # interface name -> Free
        self.live = 0
        self.peak = 0
        self.count = 0
        self.by_rule = {}

    def new(self, name, arity, label=None):
        a = Agent(name, arity, label)
        self.live += 1
        self.peak = max(self.peak, self.live)
        return a

    def kill(self, a):
        a.alive = False
        self.live -= 1

    def link(self, a, i, b, j):
        a.ports[i] = (b, j)
        b.ports[j] = (a, i)
        if i == 0 and j == 0 and not isinstance(a, Free) \
                and not isinstance(b, Free):
            self.redexes.append((a, b))

    def agents(self):
        """All live agents reachable from the interface and the redexes."""
        seen, todo = set(), [f for f in self.free.values()]
        for a, b in self.redexes:
            todo += [a, b]
        out = []
        while todo:
            a = todo.pop()
            if id(a) in seen:
                continue
            seen.add(id(a))
            out.append(a)
            for p in a.ports:
                if p is not None:
                    todo.append(p[0])
        return out

# ---------------------------------------------------------------- terms


TOKEN = re.compile(r"\s*(=>|><|~|[A-Za-z_][A-Za-z0-9_']*|\{[A-Za-z0-9_]*\}"
                   r"|[(),]|\S)")


def tokenize(s):
    toks, pos = [], 0
    while pos < len(s):
        m = TOKEN.match(s, pos)
        if not m or m.end() == pos:
            break
        if m.group(1):
            toks.append(m.group(1))
        pos = m.end()
    return toks


class Syntax(Exception):
    pass


def parse_term(toks, k):
    """term ::= wire | Agent[{label}] [ '(' term {',' term} ')' ]"""
    t = toks[k]
    if not re.match(r"[A-Za-z_]", t):
        raise Syntax("expected a term, found %r" % t)
    k += 1
    if t[0].islower():
        return ("wire", t), k
    label = None
    if k < len(toks) and toks[k].startswith("{"):
        label = toks[k][1:-1]
        k += 1
    args = []
    if k < len(toks) and toks[k] == "(":
        k += 1
        while True:
            a, k = parse_term(toks, k)
            args.append(a)
            if toks[k] == ")":
                k += 1
                break
            if toks[k] != ",":
                raise Syntax("expected ',' or ')', found %r" % toks[k])
            k += 1
    return ("agent", t, label, args), k


def parse_equations(toks, k):
    eqs = []
    while k < len(toks):
        l, k = parse_term(toks, k)
        if k >= len(toks) or toks[k] != "~":
            raise Syntax("expected '~'")
        r, k = parse_term(toks, k + 1)
        eqs.append((l, r))
        if k < len(toks):
            if toks[k] != ",":
                raise Syntax("expected ',' between equations")
            k += 1
    return eqs


def wires(t, acc):
    if t[0] == "wire":
        acc.append(t[1])
    else:
        for a in t[3]:
            wires(a, acc)
    return acc


class Rule:
    def __init__(self, left, right, eqs, text):
        self.left, self.right, self.eqs, self.text = left, right, eqs, text
        for side in (left, right):
            if side[0] != "agent" or any(a[0] != "wire" for a in side[3]):
                raise Syntax("the left of a rule is A(x..) >< B(y..)")
        lw = wires(left, []) + wires(right, [])
        rw = []
        for l, r in eqs:
            wires(l, rw)
            wires(r, rw)
        if len(set(lw)) != len(lw):
            raise Syntax("a wire occurs twice on the left of a rule")
        for w in lw:
            if rw.count(w) != 1:
                raise Syntax("wire %s must occur once on the right" % w)
        for w in set(rw) - set(lw):
            if rw.count(w) != 2:
                raise Syntax("wire %s must occur twice on the right" % w)
        self.name = "%s-%s" % (left[1], right[1])

    def labels_match(self, a, b):
        la, lb = self.left[2], self.right[2]
        if la is not None and la == lb:
            return a.label == b.label
        return True


def read_file(path):
    rules, eqs, lines = {}, [], []
    with open(path) as f:
        buf = ""
        for raw in f:
            line = raw.split("#", 1)[0].rstrip()
            buf += " " + line
            if buf.strip().endswith((",", "><", "~")):
                continue
            if buf.strip():
                lines.append(buf.strip())
            buf = ""
        if buf.strip():
            lines.append(buf.strip())
    for line in lines:
        if line.startswith("include "):
            name = line.split(None, 1)[1].strip().strip('"')
            r2, e2 = read_file(os.path.join(os.path.dirname(path), name))
            for k, v in r2.items():
                rules.setdefault(k, []).extend(v)
            eqs += e2
            continue
        toks = tokenize(line)
        try:
            if "=>" in toks:
                k = toks.index("=>")
                lhs = toks[:k]
                if "><" not in lhs:
                    raise Syntax("expected '><' before '=>'")
                m = lhs.index("><")
                left, k1 = parse_term(lhs, 0)
                right, k2 = parse_term(lhs, m + 1)
                if k1 != m or k2 != len(lhs):
                    raise Syntax("bad left-hand side")
                rule = Rule(left, right, parse_equations(toks, k + 1), line)
                rules.setdefault((left[1], right[1]), []).append(rule)
            else:
                eqs += parse_equations(toks, 0)
        except (Syntax, IndexError) as e:
            msg = str(e) if isinstance(e, Syntax) else "unexpected end"
            sys.exit("%s: %s\n  in: %s" % (path, msg, line))
    return rules, eqs

# ---------------------------------------------------------------- building


def build(net, eqs, env):
    """Instantiate equations. env maps an outside wire name to the port
    (agent, i) it is attached to; every other wire occurs twice in eqs."""
    ends = {}  # wire name -> list of endpoints: ('port', a, i) or ('wire', n)
    edges = []

    def make(t):
        if t[0] == "wire":
            return ("wire", t[1])
        _, name, label, args = t
        a = net.new(name, len(args), label)
        for i, s in enumerate(args, 1):
            edges.append((("port", a, i), make(s)))
        return ("port", a, 0)

    for l, r in eqs:
        edges.append((make(l), make(r)))
    for e1, e2 in edges:
        for e, other in ((e1, e2), (e2, e1)):
            if e[0] == "wire":
                ends.setdefault(e[1], []).append(other)
    for w, port in env.items():
        ends.setdefault(w, []).append(("port",) + port)

    linked = set()
    for e1, e2 in edges + [(("wire", w), ("port",) + p) for w, p in env.items()]:
        if e1[0] == "port" and e2[0] == "port":
            net.link(e1[1], e1[2], e2[1], e2[2])
            continue
        for p, w in ((e1, e2), (e2, e1)):
            if p[0] == "port" and w[0] == "wire":
                key = (id(p[1]), p[2])
                if key in linked:
                    continue
                q = resolve(ends, w[1], p)
                if q is None:
                    continue
                linked.add(key)
                linked.add((id(q[1]), q[2]))
                net.link(p[1], p[2], q[1], q[2])


def resolve(ends, w, start):
    """The port at the other end of wire w, seen from port end 'start'."""
    prev = start
    while True:
        lst = ends[w]
        nxt = [x for x in lst if x is not prev and x != prev]
        if len(lst) == 2 and lst[0] == lst[1]:
            nxt = [lst[0]]
        if not nxt:
            return None
        e = nxt[0]
        if e[0] == "port":
            return e
        prev = ("wire", w)
        w = e[1]


def load_net(net, eqs):
    count = {}
    for l, r in eqs:
        for w in wires(l, []) + wires(r, []):
            count[w] = count.get(w, 0) + 1
    env = {}
    for w, c in count.items():
        if c > 2:
            sys.exit("wire %s occurs %d times in the net" % (w, c))
        if c == 1:
            f = Free(w)
            net.free[w] = f
            env[w] = (f, 0)
    build(net, eqs, env)

# ---------------------------------------------------------------- reduction


def interact(net, a, b):
    for rule in net.rules.get((a.name, b.name), []):
        if rule.labels_match(a, b):
            return fire(net, rule, a, b)
    for rule in net.rules.get((b.name, a.name), []):
        if rule.labels_match(b, a):
            return fire(net, rule, b, a)
    sys.exit("no rule for %s >< %s" % (a.name, b.name))


def fire(net, rule, a, b):
    _, _, la, xs = rule.left
    _, _, lb, ys = rule.right
    labels = {}
    if la is not None:
        labels[la] = a.label
    if lb is not None:
        labels.setdefault(lb, b.label)
    # each left wire is attached to the peer of an auxiliary port; a peer
    # that belongs to a or b itself is another left wire
    own = {}
    for ag, ws in ((a, xs), (b, ys)):
        for i, w in enumerate(ws, 1):
            own[(id(ag), i)] = w[1]
    env, extra = {}, []
    for ag, ws in ((a, xs), (b, ys)):
        for i, w in enumerate(ws, 1):
            peer, j = ag.ports[i]
            if (id(peer), j) in own:
                other = own[(id(peer), j)]
                if w[1] < other:
                    extra.append((("wire", w[1]), ("wire", other)))
            else:
                env[w[1]] = (peer, j)
    eqs = [(subst(l, labels), subst(r, labels)) for l, r in rule.eqs]
    net.kill(a)
    net.kill(b)
    build(net, eqs + extra, env)
    net.count += 1
    net.by_rule[rule.name] = net.by_rule.get(rule.name, 0) + 1


def subst(t, labels):
    if t[0] == "wire":
        return t
    _, name, label, args = t
    if label is not None:
        label = labels.get(label, label)
    return ("agent", name, label, [subst(x, labels) for x in args])


def run(net, order=None, limit=1000000, trace=None, before=None):
    while net.redexes:
        if net.count >= limit:
            return False
        if order is None:
            a, b = net.redexes.pop()
        else:
            k = order.randrange(len(net.redexes))
            net.redexes[k], net.redexes[-1] = net.redexes[-1], net.redexes[k]
            a, b = net.redexes.pop()
        if not (a.alive and b.alive):
            continue
        if before:
            before(net, a, b)
        interact(net, a, b)
        if trace:
            trace(net)
    return True

# ---------------------------------------------------------------- printing


def show(net):
    """The net as equations, trees hanging from principal ports."""
    agents = [a for a in net.agents() if not isinstance(a, Free)]
    names = {}
    counter = [0]

    def wire_name(a, i):
        p = (id(a), i)
        if p not in names:
            peer, j = a.ports[i]
            counter[0] += 1
            n = "w%d" % counter[0]
            names[p] = n
            names[(id(peer), j)] = n
        return names[p]

    printed = set()

    def tree(a):
        printed.add(id(a))
        lab = "" if a.label is None else "{%s}" % a.label
        args = []
        for i in range(1, len(a.ports)):
            peer, j = a.ports[i]
            if isinstance(peer, Free):
                args.append(peer.name)
            elif j == 0 and id(peer) not in printed:
                args.append(tree(peer))
            else:
                args.append(wire_name(a, i))
        return a.name + lab + ("(%s)" % ", ".join(args) if args else "")

    def root(a):
        peer, j = a.ports[0]
        return not (j > 0 and not isinstance(peer, Free))

    out = []
    for name in sorted(net.free):
        f = net.free[name]
        peer, j = f.ports[0]
        if isinstance(peer, Free):
            if name < peer.name:
                out.append("%s ~ %s" % (name, peer.name))
        elif j == 0:
            out.append("%s ~ %s" % (name, tree(peer)))
    for a in agents:
        if id(a) in printed or not root(a):
            continue
        peer, j = a.ports[0]
        if isinstance(peer, Free):
            continue
        if j == 0:
            t = tree(a)
            out.append("%s ~ %s" % (t, tree(peer)))
    for a in agents:          # vicious circles: no root at all
        if id(a) not in printed:
            t = tree(a)
            out.append("%s ~ %s" % (t, wire_name(a, 0)))
    # aux-aux wires between trees, and aux ports on the interface
    return out


def rule_for(net, a, b):
    for x, y in ((a, b), (b, a)):
        for rule in net.rules.get((x.name, y.name), []):
            if rule.labels_match(x, y):
                return rule
    return None


def to_dot(net, title, pair=None):
    """The net as a Graphviz graph. Agents are triangles with the principal
    port at the apex. Trees hang below their principal ports, as in show();
    in an active pair the first agent is turned over, with its subtrees
    above it. The pair about to fire is filled."""
    everything = net.agents()
    agents = [a for a in everything if not isinstance(a, Free)]
    frees = [a for a in everything if isinstance(a, Free)]
    up = {}                                   # id -> apex up?

    def grow(root, upright):
        todo = [root]
        while todo:
            a = todo.pop()
            if id(a) in up:
                continue
            up[id(a)] = upright
            for peer, j in a.ports[1:]:
                if j == 0 and not isinstance(peer, Free):
                    todo.append(peer)

    if pair:
        grow(pair[0], False)
        grow(pair[1], True)
    for a in agents:
        peer, j = a.ports[0]
        if j == 0 and not isinstance(peer, Free) and id(a) not in up \
                and id(peer) not in up:
            grow(a, False)
            grow(peer, True)
    for a in agents:
        peer, j = a.ports[0]
        if j != 0 or isinstance(peer, Free):
            grow(a, True)
    for a in agents:
        grow(a, True)

    ids = {}
    for a in everything:
        ids[id(a)] = "n%d" % len(ids)
    firing = {id(x) for x in pair} if pair else set()

    def compass(a, i):
        n = len(a.ports) - 1
        if i == 0:
            c = "n"
        elif n == 1:
            c = "s"
        else:
            c = {2: ["sw", "se"], 3: ["sw", "s", "se"]}.get(n, ["s"] * n)[i - 1]
        if not up[id(a)]:
            c = c.replace("n", "S").replace("s", "n").replace("S", "s")
        return c

    out = ["graph net {",
           '  graph [label="%s", labelloc=t, fontname="Helvetica", '
           'fontsize=14, nodesep=0.35, ranksep=0.45];' % title,
           '  node [fontname="Helvetica", fontsize=12];',
           '  edge [color="#444444"];']
    for a in frees:
        out.append('  %s [shape=plaintext, label="%s", fontcolor="#1f5fbf", '
                   'fontname="Helvetica-Oblique"];' % (ids[id(a)], a.name))
    for a in agents:
        name = a.name if a.label is None else "%s%s" % (a.name, a.label)
        shape = "triangle" if up[id(a)] else "invtriangle"
        fill = ', style=filled, fillcolor="#f6c9c4"' if id(a) in firing \
            else ', style=filled, fillcolor="#e8eef7"'
        out.append('  %s [shape=%s, label="%s", width=0.75, height=0.6, '
                   'fixedsize=true, margin=0%s];'
                   % (ids[id(a)], shape, name, fill))
    done = set()
    for a in everything:
        for i, p in enumerate(a.ports):
            if p is None:
                continue
            b, j = p
            key = frozenset([(id(a), i), (id(b), j)])
            if key in done:
                continue
            done.add(key)
            # put the end that belongs above first
            fa, fb = isinstance(a, Free), isinstance(b, Free)
            attrs = []
            if fa and fb:
                tail, head = (a, i), (b, j)
            elif fa or fb:
                f, (g, k) = ((a, i), (b, j)) if fa else ((b, j), (a, i))
                below = (k == 0) == up[id(g)]
                tail, head = (f, (g, k)) if below else ((g, k), f)
            elif i == 0 and j == 0:
                tail, head = ((a, i), (b, j)) if not up[id(a)] \
                    else ((b, j), (a, i))
                active = id(a) in firing and id(b) in firing
                attrs.append('color="#c0392b", penwidth=%s'
                             % ("3" if active else "2"))
            elif i == 0 or j == 0:
                child, parent = ((a, i), (b, j)) if i == 0 else ((b, j), (a, i))
                tail, head = (parent, child) if up[id(child[0])] \
                    else (child, parent)
            else:
                tail, head = (a, i), (b, j)
                attrs.append("constraint=false")

            def end(e):
                x, k = e
                if isinstance(x, Free):
                    return ids[id(x)]
                return "%s:%s" % (ids[id(x)], compass(x, k))
            out.append("  %s -- %s%s;" % (end(tail), end(head),
                       " [%s]" % ", ".join(attrs) if attrs else ""))
    out.append("}")
    return "\n".join(out) + "\n"

# ---------------------------------------------------------------- lambda terms


LAM_RULES = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "lambda.inet")


def read_lam(path):
    out = []
    with open(path) as f:
        for line in f:
            m = re.match(r'\s*include\s+"?([^"\s]+)"?', line)
            if m:
                out.append(read_lam(os.path.join(os.path.dirname(path),
                                                 m.group(1))))
            else:
                out.append(line)
    return "".join(out)


def lam_parse(text):
    """Definitions 'f x y = M;' then an expression; \\x y.M; juxtaposition."""
    text = re.sub(r"#[^\n]*", "", text)
    toks = re.findall(r"[A-Za-z_][A-Za-z0-9_']*|\\|[().=;]", text)
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else None

    def eat(t):
        if peek() != t:
            sys.exit("syntax error: expected %r, found %r" % (t, peek()))
        pos[0] += 1

    def term():
        if peek() == "\\":
            eat("\\")
            xs = []
            while peek() not in (".", None):
                xs.append(peek())
                pos[0] += 1
            eat(".")
            body = term()
            for x in reversed(xs):
                body = ("lam", x, body)
            return body
        t = atom()
        while peek() not in (")", ";", None):
            t = ("app", t, atom() if peek() != "\\" else term())
        return t

    def atom():
        t = peek()
        if t == "(":
            eat("(")
            m = term()
            eat(")")
            return m
        if t is None or not re.match(r"[A-Za-z_]", t):
            sys.exit("syntax error at %r" % t)
        pos[0] += 1
        return ("var", t)

    defs = {}
    while True:
        k = pos[0]
        j = k
        while j < len(toks) and toks[j] not in ("=", ";"):
            j += 1
        if j < len(toks) and toks[j] == "=":
            name, params = toks[k], toks[k + 1:j]
            pos[0] = j + 1
            body = term()
            for x in reversed(params):
                body = ("lam", x, body)
            defs[name] = expand(body, defs, set())
            eat(";")
        else:
            m = term()
            if peek() is not None:
                sys.exit("syntax error at %r" % peek())
            return expand(m, defs, set()), defs


def expand(t, defs, bound):
    if t[0] == "var":
        return defs[t[1]] if t[1] in defs and t[1] not in bound else t
    if t[0] == "lam":
        return ("lam", t[1], expand(t[2], defs, bound | {t[1]}))
    return ("app", expand(t[1], defs, bound), expand(t[2], defs, bound))


def lam_to_net(net, term):
    """Lam(x, b): principal = the function, aux 1 = variable, aux 2 = body.
    App(a, r): principal = the function, aux 1 = argument, aux 2 = result.
    A variable used k > 1 times gets k-1 fans Dup{L}, L fresh per binder;
    an unused one gets an eraser."""
    labels = [0]
    uses = {}

    def tr(t, scope):
        # returns the port (agent, i) that is the root of t
        if t[0] == "var":
            if t[1] in scope:
                return ("use", t[1], scope[t[1]])
            if t[1] not in net.free:
                net.free[t[1]] = []
            return ("freeuse", t[1])
        if t[0] == "lam":
            lam = net.new("Lam", 2)
            key = object()
            uses[key] = []
            body = tr(t[2], dict(scope, **{t[1]: key}))
            plug(body, lam, 2)
            bind(lam, key)
            return (lam, 0)
        app = net.new("App", 2)
        plug(tr(t[1], scope), app, 0)
        plug(tr(t[2], scope), app, 1)
        return (app, 2)

    def plug(src, a, i):
        if src[0] == "use":
            uses[src[2]].append((a, i))
        elif src[0] == "freeuse":
            net.free[src[1]].append((a, i))
        else:
            net.link(src[0], src[1], a, i)

    def bind(lam, key):
        fan_out(lam, 1, uses.pop(key))

    def fan_out(a, i, ports):
        if not ports:
            e = net.new("Era", 0)
            net.link(a, i, e, 0)
            return
        if len(ports) == 1:
            net.link(a, i, ports[0][0], ports[0][1])
            return
        labels[0] += 1
        lab = labels[0]

        def tree(ps):
            if len(ps) == 1:
                return ps[0]
            d = net.new("Dup", 2, lab)
            h = len(ps) // 2
            l, r = tree(ps[:h]), tree(ps[h:])
            net.link(d, 1, l[0], l[1])
            net.link(d, 2, r[0], r[1])
            return (d, 0)

        root = tree(ports)
        net.link(a, i, root[0], root[1])

    root = tr(term, {})
    out = Free("out")
    if root[0] in ("use", "freeuse"):
        sys.exit("the program is a single variable")
    net.link(out, 0, root[0], root[1])
    frees = net.free
    net.free = {"out": out}
    for name, ports in frees.items():
        f = Free(name)
        net.free[name] = f
        fan_out(f, 0, ports)


def lam_readback(net):
    """Read the lambda-term back from the output wire. Fans are passed with
    one stack of choices per label: entering a fan at an auxiliary port
    pushes the port, entering at the principal port pops it."""
    names = {}
    counter = [0]

    def fresh():
        n = counter[0]
        counter[0] += 1
        s = "xyzwvutsrqponmlkjihgfedcba"[n % 26]
        return s + ("" if n < 26 else str(n // 26))

    def read(port, stacks, depth):
        if depth > 2000:
            return ("var", "...")
        a, i = port
        if isinstance(a, Free):
            return ("var", a.name)
        if a.name == "Lam":
            if i == 0:
                x = fresh()
                names[id(a)] = x
                return ("lam", x, read(a.ports[2], stacks, depth + 1))
            if i == 1:
                return ("var", names.get(id(a), "?"))
            return ("var", "?body")
        if a.name == "App":
            if i == 2:
                return ("app", read(a.ports[0], stacks, depth + 1),
                        read(a.ports[1], stacks, depth + 1))
            return ("var", "?redex")
        if a.name == "Dup":
            st = stacks.get(a.label, ())
            if i == 0:
                if not st:
                    return ("var", "?fan")
                k, rest = st[0], st[1:]
                s2 = dict(stacks)
                s2[a.label] = rest
                return read(a.ports[k], s2, depth + 1)
            s2 = dict(stacks)
            s2[a.label] = (i,) + st
            return read(a.ports[0], s2, depth + 1)
        return ("var", "?" + a.name)

    return read(net.free["out"].ports[0], {}, 0)


def lam_first_redex(net):
    """The first active pair met when reading the term back, function
    before argument (leftmost-outermost), or None."""
    def cross(a, k, stacks, depth):
        b, j = a.ports[k]
        if k == 0 and j == 0 and not isinstance(b, Free) \
                and not isinstance(a, Free):
            return (a, b)
        return visit((b, j), stacks, depth)

    def visit(port, stacks, depth):
        a, i = port
        if isinstance(a, Free) or depth > 5000:
            return None
        if a.name == "Lam":
            return cross(a, 2, stacks, depth + 1) if i == 0 else None
        if a.name == "App":
            if i != 2:
                return None
            return cross(a, 0, stacks, depth + 1) or \
                cross(a, 1, stacks, depth + 1)
        if a.name == "Dup":
            st = stacks.get(a.label, ())
            s2 = dict(stacks)
            if i == 0:
                if not st:
                    return None
                s2[a.label] = st[1:]
                return cross(a, st[0], s2, depth + 1)
            s2[a.label] = (i,) + st
            return cross(a, 0, s2, depth + 1)
        return None

    out = net.free["out"]
    b, j = out.ports[0]
    return visit((b, j), {}, 0)


def run_lazy(net, limit=1000000, trace=None, before=None):
    """Reduce only the active pairs that the readback reaches."""
    while True:
        if net.count >= limit:
            return False
        r = lam_first_redex(net)
        if r is None:
            return True
        if before:
            before(net, r[0], r[1])
        interact(net, r[0], r[1])
        if trace:
            trace(net)


def lam_show(t):
    if t[0] == "var":
        return t[1]
    if t[0] == "lam":
        xs, b = [t[1]], t[2]
        while b[0] == "lam":
            xs.append(b[1])
            b = b[2]
        return "\\%s. %s" % (" ".join(xs), lam_show(b))
    f = lam_show(t[1]) if t[1][0] != "lam" else "(%s)" % lam_show(t[1])
    x = lam_show(t[2]) if t[2][0] == "var" else "(%s)" % lam_show(t[2])
    return "%s %s" % (f, x)

# ---------------------------------------------------------------- reference


def debruijn(t, env=()):
    if t[0] == "var":
        return ("v", env.index(t[1])) if t[1] in env else ("f", t[1])
    if t[0] == "lam":
        return ("l", debruijn(t[2], (t[1],) + env))
    return ("a", debruijn(t[1], env), debruijn(t[2], env))


def shift(t, d, c=0):
    if t[0] == "v":
        return ("v", t[1] + d) if t[1] >= c else t
    if t[0] == "f":
        return t
    if t[0] == "l":
        return ("l", shift(t[1], d, c + 1))
    return ("a", shift(t[1], d, c), shift(t[2], d, c))


def subst_db(t, s, k=0):
    if t[0] == "v":
        if t[1] == k:
            return shift(s, k)
        return ("v", t[1] - 1) if t[1] > k else t
    if t[0] == "f":
        return t
    if t[0] == "l":
        return ("l", subst_db(t[1], s, k + 1))
    return ("a", subst_db(t[1], s, k), subst_db(t[2], s, k))


def normal_order(t, limit=200000):
    """Leftmost-outermost normalisation; returns (normal form, beta steps)."""
    steps = [0]

    def step(t):
        # one leftmost-outermost step, or None
        if t[0] == "a":
            if t[1][0] == "l":
                return subst_db(t[1][1], t[2])
            f = step(t[1])
            if f is not None:
                return ("a", f, t[2])
            x = step(t[2])
            return None if x is None else ("a", t[1], x)
        if t[0] == "l":
            b = step(t[1])
            return None if b is None else ("l", b)
        return None

    while steps[0] < limit:
        n = step(t)
        if n is None:
            return t, steps[0]
        t = n
        steps[0] += 1
    return None, steps[0]

# ---------------------------------------------------------------- main


def main():
    args = sys.argv[1:]
    trace = quiet = check = lazy = False
    dotdir = None
    order = None
    limit = 1000000
    path = None
    while args:
        a = args.pop(0)
        if a in ("-t", "--trace"):
            trace = True
        elif a in ("-q", "--quiet"):
            quiet = True
        elif a in ("-c", "--check"):
            check = True
        elif a in ("-l", "--lazy"):
            lazy = True
        elif a in ("-r", "--random"):
            order = random.Random(int(args.pop(0)))
        elif a in ("-d", "--dot"):
            dotdir = args.pop(0)
        elif a in ("-n", "--limit"):
            limit = int(args.pop(0))
        elif a.startswith("-"):
            sys.exit(__doc__)
        else:
            path = a
    if path is None:
        sys.exit(__doc__)

    is_lam = path.endswith(".lam")
    if is_lam:
        rules, _ = read_file(LAM_RULES)
        net = Net(rules)
        term, _ = lam_parse(read_lam(path))
        lam_to_net(net, term)
    else:
        rules, eqs = read_file(path)
        net = Net(rules)
        load_net(net, eqs)

    def tr(n):
        print("%4d  %s" % (n.count, ",  ".join(show(n))))

    def snapshot(n, a, b):
        rule = rule_for(n, a, b)
        title = "step %d: %s" % (n.count + 1, rule.name if rule else "?")
        with open(os.path.join(dotdir, "step-%03d.dot" % n.count), "w") as f:
            f.write(to_dot(n, title, (a, b)))

    if dotdir:
        os.makedirs(dotdir, exist_ok=True)
    if trace:
        print("%4d  %s" % (0, ",  ".join(show(net))))
    if lazy:
        done = run_lazy(net, limit, tr if trace else None,
                        snapshot if dotdir else None)
    else:
        done = run(net, order, limit, tr if trace else None,
                   snapshot if dotdir else None)
    if dotdir:
        with open(os.path.join(dotdir, "step-%03d.dot" % net.count), "w") as f:
            f.write(to_dot(net, "normal form after %d interactions"
                           % net.count))
    if not quiet and not trace:
        if is_lam:
            print(lam_show(lam_readback(net)))
        else:
            for eq in show(net):
                print(eq)
    if not done:
        print("stopped after %d interactions" % net.count)
    rules_used = ", ".join("%s %d" % kv for kv in sorted(net.by_rule.items()))
    print("interactions: %d (%s)" % (net.count, rules_used))
    print("peak agents: %d" % net.peak)
    if is_lam and check:
        ref, beta = normal_order(debruijn(term))
        got = debruijn(lam_readback(net))
        if ref is None:
            print("reference: no normal form within %d steps" % beta)
        else:
            print("normal order: %d beta steps" % beta)
            print("check: %s" % ("ok" if got == ref else "WRONG"))
            if got != ref:
                sys.exit(1)


if __name__ == "__main__":
    main()
