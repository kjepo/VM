"""Differential tests for VM16 implementations.

Every test program runs twice: on the implementation under test, and on a
reference interpreter written directly from vm16-spec.tex. The two must agree
on the exit status or trap, all registers, both stack pointers, the whole
usable memory region and the output.

Usage:  python vm16-test.py --z80 vm16-z80.bin vm16-z80.lst
        python vm16-test.py --c ./vm16

The Z80 backend runs vm16-z80.asm in an emulated Z80 and needs the `z80`
package from PyPI. The C backend runs the vm16 executable built from vm16.c.
"""

import os
import random
import re
import subprocess
import sys
import tempfile

MEM_LO, MEM_HI = 0x2000, 0xEFFF
IMAGE = 0xF000

# ---------------------------------------------------------------- encoder

OPS = {
    'HALT': (0x00, 'A'), 'NOP': (0x01, 'A'), 'LI': (0x02, 'RI16'), 'MOV': (0x03, 'RR'),
    'LW': (0x04, 'RRI8'), 'SW': (0x05, 'RRI8'), 'LB': (0x06, 'RRI8'), 'SB': (0x07, 'RRI8'),
    'LWA': (0x08, 'RI16'), 'SWA': (0x09, 'RI16'),
    'ADD': (0x10, 'RR'), 'SUB': (0x11, 'RR'), 'AND': (0x12, 'RR'), 'OR': (0x13, 'RR'),
    'XOR': (0x14, 'RR'), 'MUL': (0x15, 'RR'), 'DIVU': (0x16, 'RR'),
    'NOT': (0x18, 'R'), 'NEG': (0x19, 'R'), 'SHL': (0x1A, 'R'), 'SHR': (0x1B, 'R'),
    'SAR': (0x1C, 'R'), 'ADDI': (0x1D, 'RI8'),
    'BEQ': (0x20, 'RRI8'), 'BNE': (0x21, 'RRI8'), 'BLT': (0x22, 'RRI8'), 'BGE': (0x23, 'RRI8'),
    'BLTU': (0x24, 'RRI8'), 'BGEU': (0x25, 'RRI8'), 'BZ': (0x26, 'RI8'), 'BNZ': (0x27, 'RI8'),
    'JMP': (0x28, 'I16'), 'JR': (0x29, 'R'),
    'PUSH': (0x30, 'R'), 'POP': (0x31, 'R'), 'GETDSP': (0x32, 'R'), 'SETDSP': (0x33, 'R'),
    'GETRSP': (0x34, 'R'), 'SETRSP': (0x35, 'R'),
    'CALL': (0x38, 'I16'), 'CALLR': (0x39, 'R'), 'RET': (0x3A, 'A'), 'SYS': (0x3F, 'I8'),
}
SIZE = {'A': 1, 'R': 2, 'I8': 2, 'RR': 3, 'RI8': 3, 'I16': 3, 'RRI8': 4, 'RI16': 4}
FORMAT = {code: fmt for code, fmt in OPS.values()}
BRANCHES = {'BEQ', 'BNE', 'BLT', 'BGE', 'BLTU', 'BGEU', 'BZ', 'BNZ'}


class Asm:
    """Two-pass encoder. Operands are register numbers or ints; jump and
    branch targets may be label names."""

    def __init__(self, org):
        self.org = org
        self.items = []         # (addr, mnemonic, operands) or raw bytes

    def here(self):
        return self.org + sum(SIZE[OPS[m][1]] if m else len(ops)
                              for _, m, ops in self.items)

    def label(self, name):
        self.items.append((name, None, b''))

    def raw(self, data):
        self.items.append((None, None, bytes(data)))

    def __getattr__(self, mnemonic):
        if mnemonic.upper() not in OPS:
            raise AttributeError(mnemonic)
        return lambda *ops: self.items.append((None, mnemonic.upper(), ops))

    def build(self):
        labels, addr = {}, self.org
        for name, m, ops in self.items:
            if name is not None:
                labels[name] = addr
            addr += SIZE[OPS[m][1]] if m else len(ops)
        out, addr = bytearray(), self.org
        for name, m, ops in self.items:
            if m is None:
                out += ops
                addr += len(ops)
                continue
            code, fmt = OPS[m]
            nxt = addr + SIZE[fmt]
            val = lambda x: labels[x] if isinstance(x, str) else x
            ops = list(ops)
            if m in BRANCHES:
                off = val(ops[-1]) - nxt if isinstance(ops[-1], str) else ops[-1]
                assert -128 <= off <= 127, (m, off)
                ops[-1] = off & 0xFF
            b = [code]
            if fmt == 'R':
                b += [2 * ops[0]]
            elif fmt == 'I8':
                b += [ops[0] & 0xFF]
            elif fmt == 'RR':
                b += [2 * ops[0], 2 * ops[1]]
            elif fmt == 'RI8':
                b += [2 * ops[0], ops[1] & 0xFF]
            elif fmt == 'I16':
                v = val(ops[0])
                b += [v & 0xFF, v >> 8]
            elif fmt == 'RRI8':
                b += [2 * ops[0], 2 * ops[1], ops[2] & 0xFF]
            elif fmt == 'RI16':
                v = val(ops[1]) & 0xFFFF
                b += [2 * ops[0], v & 0xFF, v >> 8]
            out += bytes(b)
            addr = nxt
        return bytes(out), labels


def image(body, load=MEM_LO, entry=None, dsp=0xE000, rsp=0xF000, magic=b'V16\0'):
    entry = load if entry is None else entry
    w = lambda v: bytes([v & 0xFF, (v >> 8) & 0xFF])
    return magic + w(load) + w(len(body)) + w(entry) + w(dsp) + w(rsp) + body

# ---------------------------------------------------------------- reference


class RefVM:
    def __init__(self, img, inp=b''):
        self.mem = bytearray(65536)
        self.inp, self.out = list(inp), bytearray()
        self.steps = 0
        if img[:4] != b'V16\0':
            self.result = ('reject',)
            return
        load, length, entry, dsp, rsp = (img[4 + 2 * i] | img[5 + 2 * i] << 8 for i in range(5))
        if load < MEM_LO or load + length > MEM_HI + 1:
            self.result = ('reject',)
            return
        self.mem[load:load + length] = img[14:14 + length]
        self.r = [0] * 16
        self.pc, self.dsp, self.rsp = entry, dsp, rsp
        self.result = None

    def rw(self, a):
        return self.mem[a & 0xFFFF] | self.mem[(a + 1) & 0xFFFF] << 8

    def ww(self, a, v):
        self.mem[a & 0xFFFF] = v & 0xFF
        self.mem[(a + 1) & 0xFFFF] = (v >> 8) & 0xFF

    def run(self, limit=2_000_000):
        while self.result is None and self.steps < limit:
            self.step()
        return self.result

    def step(self):
        self.steps += 1
        m, r = self.mem, self.r
        start = self.pc
        op = m[self.pc]
        fmt = FORMAT.get(op)
        if fmt is None:
            self.result = ('trap', 1, start)
            return
        b = [m[(self.pc + i) & 0xFFFF] for i in range(SIZE[fmt])]
        self.pc = nxt = (self.pc + SIZE[fmt]) & 0xFFFF
        a = b[1] // 2 if len(b) > 1 else 0
        c = b[2] // 2 if len(b) > 2 else 0
        i16 = (b[-2] | b[-1] << 8) if fmt in ('I16', 'RI16') else None
        i8 = b[-1]
        sx = i8 - 256 if i8 > 127 else i8
        s = lambda v: v - 65536 if v & 0x8000 else v
        M = 0xFFFF

        def branch(cond):
            if cond:
                self.pc = (nxt + sx) & M

        if op == 0x00: self.result = ('halt', r[0])
        elif op == 0x01: pass
        elif op == 0x02: r[a] = i16
        elif op == 0x03: r[a] = r[c]
        elif op == 0x04: r[a] = self.rw(r[c] + i8)
        elif op == 0x05: self.ww(r[c] + i8, r[a])
        elif op == 0x06: r[a] = m[(r[c] + i8) & M]
        elif op == 0x07: m[(r[c] + i8) & M] = r[a] & 0xFF
        elif op == 0x08: r[a] = self.rw(i16)
        elif op == 0x09: self.ww(i16, r[a])
        elif op == 0x10: r[a] = (r[a] + r[c]) & M
        elif op == 0x11: r[a] = (r[a] - r[c]) & M
        elif op == 0x12: r[a] &= r[c]
        elif op == 0x13: r[a] |= r[c]
        elif op == 0x14: r[a] ^= r[c]
        elif op == 0x15: r[a] = (r[a] * r[c]) & M
        elif op == 0x16:
            n, d = r[a], r[c]
            q, rem = (n // d, n % d) if d else (0xFFFF, n)
            r[15] = rem
            r[a] = q
        elif op == 0x18: r[a] ^= M
        elif op == 0x19: r[a] = (-r[a]) & M
        elif op == 0x1A: r[a] = (r[a] << 1) & M
        elif op == 0x1B: r[a] >>= 1
        elif op == 0x1C: r[a] = (r[a] >> 1) | (r[a] & 0x8000)
        elif op == 0x1D: r[a] = (r[a] + sx) & M
        elif op == 0x20: branch(r[a] == r[c])
        elif op == 0x21: branch(r[a] != r[c])
        elif op == 0x22: branch(s(r[a]) < s(r[c]))
        elif op == 0x23: branch(s(r[a]) >= s(r[c]))
        elif op == 0x24: branch(r[a] < r[c])
        elif op == 0x25: branch(r[a] >= r[c])
        elif op == 0x26: branch(r[a] == 0)
        elif op == 0x27: branch(r[a] != 0)
        elif op == 0x28: self.pc = i16
        elif op == 0x29: self.pc = r[a]
        elif op == 0x30: self.dsp = (self.dsp - 2) & M; self.ww(self.dsp, r[a])
        elif op == 0x31: r[a] = self.rw(self.dsp); self.dsp = (self.dsp + 2) & M
        elif op == 0x32: r[a] = self.dsp
        elif op == 0x33: self.dsp = r[a]
        elif op == 0x34: r[a] = self.rsp
        elif op == 0x35: self.rsp = r[a]
        elif op in (0x38, 0x39):
            t = i16 if op == 0x38 else r[a]
            self.rsp = (self.rsp - 2) & M
            self.ww(self.rsp, nxt)
            self.pc = t
        elif op == 0x3A: self.pc = self.rw(self.rsp); self.rsp = (self.rsp + 2) & M
        elif op == 0x3F:
            if i8 == 0: self.out.append(r[0] & 0xFF)
            elif i8 == 1: r[0] = self.inp.pop(0) if self.inp else 0xFFFF
            elif i8 == 2: r[0], r[1] = MEM_LO, MEM_HI
            elif i8 == 3: pass
            else: self.result = ('trap', 3, start)

# ---------------------------------------------------------------- Z80 side


class Z80VM:
    def __init__(self, binfile, lstfile):
        self.code = open(binfile, 'rb').read()
        syms = {}
        for line in open(lstfile, encoding='latin-1'):
            mt = re.match(r'^(\w+)\s+=\s+\$([0-9A-F]{4})', line)
            if mt:
                syms[mt.group(1)] = int(mt.group(2), 16)
        self.sym = syms

    def run(self, img, inp=b'', max_ticks=400_000_000):
        import z80
        m = z80.Z80Machine()
        m.set_memory_block(0x0100, self.code)
        m.set_memory_block(IMAGE, img)
        out, inp = bytearray(), list(inp)

        def on_out(port, value):
            if port & 0xFF == 1:
                out.append(value)

        def on_in(port):
            if port & 0xFF == 2:
                return 1 if inp else 0
            return inp.pop(0) if inp else 0

        m.set_output_callback(on_out)
        m.set_input_callback(on_in)
        m.pc = self.sym['test_main']
        stop = self.sym['result_a'] - 1         # address of the final 'halt'
        m.set_breakpoint(stop)
        m.ticks_to_stop = max_ticks
        while m.pc != stop and m.ticks_to_stop > 0:
            m.run()                             # returns every ~100k T-states
        assert m.pc == stop, 'Z80 did not reach the final HALT'
        ticks = max_ticks - m.ticks_to_stop
        # vm_run's results are still in A and HL at the final halt
        a, hl = m.a, m.hl
        mem = bytes(m.memory)
        regs = [mem[0x180 + 2 * i] | mem[0x181 + 2 * i] << 8 for i in range(16)]
        w = lambda s: mem[self.sym[s]] | mem[self.sym[s] + 1] << 8
        if a == 0:
            result = ('halt', hl)
        elif a == 0xFF:
            result = ('reject',)
        else:
            result = ('trap', a, hl)
        return dict(result=result, regs=regs, dsp=w('vm_dsp'), rsp=w('vm_rsp'),
                    mem=mem[MEM_LO:MEM_HI + 1], out=bytes(out), ticks=ticks)


# ---------------------------------------------------------------- C side


class CVM:
    def __init__(self, exe):
        self.exe = exe
        self.dir = tempfile.mkdtemp(prefix='vm16-test-')

    def run(self, img, inp=b'', check=False):
        imgfile = os.path.join(self.dir, 'image.v16')
        dumpfile = os.path.join(self.dir, 'dump.bin')
        with open(imgfile, 'wb') as f:
            f.write(img)
        cmd = [self.exe, '-r', f'{MEM_LO:04X}-{MEM_HI:04X}', '-d', dumpfile, imgfile]
        if check:
            cmd.insert(1, '-c')
        p = subprocess.run(cmd, input=inp, capture_output=True)
        d = open(dumpfile, 'rb').read()
        w = lambda i: d[i] | d[i + 1] << 8
        kind, code, value = d[0], d[1], w(2)
        result = [('halt', value), ('trap', code, value), ('reject',)][kind]
        return dict(result=result, regs=[w(4 + 2 * i) for i in range(16)], dsp=w(36), rsp=w(38),
                    steps=int.from_bytes(d[40:48], 'little'),
                    mem=d[48 + MEM_LO:48 + MEM_HI + 1], out=p.stdout, exitcode=p.returncode)


# ---------------------------------------------------------------- tests

failures = 0
checks = 0


def compare(name, img, z, inp=b''):
    global failures, checks
    checks += 1
    ref = RefVM(img, inp)
    ref.run()
    got = z.run(img, inp)
    problems = []
    if got['result'] != ref.result:
        problems.append(f"result {got['result']} != {ref.result}")
    if ref.result and ref.result[0] != 'reject':
        if got['regs'] != ref.r:
            problems.append('regs ' + ', '.join(
                f'r{i}={g:#06x}/{e:#06x}' for i, (g, e) in enumerate(zip(got['regs'], ref.r)) if g != e))
        if (got['dsp'], got['rsp']) != (ref.dsp, ref.rsp):
            problems.append(f"dsp/rsp {got['dsp']:#x},{got['rsp']:#x} != {ref.dsp:#x},{ref.rsp:#x}")
        if got['mem'] != bytes(ref.mem[MEM_LO:MEM_HI + 1]):
            diff = next(i for i in range(len(got['mem'])) if got['mem'][i] != ref.mem[MEM_LO + i])
            problems.append(f'memory differs first at {MEM_LO + diff:#06x}')
    if got['out'] != bytes(ref.out):
        problems.append(f"output {got['out']!r} != {bytes(ref.out)!r}")
    if problems:
        failures += 1
        print(f'FAIL {name}: ' + '; '.join(problems))
    return got, ref


def random_regs(a, rnd):
    special = [0, 1, 2, 0x7FFF, 0x8000, 0x8001, 0xFFFF, 0xFFFE, 0x00FF, 0x0100]
    for i in range(16):
        a.li(i, rnd.choice(special) if rnd.random() < 0.3 else rnd.randrange(65536))


def main():
    if len(sys.argv) == 4 and sys.argv[1] == '--z80':
        z = Z80VM(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == '--c':
        z = CVM(sys.argv[2])
    else:
        sys.exit(__doc__)
    rnd = random.Random(16)

    # Encoder agrees with the hand-assembled example in the spec.
    a = Asm(0x0300)
    a.label('cons'); a.lwa(0, 0x0200); a.bz(0, 'cons_gc'); a.lw(3, 0, 2); a.swa(3, 0x0200)
    a.sw(1, 0, 0); a.sw(2, 0, 2); a.ret()
    a.label('cons_gc'); a.call(0x0400); a.jmp('cons')
    spec = bytes.fromhex('08000002 260011 04060002 09060002 05020000 05040002 3A 380004 280003'.replace(' ', ''))
    global checks, failures
    checks += 1
    if a.build()[0] != spec:
        failures += 1
        print('FAIL spec example encoding:', a.build()[0].hex(), '!=', spec.hex())

    # Two-register arithmetic, every operand pair including ra == rb.
    for mn in ['MOV', 'ADD', 'SUB', 'AND', 'OR', 'XOR', 'MUL', 'DIVU']:
        for k in range(40):
            a = Asm(MEM_LO)
            random_regs(a, rnd)
            ra, rb = rnd.randrange(16), rnd.randrange(16)
            if k < 3:
                rb = ra
            if mn == 'DIVU' and k in (3, 4):
                a.li(rb, 0)                     # division by zero
            if mn == 'DIVU' and k == 5:
                ra = 15                          # quotient must win over remainder
            getattr(a, mn.lower())(ra, rb)
            a.halt()
            compare(f'{mn} r{ra},r{rb} #{k}', image(a.build()[0]), z)

    # One-register operations and ADDI.
    for mn in ['NOT', 'NEG', 'SHL', 'SHR', 'SAR']:
        for k in range(20):
            a = Asm(MEM_LO)
            random_regs(a, rnd)
            getattr(a, mn.lower())(rnd.randrange(16))
            a.halt()
            compare(f'{mn} #{k}', image(a.build()[0]), z)
    for k in range(40):
        a = Asm(MEM_LO)
        random_regs(a, rnd)
        a.addi(rnd.randrange(16), rnd.choice([0, 1, -1, 127, -128]) if k < 10 else rnd.randrange(-128, 128))
        a.halt()
        compare(f'ADDI #{k}', image(a.build()[0]), z)

    # Branches: taken and not taken, forward and backward.
    for mn in ['BEQ', 'BNE', 'BLT', 'BGE', 'BLTU', 'BGEU', 'BZ', 'BNZ']:
        for k in range(40):
            a = Asm(MEM_LO)
            random_regs(a, rnd)
            ra, rb = rnd.randrange(16), rnd.randrange(16)
            if k % 4 == 0:
                a.mov(rb, ra)                    # equal operands
            if k % 4 == 1:
                a.li(ra, 0)
            backward = k % 3 == 0
            if backward:
                a.jmp('test')
                a.label('target'); a.li(0, 2); a.halt()
                a.label('test')
            ops = (ra, 'target') if mn in ('BZ', 'BNZ') else (ra, rb, 'target')
            getattr(a, mn.lower())(*ops)
            a.li(0, 1); a.halt()
            if not backward:
                a.label('target'); a.li(0, 2); a.halt()
            compare(f'{mn} #{k}', image(a.build()[0]), z)

    # Memory: aligned and unaligned words, bytes, absolute addressing.
    for k in range(60):
        a = Asm(MEM_LO)
        random_regs(a, rnd)
        base = rnd.randrange(0x3000, 0xE000)
        ra, rb = rnd.randrange(16), rnd.randrange(16)
        off = rnd.randrange(256)
        a.li(rb, base)
        mn = rnd.choice(['LW', 'SW', 'LB', 'SB'])
        getattr(a, mn.lower())(ra, rb, off)
        a.lwa(rnd.randrange(16), base + rnd.randrange(-40, 40))
        a.swa(rnd.randrange(16), base + rnd.randrange(-40, 40))
        a.halt()
        img = image(a.build()[0])
        compare(f'{mn} r{ra},[r{rb}+{off}] #{k}', img, z)

    # Stacks, calls and returns.
    a = Asm(MEM_LO)
    random_regs(a, rnd)
    for i in range(6):
        a.push(i)
    a.pop(10); a.pop(11); a.getdsp(12); a.getrsp(13)
    a.call('f'); a.li(14, 'g'); a.callr(14)
    a.li(2, 0xD000); a.setdsp(2); a.push(2); a.li(3, 0xC000); a.setrsp(3); a.call('f')
    a.li(0, 7); a.halt()
    a.label('f'); a.push(0); a.call('g'); a.pop(5); a.ret()
    a.label('g'); a.getrsp(6); a.addi(9, 1); a.ret()
    compare('stack/call/ret', image(a.build()[0]), z)

    # JMP and JR.
    a = Asm(MEM_LO)
    a.jmp('x'); a.li(0, 99); a.halt()
    a.label('x'); a.li(4, 'y'); a.jr(4); a.li(0, 98); a.halt()
    a.label('y'); a.li(0, 5); a.halt()
    compare('JMP/JR', image(a.build()[0]), z)

    # System calls.
    a = Asm(MEM_LO)
    for ch in b'Hello, VM16!\n':
        a.li(0, ch); a.sys(0)
    a.label('echo'); a.sys(1); a.li(1, 0xFFFF); a.beq(0, 1, 'done'); a.sys(0); a.jmp('echo')
    a.label('done'); a.sys(3); a.sys(2); a.halt()
    compare('SYS putc/getc/meminfo/debug', image(a.build()[0]), z, inp=b'echo me')
    for n in (4, 31, 127, 200):
        a = Asm(MEM_LO); a.nop(); a.sys(n); a.halt()
        compare(f'SYS {n} traps', image(a.build()[0]), z)

    # Reserved opcodes trap with the right PC.
    for op in (0x0A, 0x0F, 0x17, 0x1E, 0x2A, 0x36, 0x3B, 0x3E, 0x40, 0x80, 0xFF):
        a = Asm(MEM_LO); a.li(1, 1); a.raw([op, 0, 0, 0]); a.halt()
        compare(f'opcode {op:#04x} traps', image(a.build()[0]), z)

    # The loader rejects bad images.
    body = Asm(MEM_LO); body.halt(); body = body.build()[0]
    compare('bad magic', image(body, magic=b'V17\0'), z)
    compare('load below LO', image(body, load=MEM_LO - 1), z)
    compare('body past HI', image(b'\0' * 2, load=MEM_HI), z)
    compare('body ends at HI', image(b'\0', load=MEM_HI), z)
    compare('empty body', image(b'', entry=MEM_LO), z)

    # Benchmark: iterative sum and recursive Fibonacci.
    a = Asm(MEM_LO)
    a.li(0, 0); a.li(1, 1000); a.li(2, 0)
    a.label('loop'); a.add(0, 1); a.addi(1, -1); a.bnz(1, 'loop')
    a.li(3, 18); a.call('fib'); a.halt()
    a.label('fib')                       # r0 = fib(r3), uses the data stack
    a.li(4, 2); a.bltu(3, 4, 'fib_small')
    a.push(3); a.addi(3, -1); a.call('fib'); a.pop(3)
    a.push(0); a.addi(3, -2); a.call('fib'); a.pop(4); a.add(0, 4); a.addi(3, 2); a.ret()
    a.label('fib_small'); a.mov(0, 3); a.ret()
    img = image(a.build()[0])
    got, ref = compare('benchmark', img, z)
    if isinstance(z, Z80VM) and ref.result[0] == 'halt':
        print(f"benchmark: fib(18) = {ref.result[1]}, {ref.steps} VM instructions, "
              f"{got['ticks']} Z80 T-states, {got['ticks'] / ref.steps:.1f} T-states per VM "
              f"instruction, {got['ticks'] / 4e6:.2f} s at 4 MHz")
    if isinstance(z, CVM):
        c_only_checks(z, a)
    print(f'{checks} checks, {failures} failures')
    sys.exit(1 if failures else 0)


def c_only_checks(z, bench):
    """Checking mode (-c), exit codes and speed: things only the C
    implementation has."""
    global checks, failures

    def expect(name, got, want):
        global checks, failures
        checks += 1
        if got != want:
            failures += 1
            print(f'FAIL {name}: got {got}, want {want}')

    def prog(*emit):
        a = Asm(MEM_LO)
        for e in emit:
            e(a)
        return image(a.build()[0])

    bad_reg = image(bytes([0x03, 0x02, 0x03, 0x00]))           # MOV with operand byte 03
    expect('-c: invalid register operand', z.run(bad_reg, check=True)['result'], ('trap', 2, MEM_LO))
    expect('no -c: invalid register operand runs', z.run(bad_reg)['result'][0], 'halt')
    expect('-c: load outside region', z.run(prog(lambda a: a.lwa(0, 0x1FFF), lambda a: a.halt()),
                                            check=True)['result'], ('trap', 4, MEM_LO))
    expect('-c: word straddling HI', z.run(prog(lambda a: a.li(1, MEM_HI), lambda a: a.lw(0, 1, 0),
                                                lambda a: a.halt()), check=True)['result'],
           ('trap', 4, MEM_LO + 4))
    expect('-c: data stack', z.run(prog(lambda a: a.li(1, MEM_LO + 1), lambda a: a.setdsp(1),
                                        lambda a: a.push(1), lambda a: a.halt()),
                                   check=True)['result'], ('trap', 5, MEM_LO + 6))
    expect('-c: return stack', z.run(prog(lambda a: a.ret()), check=True)['result'][:2], ('trap', 6))
    expect('-c: jump outside region', z.run(prog(lambda a: a.jmp(0x1000)), check=True)['result'],
           ('trap', 4, 0x1000))
    expect('-c: valid program unaffected', z.run(prog(lambda a: a.li(0, 3), lambda a: a.halt()),
                                                 check=True)['result'], ('halt', 3))
    expect('exit code after HALT', z.run(prog(lambda a: a.li(0, 0x1234), lambda a: a.halt()))['exitcode'],
           0x34)
    expect('exit code after trap', z.run(prog(lambda a: a.sys(9)))['exitcode'], 128 + 3)
    expect('exit code for rejected image', z.run(image(b'', load=0))['exitcode'], 125)

    # Speed: the same benchmark with a bigger argument.
    for item in bench.items:
        if item[1] == 'LI' and item[2] == (3, 18):
            bench.items[bench.items.index(item)] = (None, 'LI', (3, 27))
    img = image(bench.build()[0])
    path = os.path.join(z.dir, 'bench.v16')
    with open(path, 'wb') as f:
        f.write(img)
    p = subprocess.run([z.exe, '-s', path], capture_output=True, text=True)
    print('speed: fib(27) +', p.stderr.strip().removeprefix('vm16: '))


if __name__ == '__main__':
    main()
