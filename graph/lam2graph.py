#!/usr/bin/env python3
"""lam2graph.py - compile a lambda term to a combinator graph for graph.asm.

    python3 lam2graph.py fac.lam              write fac.graph
    python3 lam2graph.py fac.lam -o -         write the graph to standard output
    python3 lam2graph.py < fac.lam            the same
    python3 lam2graph.py -t fac.lam           print the combinator term instead

The compiler is prototype.py's: the reader, Turner's bracket abstraction and
the check for unbound variables. The graph is written in postfix, the format
graph.asm reads: a combinator or a number is a token, and "f a @" is f
applied to a. So C I compiles to "C I @".
"""
import argparse
import sys

from prototype import App, Error, Reader, check_free, compile_, show


def postfix(e):
    """The tokens of e in postfix, without recursion."""
    out, todo = [], [e]
    while todo:
        e = todo.pop()
        if isinstance(e, App):
            todo += ['@', e.a, e.f]
        else:
            out.append(str(e))
    return out


def lines(tokens, width=72):
    line = ''
    for t in tokens:
        if line and len(line) + 1 + len(t) > width:
            yield line
            line = t
        else:
            line = line + ' ' + t if line else t
    if line:
        yield line


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('program', nargs='?', help='file to compile (default: standard input)')
    ap.add_argument('-o', '--output', help='output file, - for standard output '
                    '(default: PROGRAM with .graph, or standard output)')
    ap.add_argument('-t', '--term', action='store_true',
                    help='print the combinator term, with brackets, instead')
    ap.add_argument('--ski', action='store_true', help='compile to S, K and I only')
    a = ap.parse_args()
    text = open(a.program).read() if a.program else sys.stdin.read()
    sys.setrecursionlimit(100000)
    try:
        code = compile_(Reader(text).program(), not a.ski)
        check_free(code)
    except Error as e:
        print('error:', e, file=sys.stderr)
        return 1
    if a.term:
        print(show(code))
        return 0
    out = a.output
    if out is None:
        out = a.program.rsplit('.', 1)[0] + '.graph' if a.program else '-'
    f = sys.stdout if out == '-' else open(out, 'w')
    if a.program:
        f.write(f'# {a.program}\n')
    for line in lines(postfix(code)):
        f.write(line + '\n')
    if f is not sys.stdout:
        f.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
