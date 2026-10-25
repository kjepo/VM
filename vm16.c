/*
 * vm16.c - interpreter for VM16, specification version 0.1 (vm16-spec.tex)
 *
 * Build:  cc -O2 -Wall -Wextra -o vm16 vm16.c
 *         (add -DVM16_NO_GOTO to use a portable switch instead of computed goto)
 *
 * Usage:  vm16 [-c] [-s] [-r LO-HI] [-d DUMPFILE] IMAGE
 *
 *   -c          checking implementation: also trap on invalid register
 *               operands (code 2) and on memory or stack accesses outside
 *               the usable region (codes 4, 5, 6)
 *   -s          print instruction count and speed to stderr
 *   -r LO-HI    usable region in hex, default 0000-FFFF
 *   -d FILE     write the final machine state to FILE (used by the tests)
 *
 * SYS 0 writes to stdout, SYS 1 reads from stdin.
 * Exit status: r0 & 255 after HALT, 128 + code after a trap,
 * 125 if the image is rejected.
 */

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(__GNUC__) && !defined(VM16_NO_GOTO)
#define USE_GOTO 1
#else
#define USE_GOTO 0
#endif

enum {                                  /* opcodes */
    HALT = 0x00, NOP = 0x01, LI = 0x02, MOV = 0x03,
    LW = 0x04, SW = 0x05, LB = 0x06, SB = 0x07, LWA = 0x08, SWA = 0x09,
    ADD = 0x10, SUB = 0x11, AND = 0x12, OR = 0x13, XOR = 0x14, MUL = 0x15, DIVU = 0x16,
    NOT = 0x18, NEG = 0x19, SHL = 0x1A, SHR = 0x1B, SAR = 0x1C, ADDI = 0x1D,
    BEQ = 0x20, BNE = 0x21, BLT = 0x22, BGE = 0x23, BLTU = 0x24, BGEU = 0x25,
    BZ = 0x26, BNZ = 0x27, JMP = 0x28, JR = 0x29,
    PUSH = 0x30, POP = 0x31, GETDSP = 0x32, SETDSP = 0x33, GETRSP = 0x34, SETRSP = 0x35,
    CALL = 0x38, CALLR = 0x39, RET = 0x3A, SYS = 0x3F
};

enum {                                  /* trap codes, spec section 6 */
    T_OPCODE = 1, T_REG = 2, T_SYS = 3, T_MEM = 4, T_DSTACK = 5, T_RSTACK = 6
};

static const char *const trap_name[] = {
    "", "reserved opcode", "invalid register operand", "unassigned SYS service",
    "memory access outside the usable region", "data stack out of bounds",
    "return stack out of bounds"
};

/* Instruction length in bytes (0 = reserved opcode). */
static const uint8_t len[256] = {
    [HALT] = 1, [NOP] = 1, [LI] = 4, [MOV] = 3,
    [LW] = 4, [SW] = 4, [LB] = 4, [SB] = 4, [LWA] = 4, [SWA] = 4,
    [ADD] = 3, [SUB] = 3, [AND] = 3, [OR] = 3, [XOR] = 3, [MUL] = 3, [DIVU] = 3,
    [NOT] = 2, [NEG] = 2, [SHL] = 2, [SHR] = 2, [SAR] = 2, [ADDI] = 3,
    [BEQ] = 4, [BNE] = 4, [BLT] = 4, [BGE] = 4, [BLTU] = 4, [BGEU] = 4,
    [BZ] = 3, [BNZ] = 3, [JMP] = 3, [JR] = 2,
    [PUSH] = 2, [POP] = 2, [GETDSP] = 2, [SETDSP] = 2, [GETRSP] = 2, [SETRSP] = 2,
    [CALL] = 3, [CALLR] = 2, [RET] = 1, [SYS] = 2,
};

/* Number of register operands; they always follow the opcode byte. */
static const uint8_t nreg[256] = {
    [LI] = 1, [MOV] = 2, [LW] = 2, [SW] = 2, [LB] = 2, [SB] = 2, [LWA] = 1, [SWA] = 1,
    [ADD] = 2, [SUB] = 2, [AND] = 2, [OR] = 2, [XOR] = 2, [MUL] = 2, [DIVU] = 2,
    [NOT] = 1, [NEG] = 1, [SHL] = 1, [SHR] = 1, [SAR] = 1, [ADDI] = 1,
    [BEQ] = 2, [BNE] = 2, [BLT] = 2, [BGE] = 2, [BLTU] = 2, [BGEU] = 2,
    [BZ] = 1, [BNZ] = 1, [JR] = 1,
    [PUSH] = 1, [POP] = 1, [GETDSP] = 1, [SETDSP] = 1, [GETRSP] = 1, [SETRSP] = 1,
    [CALLR] = 1,
};

typedef struct {
    uint8_t mem[65536];
    uint16_t r[16];
    uint16_t pc, dsp, rsp;              /* after vm_run, pc is the last instruction */
    uint16_t lo, hi;                    /* usable region */
    int check;                          /* nonzero: checking implementation */
    uint64_t steps;                     /* instructions executed */
    FILE *in, *out;
} VM;

static int in_region(const VM *vm, uint16_t a, unsigned n)
{
    for (unsigned i = 0; i < n; i++) {
        uint16_t x = (uint16_t)(a + i);
        if (x < vm->lo || x > vm->hi)
            return 0;
    }
    return 1;
}

/* Checks made before executing an instruction in checking mode. */
static int precheck(const VM *vm, uint16_t pc, unsigned op)
{
    unsigned n = len[op];
    if (!in_region(vm, pc, n ? n : 1))
        return T_MEM;
    for (unsigned i = 1; i <= nreg[op]; i++)
        if (vm->mem[(uint16_t)(pc + i)] & ~0x1Eu)
            return T_REG;
    return 0;                           /* a reserved opcode traps when dispatched */
}

static void debug_dump(const VM *vm, uint16_t pc, uint16_t dsp, uint16_t rsp)
{
    fprintf(stderr, "vm16: SYS 3 at %04X  DSP=%04X RSP=%04X\n", pc, dsp, rsp);
    for (int i = 0; i < 16; i++)
        fprintf(stderr, "  r%-2d=%04X%s", i, vm->r[i], i % 8 == 7 ? "\n" : "");
}

/*
 * Run until HALT or a trap. Returns 0 after HALT (exit status in r0), or the
 * trap code. Either way vm->pc is the address of the instruction that stopped.
 */
static int vm_run(VM *vm)
{
    uint8_t *const m = vm->mem;
    uint16_t *const r = vm->r;
    const int check = vm->check;
    uint16_t pc = vm->pc, dsp = vm->dsp, rsp = vm->rsp, start = pc;
    uint64_t steps = vm->steps;
    unsigned op;
    int trap = 0;

/* Operand fetch. pc is a uint16_t, so it wraps at 0xFFFF by itself. */
#define B()         m[pc++]
#define REG()       r[(B() >> 1) & 15]
#define IMM16()     (pc += 2, (uint16_t)(m[(uint16_t)(pc - 2)] | m[(uint16_t)(pc - 1)] << 8))
#define SEXT8(x)    ((uint16_t)(((x) ^ 0x80u) - 0x80u))

/* Little-endian words at any address; the high byte of 0xFFFF is at 0x0000. */
#define RD16(a)     ((uint16_t)(m[(uint16_t)(a)] | m[(uint16_t)((a) + 1)] << 8))
#define WR16(a, v)  (m[(uint16_t)(a)] = (uint8_t)(v), m[(uint16_t)((a) + 1)] = (uint8_t)((v) >> 8))

#define TRAP(code)  do { trap = (code); goto stop; } while (0)
#define CHK(a, n, code) \
    do { if (check && !in_region(vm, (a), (n))) TRAP(code); } while (0)

#define DECODE() \
    do { \
        start = pc; \
        op = m[pc++]; \
        steps++; \
        if (check && (trap = precheck(vm, start, op)) != 0) \
            goto stop; \
    } while (0)

#if USE_GOTO
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Winitializer-overrides"
#elif defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Woverride-init"
#pragma GCC diagnostic ignored "-Wpedantic"
#endif
    static void *const jump[256] = {
        [0 ... 255] = &&illegal,
        [HALT] = &&L_HALT, [NOP] = &&L_NOP, [LI] = &&L_LI, [MOV] = &&L_MOV,
        [LW] = &&L_LW, [SW] = &&L_SW, [LB] = &&L_LB, [SB] = &&L_SB,
        [LWA] = &&L_LWA, [SWA] = &&L_SWA,
        [ADD] = &&L_ADD, [SUB] = &&L_SUB, [AND] = &&L_AND, [OR] = &&L_OR,
        [XOR] = &&L_XOR, [MUL] = &&L_MUL, [DIVU] = &&L_DIVU,
        [NOT] = &&L_NOT, [NEG] = &&L_NEG, [SHL] = &&L_SHL, [SHR] = &&L_SHR,
        [SAR] = &&L_SAR, [ADDI] = &&L_ADDI,
        [BEQ] = &&L_BEQ, [BNE] = &&L_BNE, [BLT] = &&L_BLT, [BGE] = &&L_BGE,
        [BLTU] = &&L_BLTU, [BGEU] = &&L_BGEU, [BZ] = &&L_BZ, [BNZ] = &&L_BNZ,
        [JMP] = &&L_JMP, [JR] = &&L_JR,
        [PUSH] = &&L_PUSH, [POP] = &&L_POP, [GETDSP] = &&L_GETDSP,
        [SETDSP] = &&L_SETDSP, [GETRSP] = &&L_GETRSP, [SETRSP] = &&L_SETRSP,
        [CALL] = &&L_CALL, [CALLR] = &&L_CALLR, [RET] = &&L_RET, [SYS] = &&L_SYS,
    };
#if defined(__clang__)
#pragma clang diagnostic pop
#elif defined(__GNUC__)
#pragma GCC diagnostic pop
#endif
#define TARGET(x)   L_##x:
#define NEXT        do { DECODE(); goto *jump[op]; } while (0)
    NEXT;
#else
#define TARGET(x)   case x:
#define NEXT        break
    for (;;) {
        DECODE();
        switch (op) {
#endif

    TARGET(HALT)    goto stop;
    TARGET(NOP)     NEXT;
    TARGET(LI)      { uint16_t *a = &REG(); *a = IMM16(); } NEXT;
    TARGET(MOV)     { uint16_t *a = &REG(); *a = REG(); } NEXT;

    /* Memory */
    TARGET(LW)      { uint16_t *a = &REG(); uint16_t ea = REG(); ea += B();
                      CHK(ea, 2, T_MEM); *a = RD16(ea); } NEXT;
    TARGET(SW)      { uint16_t v = REG(); uint16_t ea = REG(); ea += B();
                      CHK(ea, 2, T_MEM); WR16(ea, v); } NEXT;
    TARGET(LB)      { uint16_t *a = &REG(); uint16_t ea = REG(); ea += B();
                      CHK(ea, 1, T_MEM); *a = m[ea]; } NEXT;
    TARGET(SB)      { uint16_t v = REG(); uint16_t ea = REG(); ea += B();
                      CHK(ea, 1, T_MEM); m[ea] = (uint8_t)v; } NEXT;
    TARGET(LWA)     { uint16_t *a = &REG(); uint16_t ea = IMM16();
                      CHK(ea, 2, T_MEM); *a = RD16(ea); } NEXT;
    TARGET(SWA)     { uint16_t v = REG(); uint16_t ea = IMM16();
                      CHK(ea, 2, T_MEM); WR16(ea, v); } NEXT;

    /* Arithmetic and logic. Results are stored into uint16_t, which
       reduces them modulo 2^16. */
    TARGET(ADD)     { uint16_t *a = &REG(); uint16_t b = REG(); *a += b; } NEXT;
    TARGET(SUB)     { uint16_t *a = &REG(); uint16_t b = REG(); *a -= b; } NEXT;
    TARGET(AND)     { uint16_t *a = &REG(); uint16_t b = REG(); *a &= b; } NEXT;
    TARGET(OR)      { uint16_t *a = &REG(); uint16_t b = REG(); *a |= b; } NEXT;
    TARGET(XOR)     { uint16_t *a = &REG(); uint16_t b = REG(); *a ^= b; } NEXT;
    TARGET(MUL)     { uint16_t *a = &REG(); uint16_t b = REG();
                      *a = (uint16_t)((uint32_t)*a * b); } NEXT;
    TARGET(DIVU)    { uint16_t *a = &REG(); uint16_t d = REG(); uint16_t n = *a;
                      r[15] = d ? n % d : n;            /* remainder first ... */
                      *a = d ? n / d : 0xFFFF; } NEXT;  /* ... the quotient wins */
    TARGET(NOT)     { uint16_t *a = &REG(); *a ^= 0xFFFF; } NEXT;
    TARGET(NEG)     { uint16_t *a = &REG(); *a = (uint16_t)(0u - *a); } NEXT;
    TARGET(SHL)     { uint16_t *a = &REG(); *a = (uint16_t)(*a << 1); } NEXT;
    TARGET(SHR)     { uint16_t *a = &REG(); *a >>= 1; } NEXT;
    TARGET(SAR)     { uint16_t *a = &REG(); *a = (uint16_t)((*a >> 1) | (*a & 0x8000)); } NEXT;
    TARGET(ADDI)    { uint16_t *a = &REG(); *a += SEXT8(B()); } NEXT;

    /* Branches. The offset is read last, so pc is already 'next'.
       Signed comparison flips both sign bits and compares unsigned. */
#define BRANCH(cond) do { uint16_t off = SEXT8(B()); if (cond) pc += off; } while (0)
    TARGET(BEQ)     { uint16_t a = REG(), b = REG(); BRANCH(a == b); } NEXT;
    TARGET(BNE)     { uint16_t a = REG(), b = REG(); BRANCH(a != b); } NEXT;
    TARGET(BLT)     { uint16_t a = REG(), b = REG(); BRANCH((a ^ 0x8000) < (b ^ 0x8000)); } NEXT;
    TARGET(BGE)     { uint16_t a = REG(), b = REG(); BRANCH((a ^ 0x8000) >= (b ^ 0x8000)); } NEXT;
    TARGET(BLTU)    { uint16_t a = REG(), b = REG(); BRANCH(a < b); } NEXT;
    TARGET(BGEU)    { uint16_t a = REG(), b = REG(); BRANCH(a >= b); } NEXT;
    TARGET(BZ)      { uint16_t a = REG(); BRANCH(a == 0); } NEXT;
    TARGET(BNZ)     { uint16_t a = REG(); BRANCH(a != 0); } NEXT;
    TARGET(JMP)     { uint16_t t = IMM16(); pc = t; } NEXT;
    TARGET(JR)      { uint16_t t = REG(); pc = t; } NEXT;

    /* Stacks: full descending, one word per item */
    TARGET(PUSH)    { uint16_t v = REG(); dsp -= 2; CHK(dsp, 2, T_DSTACK); WR16(dsp, v); } NEXT;
    TARGET(POP)     { uint16_t *a = &REG(); CHK(dsp, 2, T_DSTACK); *a = RD16(dsp); dsp += 2; } NEXT;
    TARGET(GETDSP)  { uint16_t *a = &REG(); *a = dsp; } NEXT;
    TARGET(SETDSP)  { dsp = REG(); } NEXT;
    TARGET(GETRSP)  { uint16_t *a = &REG(); *a = rsp; } NEXT;
    TARGET(SETRSP)  { rsp = REG(); } NEXT;
    TARGET(CALL)    { uint16_t t = IMM16(); rsp -= 2; CHK(rsp, 2, T_RSTACK);
                      WR16(rsp, pc); pc = t; } NEXT;
    TARGET(CALLR)   { uint16_t t = REG(); rsp -= 2; CHK(rsp, 2, T_RSTACK);
                      WR16(rsp, pc); pc = t; } NEXT;
    TARGET(RET)     { CHK(rsp, 2, T_RSTACK); pc = RD16(rsp); rsp += 2; } NEXT;

    TARGET(SYS)     {
                        unsigned n = B();
                        if (n == 0) {
                            fputc(r[0] & 0xFF, vm->out);
                        } else if (n == 1) {
                            fflush(vm->out);
                            int c = fgetc(vm->in);
                            r[0] = c == EOF ? 0xFFFF : (uint16_t)c;
                        } else if (n == 2) {
                            r[0] = vm->lo;
                            r[1] = vm->hi;
                        } else if (n == 3) {
                            debug_dump(vm, start, dsp, rsp);
                        } else {
                            TRAP(T_SYS);
                        }
                    } NEXT;

#if !USE_GOTO
        default:
            goto illegal;
        }
    }
#endif

illegal:
    trap = T_OPCODE;
stop:
    vm->pc = start;
    vm->dsp = dsp;
    vm->rsp = rsp;
    vm->steps = steps;
    return trap;
}

/* Load an image (spec section 7). Returns 0, or -1 with a message. */
static int load_image(VM *vm, const uint8_t *img, size_t size, const char **why)
{
    if (size < 14 || memcmp(img, "V16\0", 4) != 0) {
        *why = "not a VM16 image (bad header)";
        return -1;
    }
    unsigned w[5];
    for (int i = 0; i < 5; i++)
        w[i] = img[4 + 2 * i] | img[5 + 2 * i] << 8;
    unsigned load = w[0], length = w[1];
    if (size - 14 < length) {
        *why = "image body is shorter than its header says";
        return -1;
    }
    if (load < vm->lo || load + length > (unsigned)vm->hi + 1) {
        *why = "image body does not fit in the usable region";
        return -1;
    }
    memcpy(vm->mem + load, img + 14, length);
    memset(vm->r, 0, sizeof vm->r);
    vm->pc = (uint16_t)w[2];
    vm->dsp = (uint16_t)w[3];
    vm->rsp = (uint16_t)w[4];
    return 0;
}

/* Final state for the test harness: kind (0 halt, 1 trap, 2 rejected),
   trap code, r0 or trap PC, r0..r15, DSP, RSP, steps, then all of memory.
   Multi-byte values are little-endian. */
static void write_dump(const char *path, const VM *vm, int kind, int code, unsigned value)
{
    FILE *f = fopen(path, "wb");
    if (!f) {
        perror(path);
        exit(2);
    }
    uint8_t h[48] = { (uint8_t)kind, (uint8_t)code, (uint8_t)value, (uint8_t)(value >> 8) };
    for (int i = 0; i < 16; i++) {
        h[4 + 2 * i] = (uint8_t)vm->r[i];
        h[5 + 2 * i] = (uint8_t)(vm->r[i] >> 8);
    }
    h[36] = (uint8_t)vm->dsp; h[37] = (uint8_t)(vm->dsp >> 8);
    h[38] = (uint8_t)vm->rsp; h[39] = (uint8_t)(vm->rsp >> 8);
    for (int i = 0; i < 8; i++)
        h[40 + i] = (uint8_t)(vm->steps >> (8 * i));
    fwrite(h, 1, sizeof h, f);
    fwrite(vm->mem, 1, sizeof vm->mem, f);
    fclose(f);
}

static void usage(void)
{
    fprintf(stderr, "usage: vm16 [-c] [-s] [-r LO-HI] [-d DUMPFILE] IMAGE\n");
    exit(2);
}

int main(int argc, char **argv)
{
    static VM vm;                       /* 64 KB: keep it off the stack */
    const char *dump = NULL, *path = NULL;
    int stats = 0;
    vm.lo = 0x0000;
    vm.hi = 0xFFFF;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-c")) {
            vm.check = 1;
        } else if (!strcmp(argv[i], "-s")) {
            stats = 1;
        } else if (!strcmp(argv[i], "-d") && i + 1 < argc) {
            dump = argv[++i];
        } else if (!strcmp(argv[i], "-r") && i + 1 < argc) {
            unsigned lo, hi;
            if (sscanf(argv[++i], "%x-%x", &lo, &hi) != 2 || lo > hi || hi > 0xFFFF)
                usage();
            vm.lo = (uint16_t)lo;
            vm.hi = (uint16_t)hi;
        } else if (argv[i][0] == '-' || path) {
            usage();
        } else {
            path = argv[i];
        }
    }
    if (!path)
        usage();

    static uint8_t img[14 + 65536 + 1];
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        return 2;
    }
    size_t size = fread(img, 1, sizeof img, f);
    fclose(f);

    const char *why;
    if (load_image(&vm, img, size, &why) != 0) {
        fprintf(stderr, "vm16: %s: %s\n", path, why);
        if (dump)
            write_dump(dump, &vm, 2, 0, 0);
        return 125;
    }

    vm.in = stdin;
    vm.out = stdout;
    clock_t t0 = clock();
    int trap = vm_run(&vm);
    double secs = (double)(clock() - t0) / CLOCKS_PER_SEC;
    fflush(stdout);

    if (stats)
        fprintf(stderr, "vm16: %" PRIu64 " instructions in %.3f s (%.1f million/s)\n",
                vm.steps, secs, secs > 0 ? vm.steps / secs / 1e6 : 0.0);
    if (dump)
        write_dump(dump, &vm, trap ? 1 : 0, trap, trap ? vm.pc : vm.r[0]);
    if (trap) {
        fprintf(stderr, "vm16: trap %d (%s) at %04X, opcode %02X\n",
                trap, trap_name[trap], vm.pc, vm.mem[vm.pc]);
        return 128 + trap;
    }
    return vm.r[0] & 0xFF;
}
