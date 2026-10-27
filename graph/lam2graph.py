#!/usr/bin/env python3
"""lam2graph.py - compile a lambda program to a combinator graph for graph.asm.

    python3 lam2graph.py fac.lam              write fac.graph
    python3 lam2graph.py fac.lam -o -         write the graph to standard output
    python3 lam2graph.py < fac.lam            the same
    python3 lam2graph.py -t fac.lam           print the combinator terms instead
    python3 lam2graph.py fac.morc             a MORC program (see morc.py)

The compiler is prototype.py's: the reader, Turner's bracket abstraction, and
the linking of definitions. The graph is written in postfix, the format
graph.asm reads: a combinator or a number is a token, and "f a @" is f
applied to a. So C I compiles to "C I @". A program with definitions starts
with %n, the number of definitions; each definition ends with =k, which makes
the cell on top of the stack definition k, and $k refers to definition k.
"""
import argparse
import sys

from prototype import Error, compile_text, emit, show_program


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('program', nargs='?', help='file to compile (default: standard input)')
    ap.add_argument('-o', '--output', help='output file, - for standard output '
                    '(default: PROGRAM with .graph, or standard output)')
    ap.add_argument('-t', '--term', action='store_true',
                    help='print the combinator terms, with brackets, instead')
    ap.add_argument('--ski', action='store_true', help='compile to S, K and I only')
    ap.add_argument('-m', '--morc', action='store_true',
                    help='the input is a MORC program (implied by a .morc file)')
    a = ap.parse_args()
    text = open(a.program).read() if a.program else sys.stdin.read()
    sys.setrecursionlimit(100000)
    try:
        program = compile_text(text, not a.ski, a.morc or (a.program or '').endswith('.morc'))
    except Error as e:
        print('error:', e, file=sys.stderr)
        return 1
    if a.term:
        print('\n'.join(show_program(program)))
        return 0
    out = a.output
    if out is None:
        out = a.program.rsplit('.', 1)[0] + '.graph' if a.program else '-'
    f = sys.stdout if out == '-' else open(out, 'w')
    if a.program:
        f.write(f'# {a.program}\n')
    for line in emit(program):
        f.write(line + '\n')
    if f is not sys.stdout:
        f.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
