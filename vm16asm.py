#!/usr/bin/env python3
"""vm16asm.py - assembler for VM16, specification version 0.1.

Accepts the syntax of appendix B of vm16-spec.tex and writes a program image
(spec section 7).

Usage:  python vm16asm.py SOURCE.asm [-o IMAGE] [-l LISTING]

The image defaults to SOURCE with the extension .v16.

Syntax summary:
    label:  MNEMONIC operands       ; comment
    registers r0..r15, memory operands [rb] and [rb+expr]
    numbers 42, 0x2A, 'A' (escapes \\n \\t \\0 \\\\ \\'), expressions with + - * ( )
    .org addr   .equ name, value   .byte e, ...   .word e, ...   .ascii "text"
    .space n    .entry label       .stacks dsp, rsp
"""

import re
import sys

OPS = {
    'HALT': (0x00, 'A'), 'NOP': (0x01, 'A'), 'LI': (0x02, 'RI16'), 'MOV': (0x03, 'RR'),
    'LW': (0x04, 'RM'), 'SW': (0x05, 'RM'), 'LB': (0x06, 'RM'), 'SB': (0x07, 'RM'),
    'LWA': (0x08, 'RI16'), 'SWA': (0x09, 'RI16'),
    'ADD': (0x10, 'RR'), 'SUB': (0x11, 'RR'), 'AND': (0x12, 'RR'), 'OR': (0x13, 'RR'),
    'XOR': (0x14, 'RR'), 'MUL': (0x15, 'RR'), 'DIVU': (0x16, 'RR'),
    'NOT': (0x18, 'R'), 'NEG': (0x19, 'R'), 'SHL': (0x1A, 'R'), 'SHR': (0x1B, 'R'),
    'SAR': (0x1C, 'R'), 'ADDI': (0x1D, 'RS8'),
    'BEQ': (0x20, 'RRB'), 'BNE': (0x21, 'RRB'), 'BLT': (0x22, 'RRB'), 'BGE': (0x23, 'RRB'),
    'BLTU': (0x24, 'RRB'), 'BGEU': (0x25, 'RRB'), 'BZ': (0x26, 'RB'), 'BNZ': (0x27, 'RB'),
    'JMP': (0x28, 'I16'), 'JR': (0x29, 'R'),
    'PUSH': (0x30, 'R'), 'POP': (0x31, 'R'), 'GETDSP': (0x32, 'R'), 'SETDSP': (0x33, 'R'),
    'GETRSP': (0x34, 'R'), 'SETRSP': (0x35, 'R'),
    'CALL': (0x38, 'I16'), 'CALLR': (0x39, 'R'), 'RET': (0x3A, 'A'), 'SYS': (0x3F, 'U8'),
}
# Operand shapes (spec formats in parentheses): A, R, U8 (I8), RR, RS8 and RB (RI8),
# I16, RM and RRB (RRI8), RI16.
SIZE = {'A': 1, 'R': 2, 'U8': 2, 'RR': 3, 'RS8': 3, 'RB': 3, 'I16': 3, 'RM': 4, 'RRB': 4,
        'RI16': 4}
NOPS = {'A': 0, 'R': 1, 'U8': 1, 'RR': 2, 'RS8': 2, 'RB': 2, 'I16': 1, 'RM': 2, 'RRB': 3,
        'RI16': 2}
ESCAPES = {'n': 10, 't': 9, 'r': 13, '0': 0, '\\': 92, "'": 39, '"': 34}


class AsmError(Exception):
    pass


def unescape(body):
    out, i = [], 0
    while i < len(body):
        if body[i] == '\\':
            if i + 1 >= len(body) or body[i + 1] not in ESCAPES:
                raise AsmError(f'bad escape in {body!r}')
            out.append(ESCAPES[body[i + 1]])
            i += 2
        else:
            out.append(ord(body[i]))
            i += 1
    return out


def split_line(line):
    """Strip the comment and split operands at commas outside quotes."""
    parts, cur, quote, i = [], '', None, 0
    while i < len(line):
        ch = line[i]
        if quote:
            cur += ch
            if ch == '\\' and i + 1 < len(line):
                cur += line[i + 1]
                i += 1
            elif ch == quote:
                quote = None
        elif ch in '\'"':
            quote = ch
            cur += ch
        elif ch == ';':
            break
        elif ch == ',':
            parts.append(cur.strip())
            cur = ''
        else:
            cur += ch
        i += 1
    if quote:
        raise AsmError('unterminated quote')
    parts.append(cur.strip())
    return parts


TOKEN = re.compile(r"\s*(0[xX][0-9a-fA-F]+|\d+|'(?:\\.|[^'\\])'|[A-Za-z_.][\w.]*|[-+*()])")


class Expr:
    """Recursive-descent evaluator for + - * ( ) over numbers and symbols."""

    def __init__(self, text, symbols, final):
        self.toks, pos = [], 0
        text = text.strip()
        while pos < len(text):
            mt = TOKEN.match(text, pos)
            if not mt:
                raise AsmError(f'cannot parse expression {text!r}')
            self.toks.append(mt.group(1))
            pos = mt.end()
        self.symbols, self.final, self.i = symbols, final, 0

    def value(self):
        v = self.sum()
        if self.i != len(self.toks):
            raise AsmError(f'unexpected {self.toks[self.i]!r} in expression')
        return v

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else None

    def sum(self):
        v = self.product()
        while self.peek() in ('+', '-'):
            op = self.toks[self.i]
            self.i += 1
            w = self.product()
            v = v + w if op == '+' else v - w
        return v

    def product(self):
        v = self.unary()
        while self.peek() == '*':
            self.i += 1
            v *= self.unary()
        return v

    def unary(self):
        t = self.peek()
        if t is None:
            raise AsmError('expression ends too early')
        self.i += 1
        if t == '-':
            return -self.unary()
        if t == '+':
            return self.unary()
        if t == '(':
            v = self.sum()
            if self.peek() != ')':
                raise AsmError('missing )')
            self.i += 1
            return v
        if t[0].isdigit():
            return int(t, 0)
        if t[0] == "'":
            chars = unescape(t[1:-1])
            if len(chars) != 1:
                raise AsmError(f'bad character literal {t}')
            return chars[0]
        if t in self.symbols:
            return self.symbols[t]
        if self.final:
            raise AsmError(f'undefined symbol {t!r}')
        return 0


def reg(text):
    mt = re.fullmatch(r'[rR](\d+)', text.strip())
    if not mt or int(mt.group(1)) > 15:
        raise AsmError(f'expected a register r0..r15, got {text!r}')
    return 2 * int(mt.group(1))


def check_range(v, lo, hi, what):
    if not lo <= v <= hi:
        raise AsmError(f'{what} {v} is out of range {lo}..{hi}')
    return v


def assemble(source):
    """Return (memory: dict addr -> byte, listing lines, entry, stacks)."""
    symbols = {}
    for final in (False, True):
        mem, listing, addr = {}, [], None
        entry = stacks = None
        for lineno, line in enumerate(source.splitlines(), 1):
            try:
                text = line
                mt = re.match(r'\s*([A-Za-z_.][\w.]*):', text)
                if mt:
                    if not final:
                        if mt.group(1) in symbols:
                            raise AsmError(f'label {mt.group(1)!r} defined twice')
                        if addr is None:
                            raise AsmError('label before the first .org')
                        symbols[mt.group(1)] = addr
                    text = text[mt.end():]
                parts = split_line(text)
                head = parts[0].split(None, 1)
                if not head:
                    listing.append((None, b'', line))
                    continue
                name = head[0].upper()
                ops = ([head[1].strip()] if len(head) > 1 else []) + parts[1:]
                ops = [o for o in ops if o != ''] if ops != [''] else []
                ev = lambda e: Expr(e, symbols, final).value()
                start, data = addr, []

                if name == '.ORG':
                    addr = check_range(Expr(ops[0], symbols, True).value(), 0, 0xFFFF, 'address')
                    listing.append((addr, b'', line))
                    continue
                if name == '.EQU':
                    if len(ops) != 2:
                        raise AsmError('.equ needs a name and a value')
                    if not final:
                        symbols[ops[0]] = Expr(ops[1], symbols, True).value()
                    listing.append((None, b'', line))
                    continue
                if name == '.ENTRY':
                    entry = ev(ops[0])
                    listing.append((None, b'', line))
                    continue
                if name == '.STACKS':
                    if len(ops) != 2:
                        raise AsmError('.stacks needs dsp, rsp')
                    stacks = (ev(ops[0]) & 0xFFFF, ev(ops[1]) & 0xFFFF)
                    listing.append((None, b'', line))
                    continue
                if addr is None:
                    raise AsmError('code or data before the first .org')
                if name == '.BYTE':
                    data = [check_range(ev(o), -128, 255, 'byte') & 0xFF for o in ops]
                elif name == '.WORD':
                    for o in ops:
                        v = check_range(ev(o), -32768, 65535, 'word') & 0xFFFF
                        data += [v & 0xFF, v >> 8]
                elif name == '.ASCII':
                    if len(ops) != 1 or not re.fullmatch(r'"(?:\\.|[^"\\])*"', ops[0]):
                        raise AsmError('.ascii needs one "string"')
                    data = unescape(ops[0][1:-1])
                elif name == '.SPACE':
                    data = [0] * check_range(Expr(ops[0], symbols, True).value(), 0, 65536, 'size')
                elif name in OPS:
                    code, shape = OPS[name]
                    if len(ops) != NOPS[shape]:
                        raise AsmError(f'{name} takes {NOPS[shape]} operand(s), got {len(ops)}')
                    nxt = addr + SIZE[shape]

                    def rel(e):
                        off = ev(e) - nxt
                        if final:
                            check_range(off, -128, 127, 'branch offset')
                        return off & 0xFF

                    def w16(e):
                        v = check_range(ev(e), -32768, 65535, 'value') & 0xFFFF
                        return [v & 0xFF, v >> 8]

                    data = [code]
                    if shape == 'R':
                        data += [reg(ops[0])]
                    elif shape == 'U8':
                        data += [check_range(ev(ops[0]), 0, 255, 'service number')]
                    elif shape == 'RR':
                        data += [reg(ops[0]), reg(ops[1])]
                    elif shape == 'RS8':
                        data += [reg(ops[0]), check_range(ev(ops[1]), -128, 127, 'immediate') & 0xFF]
                    elif shape == 'RB':
                        data += [reg(ops[0]), rel(ops[1])]
                    elif shape == 'I16':
                        data += w16(ops[0])
                    elif shape == 'RM':
                        mm = re.fullmatch(r'\[\s*([rR]\d+)\s*(?:\+(.+))?\]', ops[1])
                        if not mm:
                            raise AsmError(f'expected [rb] or [rb+offset], got {ops[1]!r}')
                        off = ev(mm.group(2)) if mm.group(2) else 0
                        data += [reg(ops[0]), reg(mm.group(1)), check_range(off, 0, 255, 'offset')]
                    elif shape == 'RRB':
                        data += [reg(ops[0]), reg(ops[1]), rel(ops[2])]
                    elif shape == 'RI16':
                        data += [reg(ops[0])] + w16(ops[1])
                else:
                    raise AsmError(f'unknown mnemonic or directive {head[0]!r}')

                for i, b in enumerate(data):
                    a = (addr + i) & 0xFFFF
                    if final and a in mem:
                        raise AsmError(f'address {a:04X} is written twice')
                    mem[a] = b
                addr += len(data)
                listing.append((start, bytes(data), line))
            except AsmError as e:
                raise AsmError(f'line {lineno}: {e}\n    {line.strip()}') from None
    return mem, listing, entry, stacks


def make_image(mem, entry, stacks):
    if not mem:
        raise AsmError('nothing to assemble')
    if stacks is None:
        raise AsmError('missing .stacks dsp, rsp')
    lo, hi = min(mem), max(mem)
    body = bytes(mem.get(a, 0) for a in range(lo, hi + 1))
    entry = lo if entry is None else entry
    w = lambda v: bytes([v & 0xFF, (v >> 8) & 0xFF])
    return b'V16\0' + w(lo) + w(len(body)) + w(entry) + w(stacks[0]) + w(stacks[1]) + body


def main():
    args = sys.argv[1:]
    out = lst = None
    if '-o' in args:
        i = args.index('-o'); out = args[i + 1]; del args[i:i + 2]
    if '-l' in args:
        i = args.index('-l'); lst = args[i + 1]; del args[i:i + 2]
    if len(args) != 1:
        sys.exit(__doc__)
    src = args[0]
    out = out or re.sub(r'\.[^./]*$', '', src) + '.v16'
    try:
        mem, listing, entry, stacks = assemble(open(src).read())
        img = make_image(mem, entry, stacks)
    except AsmError as e:
        sys.exit(f'{src}: {e}')
    open(out, 'wb').write(img)
    if lst:
        with open(lst, 'w') as f:
            for a, data, line in listing:
                hexb = ' '.join(f'{b:02X}' for b in data[:4]) + (' ...' if len(data) > 4 else '')
                f.write(f"{'' if a is None else f'{a:04X}':4}  {hexb:<14} {line}\n")
    print(f'{out}: {len(img) - 14} bytes at {min(mem):04X}, entry {entry or min(mem):04X}')


if __name__ == '__main__':
    main()
