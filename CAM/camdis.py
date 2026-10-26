#!/usr/bin/env python3
"""camdis.py - show the CAM code that cam.asm compiles a program to.

    python3 camdis.py fac.lam [--vm ../vm16] [--image cam.v16]

Runs the program on the VM16 interpreter with -d, reads the compiled code out
of the memory dump, and prints it, indenting the body of each CUR and REC.
The CODE address and the opcode numbers are read from cam.asm.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OPERAND = {'ACC': 1, 'CUR': 2, 'QUOTE': 2, 'BRANCH': 2, 'JUMP': 2, 'REC': 2}
NAMES = ['STOP', 'ACC', 'PUSH', 'SWAP', 'CONS', 'CUR', 'APP', 'RET', 'QUOTE',
         'BRANCH', 'JUMP', 'REC', 'ADD', 'SUB', 'MUL', 'DIV', 'MOD', 'EQ', 'LT']


def read_equs():
    equ = {}
    for line in open(os.path.join(HERE, 'cam.asm')):
        m = re.match(r'\s*\.equ\s+(\w+),\s*(\w+)', line)
        if m:
            equ[m.group(1)] = int(m.group(2), 0)
    for i, name in enumerate(NAMES):           # check the table against cam.asm
        if equ.get('OP_' + name, i) != i:
            sys.exit(f'camdis.py: opcode {name} is not {i} in cam.asm')
    return equ


def disassemble(mem, start):
    lines, ends, pc = [], [], start
    while True:
        while ends and pc == ends[-1]:
            ends.pop()
        op = mem[pc]
        if op >= len(NAMES):
            sys.exit(f'camdis.py: bad opcode {op} at {pc:04X}')
        name = NAMES[op]
        n = OPERAND.get(name, 0)
        arg = mem[pc + 1] if n == 1 else mem[pc + 1] | mem[pc + 2] << 8
        text = name
        if name == 'ACC':
            text += f' {arg}'
        elif name == 'QUOTE':
            v = arg - 0x10000 if arg & 0x8000 else arg
            text += f' {v >> 1}'
        elif n == 2:
            text += f' {arg:04X}'
        lines.append(f'{pc:04X}  {"  " * len(ends)}{text}')
        if name in ('CUR', 'REC'):
            ends.append(arg)
        pc += 1 + n
        if name == 'STOP':
            return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('program')
    ap.add_argument('--vm', default=os.path.join(HERE, '..', 'vm16'))
    ap.add_argument('--image', default=os.path.join(HERE, 'cam.v16'))
    a = ap.parse_args()
    equ = read_equs()
    with tempfile.TemporaryDirectory() as d:
        dump = os.path.join(d, 'dump.bin')
        with open(a.program, 'rb') as f:
            p = subprocess.run([a.vm, '-d', dump, a.image], stdin=f, capture_output=True)
        sys.stdout.write(p.stdout.decode(errors='replace'))
        mem = open(dump, 'rb').read()[48:]          # skip the 48-byte state header
    print()
    print('\n'.join(disassemble(mem, equ['CODE'])))


if __name__ == '__main__':
    main()
