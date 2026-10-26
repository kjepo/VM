; graph.asm - combinator graph reduction in VM16 assembly.
;
; Reads a lambda term from standard input, compiles it to combinators with
; Turner's bracket abstraction, and reduces the resulting graph lazily. Prints
; the result, followed by the number of reductions and garbage collections.
;
;   python3 ../vm16asm.py graph.asm
;   ../vm16 graph.v16 < fac.lam                    ->  5040
;   echo '(\a b.a) 4 3' | ../vm16 graph.v16        ->  4
;   echo '? \x y.y x' | ../vm16 graph.v16          ->  C I   (the compiled term)
;
; Input syntax (as in ../CAM/cam.asm):
;   term   = atom atom ...               application, left-associative
;   atom   = x | 42 | -42 | op | (term) | \x y ... . term
;          | if atom atom atom | rec f . term
;   x      single letter, a-z or A-Z;  \x y.M means \x.\y.M
;   42     a 15-bit signed number, -16384..16383
;   op     + - * / % = <  curried two-argument primitives: - 7 2 = 5.
;          / and % truncate towards zero. = and < return 1 or 0.
;   if c t e   0 is false
;   rec f.M    M, where f refers to M itself (M need not be a function)
;          "if" and "rec" are keywords: write "i f" and "r e" for applications.
;   #      comment to the end of the line
;   ?      as the first character: print the compiled term instead of running it
;
; The graph. Every heap cell is an application node of two words, (fun, arg).
; Everything else is a word that is not a heap address:
;     numbers       odd words n*2+1
;     combinators   small even codes C_I .. C_LT
;     variables     VAR_x, and LAM_x in a cell (LAM_x, body) for \x.body; both
;                   exist only between the reader and the compiler
; so a word is a cell exactly when it is even and at least HEAP_LO.
;
; Compilation: [x] is bracket abstraction, applied to the compiled body of each
; lambda, innermost first:
;     [x] x = I        [x] e = K e  for any other leaf    [x] (e f) = S [x]e [x]f
; and S a b is simplified as it is built (Turner 1979):
;     S (K p) (K q)     = K (p q)          S (B p q) (K r) = C' p q r
;     S (K p) I         = p                S p (K q)       = C p q
;     S (K p) (B q r)   = B* p q r         S (B p q) r     = S' p q r
;     S (K p) q         = B p q
; if c t e is IF c t e, and rec f.M is Y (\f.M).
;
; Reduction. whnf follows the function parts from the root down to the head,
; pushing each cell it passes on the data stack (the spine). If the head is a
; combinator with all its arguments, the redex is rewritten in place: its root
; cell is overwritten with the result, so every other reference to it sees the
; result too, and nothing is evaluated twice. A result that is not an
; application, such as the x of K x y, is stored as the indirection I x.
;     I x          = x               Y f          = f (Y f)    (a cycle)
;     K x y        = x               S' k f g x   = k (f x) (g x)
;     S f g x      = f x (g x)       B* k f g x   = k (f (g x))
;     B f g x      = f (g x)         C' k f g x   = k (f x) g
;     C f g x      = f x g           IF c t e     = t or e, by the value of c
;     + a b ...    = the number, after reducing a and b
; IF and the operators reduce their arguments with a nested call of whnf.
;
; Garbage collection: Cheney's copying collector over two semispaces. Its roots
; are the words on the data stack, which hold every live pointer: an
; allocating rule makes sure there is room for three cells before it reads its
; arguments. Saved spine bases and handler addresses on the stack are outside
; the heap, and the collector leaves them alone, as it does numbers.

        .equ    C_I, 2                  ; combinators (even, used as table offsets)
        .equ    C_K, 4
        .equ    C_S, 6
        .equ    C_B, 8
        .equ    C_C, 10
        .equ    C_SP, 12                ; S'
        .equ    C_BS, 14                ; B*
        .equ    C_CP, 16                ; C'
        .equ    C_Y, 18
        .equ    C_IF, 20
        .equ    C_ADD, 22               ; then SUB MUL DIV MOD EQ LT, as in op_chars
        .equ    C_LT, 34
        .equ    FWD, 0                  ; fun field of a cell copied by the collector
        .equ    VAR_BASE, 0x100         ; VAR_x = VAR_BASE + 2x
        .equ    LAM_BASE, 0x200         ; LAM_x = LAM_BASE + 2x
        .equ    LAM_END, 0x300

        .equ    CELL, 4                 ; bytes per cell
        .equ    HEAP_LO, 0x3000
        .equ    SEMI, 0x4800            ; bytes per semispace
        .equ    HEAP1, 0x3000
        .equ    HEAP2, 0x7800           ; ends at 0xC000
        .equ    STACK_LIMIT, 0xC040     ; the data stack grows down from 0xE000
        .equ    STACK_TOP, 0xE000
        .equ    RSTACK_LIMIT, 0xE040    ; the return stack grows down from 0xF000
        .equ    EOF, 0xFFFF

        .org    0x2000
        .entry  start
        .stacks STACK_TOP, 0xF000

; Registers kept throughout:
;   r9   the spine base: the data stack pointer when the current whnf began
;   r10  heap pointer, r11 = end of the semispace - 3 cells
;   r12  reductions, low word (the high word is STEPS_HI)
;   r13  STACK_LIMIT, r14 HEAP_LO

start:  LI      r10, HEAP1
        LI      r11, HEAP1+SEMI-3*CELL
        SWA     r10, FROM
        LI      r0, HEAP2
        SWA     r0, TO
        LI      r13, STACK_LIMIT
        LI      r14, HEAP_LO
        CALL    nextc                   ; LOOK = first input character
        CALL    skipws
        LI      r1, '?'
        BNE     r0, r1, st_parse
        SWA     r0, SHOW
        CALL    nextc
st_parse:
        CALL    parse_term              ; r0 = the syntax tree
        PUSH    r0
        CALL    skipws
        LI      r1, EOF
        BEQ     r0, r1, st_ok
        JMP     syntax_error            ; something left over, such as ')'
st_ok:  POP     r0
        CALL    compile
        PUSH    r0
        CALL    check_free
        POP     r0
        LWA     r1, SHOW
        BZ      r1, st_run
        CALL    print_term
        LI      r0, '\n'
        SYS     0
        LI      r0, 0
        HALT
st_run: LI      r12, 0
        CALL    whnf
        LI      r1, 1                   ; print the result
        AND     r1, r0
        BZ      r1, st_fun
        SAR     r0
        CALL    print_s16
        JMP     st_stats
st_fun: LI      r0, msg_function
        CALL    print_str
st_stats:
        LI      r0, msg_stats1          ; "\n["
        CALL    print_str
        SWA     r12, NUM
        LWA     r0, STEPS_HI
        SWA     r0, NUM+2
        CALL    print_u32
        LI      r0, msg_stats2          ; " reductions, "
        CALL    print_str
        LWA     r0, GCS
        CALL    print_u16
        LI      r0, msg_stats3          ; " collections]\n"
        CALL    print_str
        LI      r0, 0
        HALT

; ---------------------------------------------------------------------------
; The reducer
; ---------------------------------------------------------------------------
; whnf: reduce the graph r0 to weak head normal form and return it in r0: a
; number, a combinator, or the root of a partial application. On entry to a
; rule, [dsp] is the innermost cell of the spine, the one holding the first
; argument, and [dsp+2] holds the second. Changes r0-r8.
whnf:   PUSH    r9
        GETDSP  r9
        GETRSP  r1
        LI      r2, RSTACK_LIMIT
        BGEU    r1, r2, unwind
        JMP     stack_full
unwind: LI      r1, 1
        AND     r1, r0
        BNZ     r1, wh_number
        BLTU    r0, r14, wh_comb
        PUSH    r0                      ; a cell: go down its function part
        GETDSP  r1
        BLTU    r1, r13, wh_full
        LW      r0, [r0]
        JMP     unwind
wh_full:
        JMP     stack_full

; set_parent: the spine entries of a redex have been popped and r0 is its
; result. Store r0 as the function part of the parent, skipping the
; indirection, and go on with r0.
set_parent:
        GETDSP  r1
        BEQ     r1, r9, unwind
        LW      r1, [r1]
        SW      r0, [r1]
        JMP     unwind

wh_number:
        GETDSP  r1
        BEQ     r1, r9, wh_ret
        LI      r0, msg_apply           ; a number with arguments
        JMP     fail
wh_comb:
        GETDSP  r1
        MOV     r2, r9
        SUB     r2, r1                  ; r2 = 2 * the number of arguments
        LI      r3, arity2
        ADD     r3, r0
        LW      r3, [r3]
        BLTU    r2, r3, wh_partial
        ADDI    r12, 1                  ; count the reduction
        BNZ     r12, wh_go
        LWA     r1, STEPS_HI
        ADDI    r1, 1
        SWA     r1, STEPS_HI
wh_go:  LI      r3, rules
        ADD     r3, r0
        LW      r3, [r3]
        JR      r3
wh_partial:                             ; the result is the outermost cell
        BZ      r2, wh_ret
        MOV     r1, r9
        ADDI    r1, -2
        LW      r0, [r1]
wh_ret: SETDSP  r9
        POP     r9
        RET

; The rules. Each finds its arguments in the arg fields of the spine cells,
; overwrites the root of the redex, pops the redex off the spine and continues
; unwinding from the root.
r_i:    POP     r1                      ; I x = x
        LW      r0, [r1+2]
        BEQ     r0, r1, r_i_loop
        JMP     set_parent
r_i_loop:                               ; x = I x, as in rec x.x
        LI      r0, msg_loop
        JMP     fail

r_k:    GETDSP  r7                      ; K x y = x
        LW      r1, [r7]
        LW      r0, [r1+2]
        LW      r3, [r7+2]
        ADDI    r7, 4
        JMP     indirect

r_y:    POP     r0                      ; Y f = f (Y f): the root points to itself
        LW      r1, [r0+2]
        SW      r1, [r0]
        SW      r0, [r0+2]
        JMP     unwind

r_s:    BGEU    r11, r10, rs_go         ; S f g x = f x (g x)
        CALL    collect
rs_go:  GETDSP  r7
        LW      r1, [r7]
        LW      r1, [r1+2]              ; f
        LW      r2, [r7+2]
        LW      r2, [r2+2]              ; g
        LW      r0, [r7+4]              ; the root
        LW      r3, [r0+2]              ; x
        SW      r1, [r10]               ; (f x)
        SW      r3, [r10+2]
        SW      r10, [r0]
        ADDI    r10, CELL
        SW      r2, [r10]               ; (g x)
        SW      r3, [r10+2]
        SW      r10, [r0+2]
        ADDI    r10, CELL
        ADDI    r7, 6
        SETDSP  r7
        JMP     unwind

r_b:    BGEU    r11, r10, rb_go         ; B f g x = f (g x)
        CALL    collect
rb_go:  GETDSP  r7
        LW      r1, [r7]
        LW      r1, [r1+2]              ; f
        LW      r2, [r7+2]
        LW      r2, [r2+2]              ; g
        LW      r0, [r7+4]              ; the root
        LW      r3, [r0+2]              ; x
        SW      r2, [r10]               ; (g x)
        SW      r3, [r10+2]
        SW      r1, [r0]
        SW      r10, [r0+2]
        ADDI    r10, CELL
        ADDI    r7, 6
        SETDSP  r7
        JMP     unwind

r_c:    BGEU    r11, r10, rc_go         ; C f g x = f x g
        CALL    collect
rc_go:  GETDSP  r7
        LW      r1, [r7]
        LW      r1, [r1+2]              ; f
        LW      r2, [r7+2]
        LW      r2, [r2+2]              ; g
        LW      r0, [r7+4]              ; the root
        LW      r3, [r0+2]              ; x
        SW      r1, [r10]               ; (f x)
        SW      r3, [r10+2]
        SW      r10, [r0]
        SW      r2, [r0+2]
        ADDI    r10, CELL
        ADDI    r7, 6
        SETDSP  r7
        JMP     unwind

; S', B* and C': r1 = k, r2 = f, r3 = g, r4 = x, r0 = the root
args4:  BGEU    r11, r10, a4_go
        CALL    collect
a4_go:  GETDSP  r7
        LW      r1, [r7]
        LW      r1, [r1+2]
        LW      r2, [r7+2]
        LW      r2, [r2+2]
        LW      r3, [r7+4]
        LW      r3, [r3+2]
        LW      r0, [r7+6]
        LW      r4, [r0+2]
        RET

r_sp:   CALL    args4                   ; S' k f g x = k (f x) (g x)
        SW      r2, [r10]               ; (f x)
        SW      r4, [r10+2]
        SW      r1, [r10+4]             ; (k (f x))
        SW      r10, [r10+6]
        SW      r3, [r10+8]             ; (g x)
        SW      r4, [r10+10]
        MOV     r1, r10
        ADDI    r1, 4
        SW      r1, [r0]
        ADDI    r1, 4
        SW      r1, [r0+2]
        ADDI    r10, 3*CELL
        JMP     pop4

r_bs:   CALL    args4                   ; B* k f g x = k (f (g x))
        SW      r3, [r10]               ; (g x)
        SW      r4, [r10+2]
        SW      r2, [r10+4]             ; (f (g x))
        SW      r10, [r10+6]
        SW      r1, [r0]
        MOV     r1, r10
        ADDI    r1, 4
        SW      r1, [r0+2]
        ADDI    r10, 2*CELL
        JMP     pop4

r_cp:   CALL    args4                   ; C' k f g x = k (f x) g
        SW      r2, [r10]               ; (f x)
        SW      r4, [r10+2]
        SW      r1, [r10+4]             ; (k (f x))
        SW      r10, [r10+6]
        MOV     r1, r10
        ADDI    r1, 4
        SW      r1, [r0]
        SW      r3, [r0+2]
        ADDI    r10, 2*CELL
pop4:   GETDSP  r7                      ; pop the 4 spine cells
        ADDI    r7, 8
        SETDSP  r7
        JMP     unwind

r_if:   GETDSP  r7                      ; IF c t e = t, or e if c is 0
        LW      r0, [r7]
        LW      r0, [r0+2]
        CALL    whnf
        LI      r1, 1
        AND     r1, r0
        BNZ     r1, if_num
        LI      r0, msg_if
        JMP     fail
if_num: GETDSP  r7
        LW      r3, [r7+4]              ; the root
        LI      r1, 1
        BEQ     r0, r1, if_else         ; the number 0
        LW      r0, [r7+2]
        LW      r0, [r0+2]              ; t
        JMP     if_set
if_else:
        LW      r0, [r3+2]              ; e
if_set: ADDI    r7, 6
        JMP     indirect

; The operators: reduce both arguments to numbers, then jump to the handler
; with r1 = a and r2 = b, tagged. The handler leaves the tagged result in r0.
r_add:  LI      r0, op_add
        JMP     prim
r_sub:  LI      r0, op_sub
        JMP     prim
r_mul:  LI      r0, op_mul
        JMP     prim
r_div:  LI      r0, op_div
        JMP     prim
r_mod:  LI      r0, op_mod
        JMP     prim
r_eq:   LI      r0, op_eq
        JMP     prim
r_lt:   LI      r0, op_lt
prim:   PUSH    r0                      ; [dsp] = the handler
        GETDSP  r7
        LW      r0, [r7+2]
        LW      r0, [r0+2]              ; a
        CALL    whnf
        CALL    need_number
        PUSH    r0                      ; [dsp] = a, [dsp+2] = the handler
        GETDSP  r7
        LW      r0, [r7+6]
        LW      r0, [r0+2]              ; b
        CALL    whnf
        CALL    need_number
        MOV     r2, r0
        POP     r1
        POP     r0
        JR      r0

op_add: ADD     r1, r2                  ; (2a+1) + (2b+1) - 1
        ADDI    r1, -1
        MOV     r0, r1
        JMP     prim_set
op_sub: SUB     r1, r2                  ; (2a+1) - (2b+1) + 1
        ADDI    r1, 1
        MOV     r0, r1
        JMP     prim_set
op_mul: SAR     r1                      ; a * 2b + 1
        ADDI    r2, -1
        MUL     r1, r2
        ADDI    r1, 1
        MOV     r0, r1
        JMP     prim_set
op_div: SAR     r1
        SAR     r2
        CALL    sdiv
        MOV     r0, r1
        JMP     tag_r0
op_mod: SAR     r1
        SAR     r2
        CALL    sdiv
        MOV     r0, r15
tag_r0: SHL     r0
        ADDI    r0, 1
        JMP     prim_set
op_eq:  LI      r0, 3                   ; 1
        BEQ     r1, r2, prim_set
        LI      r0, 1                   ; 0
        JMP     prim_set
op_lt:  LI      r0, 3                   ; tagging keeps the order
        BLT     r1, r2, prim_set
        LI      r0, 1
prim_set:
        GETDSP  r7
        LW      r3, [r7+2]              ; the root
        ADDI    r7, 4
; indirect: overwrite the root r3 with I r0, pop the spine to r7, and go on
; with r0 (the indirection is skipped at once).
indirect:
        LI      r1, C_I
        SW      r1, [r3]
        SW      r0, [r3+2]
        SETDSP  r7
        JMP     set_parent

need_number:                            ; fail unless r0 is a number
        LI      r1, 1
        AND     r1, r0
        BZ      r1, nn_err
        RET
nn_err: LI      r0, msg_operand
        JMP     fail

; sdiv: r1 = r1 / r2, r15 = r1 % r2, signed, truncating towards zero.
; Changes r3-r5.
sdiv:   BNZ     r2, sd_ok
        LI      r0, msg_divzero
        JMP     fail
sd_ok:  LI      r3, 0                   ; r3 = negate the quotient
        LI      r4, 0                   ; r4 = negate the remainder
        LI      r5, 0
        BGE     r1, r5, sd_1
        NEG     r1
        LI      r3, 1
        LI      r4, 1
sd_1:   BGE     r2, r5, sd_2
        NEG     r2
        LI      r5, 1
        XOR     r3, r5
sd_2:   DIVU    r1, r2
        BZ      r3, sd_3
        NEG     r1
sd_3:   BZ      r4, sd_4
        NEG     r15
sd_4:   RET

; ---------------------------------------------------------------------------
; Errors
; ---------------------------------------------------------------------------
fail:   PUSH    r0                      ; print "error: <message>" and stop
        LI      r0, msg_error
        CALL    print_str
        POP     r0
        CALL    print_str
        LI      r0, '\n'
        SYS     0
        LI      r0, 1
        HALT

stack_full:
        LI      r0, msg_stack
        JMP     fail

unbound:                                ; r0 = the variable
        PUSH    r0
        LI      r0, msg_error
        CALL    print_str
        LI      r0, msg_unbound
        CALL    print_str
        POP     r0
        LI      r1, VAR_BASE
        SUB     r0, r1
        SHR     r0
        SYS     0
        LI      r0, '\n'
        SYS     0
        LI      r0, 1
        HALT

syntax_error:
        LI      r0, msg_error
        CALL    print_str
        LI      r0, msg_syntax
        CALL    print_str
        LWA     r0, LOOK
        LI      r1, EOF
        BEQ     r0, r1, se_eof
        PUSH    r0
        LI      r0, 39                  ; quote the offending character
        SYS     0
        POP     r0
        SYS     0
        LI      r0, 39
        SYS     0
        JMP     se_end
se_eof: LI      r0, msg_eof
        CALL    print_str
se_end: LI      r0, '\n'
        SYS     0
        LI      r0, 2
        HALT

; ---------------------------------------------------------------------------
; Heap
; ---------------------------------------------------------------------------
; collect: make room for three cells. Changes r0-r7.
collect:
        CALL    gc
        BGEU    r11, r10, cl_ok
oom:    LI      r0, msg_oom
        JMP     fail
cl_ok:  RET

; mkapp: r0 = a new cell (r1, r2), for the reader and the compiler, which
; never collect. Changes nothing else.
mkapp:  BLTU    r11, r10, oom
        SW      r1, [r10]
        SW      r2, [r10+2]
        MOV     r0, r10
        ADDI    r10, CELL
        RET

; gc: copy everything reachable from the data stack into the other semispace.
; Changes r0-r7.
gc:     LWA     r0, GCS
        ADDI    r0, 1
        SWA     r0, GCS
        LWA     r10, TO
        MOV     r6, r10                 ; r6 = scan pointer
        GETDSP  r7
gc_stack:
        LI      r1, STACK_TOP
        BEQ     r7, r1, gc_scan
        LW      r0, [r7]
        CALL    forward
        SW      r0, [r7]
        ADDI    r7, 2
        JMP     gc_stack
gc_scan:                                ; forward both fields of each copied cell
        BEQ     r6, r10, gc_flip
        LW      r0, [r6]
        CALL    forward
        SW      r0, [r6]
        LW      r0, [r6+2]
        CALL    forward
        SW      r0, [r6+2]
        ADDI    r6, CELL
        JMP     gc_scan
gc_flip:                                ; the copy becomes the current space
        LWA     r0, FROM
        LWA     r1, TO
        SWA     r1, FROM
        SWA     r0, TO
        MOV     r11, r1
        LI      r2, SEMI-3*CELL
        ADD     r11, r2
        RET

; forward: r0 = the new address of the cell r0, copying it if needed.
; Numbers and words outside from-space are returned unchanged. Changes r1-r3.
forward:
        LI      r1, 1
        AND     r1, r0
        BNZ     r1, fw_ret
        LWA     r1, FROM
        BLTU    r0, r1, fw_ret
        LI      r2, SEMI
        ADD     r2, r1
        BGEU    r0, r2, fw_ret
        LW      r3, [r0]
        BNZ     r3, fw_copy
        LW      r0, [r0+2]              ; copied before: follow the forwarding address
fw_ret: RET
fw_copy:
        SW      r3, [r10]
        LW      r1, [r0+2]
        SW      r1, [r10+2]
        LI      r3, FWD                 ; leave a forwarding address behind
        SW      r3, [r0]
        SW      r10, [r0+2]
        MOV     r0, r10
        ADDI    r10, CELL
        RET

; ---------------------------------------------------------------------------
; Compiler: bracket abstraction
; ---------------------------------------------------------------------------
; compile: r0 = the syntax tree r0 without lambdas. Application cells are
; reused; each lambda cell is replaced by the abstraction of its compiled body.
compile:
        LI      r1, 1
        AND     r1, r0
        BNZ     r1, c_ret               ; a number
        BLTU    r0, r14, c_ret          ; a variable or a combinator
        LW      r1, [r0]
        LI      r2, LAM_BASE
        BLTU    r1, r2, c_app
        LI      r2, LAM_END
        BGEU    r1, r2, c_app
        PUSH    r1                      ; \x.M: [x] (compile M)
        LW      r0, [r0+2]
        CALL    compile
        POP     r1
        LI      r2, LAM_BASE-VAR_BASE   ; LAM_x -> VAR_x
        SUB     r1, r2
        JMP     abstract
c_app:  PUSH    r0                      ; (M N): compile both in place
        MOV     r0, r1
        CALL    compile
        POP     r1
        SW      r0, [r1]
        PUSH    r1
        LW      r0, [r1+2]
        CALL    compile
        POP     r1
        SW      r0, [r1+2]
        MOV     r0, r1
c_ret:  RET

; abstract: r0 = [r1] r0, where r1 is a variable and r0 has no lambdas.
abstract:
        LI      r2, 1
        AND     r2, r0
        BNZ     r2, ab_k                ; a number
        BLTU    r0, r14, ab_leaf
        PUSH    r1                      ; (e f): opt_s [x]e [x]f
        PUSH    r0
        LW      r0, [r0]
        CALL    abstract
        GETDSP  r2
        LW      r1, [r2+2]
        LW      r3, [r2]
        SW      r0, [r2]                ; [dsp] = [x]e
        LW      r0, [r3+2]
        CALL    abstract
        MOV     r2, r0
        POP     r1
        POP     r3
        JMP     opt_s
ab_leaf:
        BNE     r0, r1, ab_k
        LI      r0, C_I                 ; [x] x = I
        RET
ab_k:   MOV     r2, r0                  ; [x] e = K e
        LI      r1, C_K
        JMP     mkapp

; opt_s: r0 = S r1 r2, simplified by Turner's rules.
opt_s:  MOV     r0, r2
        CALL    head
        MOV     r6, r3                  ; r6 = the function part of b
        MOV     r0, r1
        CALL    head
        MOV     r5, r3                  ; r5 = the function part of a
        LI      r7, C_K
        BNE     r5, r7, os_nk
        LW      r5, [r1+2]              ; a = K p, r5 = p
        BNE     r6, r7, os_k2
        MOV     r1, r5                  ; S (K p) (K q) = K (p q)
        LW      r2, [r2+2]
        CALL    mkapp
        MOV     r2, r0
        LI      r1, C_K
        JMP     mkapp
os_k2:  LI      r7, C_I
        BNE     r2, r7, os_k3
        MOV     r0, r5                  ; S (K p) I = p
        RET
os_k3:  MOV     r0, r6
        CALL    head
        LI      r7, C_B
        BNE     r3, r7, os_k4
        LW      r3, [r6+2]              ; S (K p) (B q r) = B* p q r
        LW      r4, [r2+2]
        MOV     r2, r5
        LI      r1, C_BS
        JMP     mk3
os_k4:  MOV     r3, r2                  ; S (K p) q = B p q
        MOV     r2, r5
        LI      r1, C_B
        JMP     mk2
os_nk:  MOV     r0, r5
        CALL    head
        LI      r7, C_B
        BNE     r3, r7, os_c
        LW      r3, [r5+2]              ; a = B p q, r3 = p
        LI      r7, C_K
        BNE     r6, r7, os_sp
        LW      r4, [r2+2]              ; S (B p q) (K r) = C' p q r
        MOV     r2, r3
        LW      r3, [r1+2]
        LI      r1, C_CP
        JMP     mk3
os_sp:  MOV     r4, r2                  ; S (B p q) r = S' p q r
        MOV     r2, r3
        LW      r3, [r1+2]
        LI      r1, C_SP
        JMP     mk3
os_c:   LI      r7, C_K
        BNE     r6, r7, os_s
        LW      r3, [r2+2]              ; S p (K q) = C p q
        MOV     r2, r1
        LI      r1, C_C
        JMP     mk2
os_s:   MOV     r3, r2                  ; S a b
        MOV     r2, r1
        LI      r1, C_S
        JMP     mk2

; head: r3 = the function part of r0 if it is a cell, else 1, which matches
; no combinator. Changes r3 only.
head:   LI      r3, 1
        AND     r3, r0
        BNZ     r3, hd_ret
        LI      r3, 1
        BLTU    r0, r14, hd_ret
        LW      r3, [r0]
hd_ret: RET

; mk2: r0 = r1 r2 r3.  mk3: r0 = r1 r2 r3 r4.  Change r1, r2.
mk2:    CALL    mkapp
        MOV     r1, r0
        MOV     r2, r3
        JMP     mkapp
mk3:    CALL    mk2
        MOV     r1, r0
        MOV     r2, r4
        JMP     mkapp

; check_free: fail if the compiled term r0 still contains a variable.
check_free:
        LI      r1, 1
        AND     r1, r0
        BNZ     r1, cf_ret
        BLTU    r0, r14, cf_leaf
        PUSH    r0
        LW      r0, [r0]
        CALL    check_free
        POP     r0
        LW      r0, [r0+2]
        JMP     check_free
cf_leaf:
        LI      r1, VAR_BASE
        BLTU    r0, r1, cf_ret
        JMP     unbound
cf_ret: RET

; ---------------------------------------------------------------------------
; Reader: builds the syntax tree from standard input
; ---------------------------------------------------------------------------
nextc:  SYS     1                       ; LOOK = next input character
        SWA     r0, LOOK
        RET

skipws: LWA     r0, LOOK                ; skip blanks and # comments; r0 = LOOK
        LI      r1, 33
        BLTU    r0, r1, sw_next         ; control characters and space (EOF is 0xFFFF)
        LI      r1, '#'
        BEQ     r0, r1, sw_comment
        RET
sw_next:
        CALL    nextc
        JMP     skipws
sw_comment:
        CALL    nextc
        LWA     r0, LOOK
        LI      r1, '\n'
        BEQ     r0, r1, skipws
        LI      r1, EOF
        BEQ     r0, r1, skipws
        JMP     sw_comment

; is_letter: r1 = 1 if r0 is A-Z or a-z, else 0. Changes r2.
is_letter:
        MOV     r1, r0
        LI      r2, 0xDF                ; fold lower case onto upper case
        AND     r1, r2
        LI      r2, 'A'
        BLTU    r1, r2, il_no
        LI      r2, 'Z'+1
        BGEU    r1, r2, il_no
        LI      r1, 1
        RET
il_no:  LI      r1, 0
        RET

; is_op: r1 = the combinator for the operator r0, or 0. Changes r2, r3.
is_op:  LI      r2, op_chars
        LI      r1, C_ADD
io_loop:
        LB      r3, [r2]
        BZ      r3, io_none
        BEQ     r3, r0, io_ret
        ADDI    r2, 1
        ADDI    r1, 2
        JMP     io_loop
io_none:
        LI      r1, 0
io_ret: RET

; parse_term: r0 = atom atom ... (application associates to the left)
parse_term:
        CALL    parse_atom
pt_loop:
        PUSH    r0                      ; the term so far
        CALL    skipws
        LI      r1, ')'
        BEQ     r0, r1, pt_end
        LI      r1, EOF
        BEQ     r0, r1, pt_end
        CALL    parse_atom
        MOV     r2, r0
        POP     r1
        CALL    mkapp
        JMP     pt_loop
pt_end: POP     r0
        RET

; parse_atom: r0 = a variable, number, operator, (term), lambda, if or rec
parse_atom:
        CALL    skipws
        LI      r1, '('
        BNE     r0, r1, pa_1
        JMP     pa_paren
pa_1:   LI      r1, '\\'
        BNE     r0, r1, pa_2
        JMP     pa_lambda
pa_2:   CALL    is_op
        BZ      r1, pa_3
        JMP     pa_op
pa_3:   LI      r1, '0'
        BLTU    r0, r1, pa_4
        LI      r1, '9'+1
        BGEU    r0, r1, pa_4
        JMP     pa_number
pa_4:   CALL    is_letter
        BZ      r1, pa_5
        JMP     pa_var
pa_5:   JMP     syntax_error

pa_var: PUSH    r0
        CALL    nextc
        POP     r0
        LWA     r1, LOOK                ; "if" or "re(c)"?
        LI      r2, 'i'
        BNE     r0, r2, pv_rec
        LI      r2, 'f'
        BNE     r1, r2, pv_make
        JMP     pa_if
pv_rec: LI      r2, 'r'
        BNE     r0, r2, pv_make
        LI      r2, 'e'
        BNE     r1, r2, pv_make
        JMP     pa_rec
pv_make:
        SHL     r0                      ; VAR_x
        LI      r1, VAR_BASE
        ADD     r0, r1
        RET

pa_if:  CALL    nextc                   ; if c t e: ((IF c) t) e
        CALL    parse_atom
        MOV     r2, r0
        LI      r1, C_IF
        CALL    mkapp
        PUSH    r0
        CALL    parse_atom
        MOV     r2, r0
        POP     r1
        CALL    mkapp
        PUSH    r0
        CALL    parse_atom
        MOV     r2, r0
        POP     r1
        JMP     mkapp

pa_rec: CALL    nextc                   ; rec f . term: Y (\f. term)
        LWA     r0, LOOK
        LI      r1, 'c'
        BEQ     r0, r1, pr_c
        JMP     syntax_error
pr_c:   CALL    nextc
        CALL    skipws
        CALL    is_letter
        BNZ     r1, pr_name
        JMP     syntax_error
pr_name:
        SHL     r0                      ; LAM_f
        LI      r1, LAM_BASE
        ADD     r0, r1
        PUSH    r0
        CALL    nextc
        CALL    skipws
        LI      r1, '.'
        BEQ     r0, r1, pr_dot
        JMP     syntax_error
pr_dot: CALL    nextc
        CALL    parse_term
        MOV     r2, r0
        POP     r1
        CALL    mkapp
        MOV     r2, r0
        LI      r1, C_Y
        JMP     mkapp

pa_number:                              ; r0 = the tagged number
        LI      r6, 0
pn_loop:
        LWA     r0, LOOK
        LI      r1, '0'
        BLTU    r0, r1, pn_done
        LI      r1, '9'+1
        BGEU    r0, r1, pn_done
        ADDI    r0, -48
        LI      r1, 10
        MUL     r6, r1
        ADD     r6, r0
        CALL    nextc
        JMP     pn_loop
pn_done:
        MOV     r0, r6
        SHL     r0
        ADDI    r0, 1
        RET

pa_op:  PUSH    r1                      ; an operator, or - and a digit
        PUSH    r0
        CALL    nextc
        POP     r0
        POP     r1
        LI      r2, '-'
        BNE     r0, r2, po_prim
        LWA     r2, LOOK
        LI      r3, '0'
        BLTU    r2, r3, po_prim
        LI      r3, '9'+1
        BGEU    r2, r3, po_prim
        CALL    pa_number               ; a negative number: -(2n+1) + 2
        NEG     r0
        ADDI    r0, 2
        RET
po_prim:
        MOV     r0, r1
        RET

pa_paren:
        CALL    nextc
        CALL    parse_term
        PUSH    r0
        CALL    skipws
        LI      r1, ')'
        BEQ     r0, r1, pp_ok
        JMP     syntax_error
pp_ok:  CALL    nextc
        POP     r0
        RET

pa_lambda:                              ; \ x y ... . body
        CALL    nextc
        CALL    skipws
        CALL    is_letter
        BNZ     r1, lam_rest
        JMP     syntax_error
lam_rest:                               ; LOOK is at a binder or at the dot
        CALL    skipws
        LI      r1, '.'
        BEQ     r0, r1, lr_body
        CALL    is_letter
        BNZ     r1, lr_bind
        JMP     syntax_error
lr_bind:
        SHL     r0                      ; (LAM_x, the rest)
        LI      r1, LAM_BASE
        ADD     r0, r1
        PUSH    r0
        CALL    nextc
        CALL    lam_rest                ; the remaining binders and the body
        MOV     r2, r0
        POP     r1
        JMP     mkapp
lr_body:
        CALL    nextc
        JMP     parse_term

; ---------------------------------------------------------------------------
; Printing
; ---------------------------------------------------------------------------
; print_term: print the combinator term r0, with application to the left
print_term:
        LI      r1, 1
        AND     r1, r0
        BNZ     r1, tm_leaf
        BLTU    r0, r14, tm_leaf
        PUSH    r0
        LW      r0, [r0]
        CALL    print_term
        LI      r0, ' '
        SYS     0
        POP     r0
        LW      r0, [r0+2]              ; the argument, in brackets if a cell
        LI      r1, 1
        AND     r1, r0
        BNZ     r1, tm_leaf
        BLTU    r0, r14, tm_leaf
        PUSH    r0
        LI      r0, '('
        SYS     0
        POP     r0
        CALL    print_term
        LI      r0, ')'
        SYS     0
        RET
tm_leaf:
        LI      r1, 1
        AND     r1, r0
        BZ      r1, tm_comb
        SAR     r0
        JMP     print_s16
tm_comb:
        LI      r1, names
        ADD     r1, r0
        LW      r0, [r1]
        JMP     print_str

; print_s16: print r0 as a signed decimal number
print_s16:
        LI      r1, 0
        BGE     r0, r1, print_u16
        PUSH    r0
        LI      r0, '-'
        SYS     0
        POP     r0
        NEG     r0
; print_u16: print r0 as an unsigned decimal number (from ../fact8.asm)
print_u16:
        LI      r1, 10
        LI      r2, 0
pu_div: DIVU    r0, r1
        PUSH    r15
        ADDI    r2, 1
        BNZ     r0, pu_div
pu_out: POP     r0
        ADDI    r0, '0'
        SYS     0
        ADDI    r2, -1
        BNZ     r2, pu_out
        RET

; print_u32: print the 32-bit number at NUM (little-endian), which it destroys.
; Each digit is a long division by 10 of the four bytes, high byte first.
print_u32:
        LI      r2, 0                   ; r2 = digits pushed
pq_digit:
        LI      r3, NUM+3
        LI      r4, 0                   ; r4 = remainder so far
        LI      r6, 0                   ; r6 = OR of the quotient bytes
pq_byte:
        MOV     r0, r4                  ; r0 = remainder * 256 + byte
        LI      r1, 256
        MUL     r0, r1
        LB      r1, [r3]
        ADD     r0, r1
        LI      r1, 10
        DIVU    r0, r1
        SB      r0, [r3]
        OR      r6, r0
        MOV     r4, r15
        LI      r1, NUM
        BEQ     r3, r1, pq_next
        ADDI    r3, -1
        JMP     pq_byte
pq_next:
        PUSH    r4
        ADDI    r2, 1
        BNZ     r6, pq_digit
        JMP     pu_out

; print_str: print the zero-terminated string at r0 (from ../fact8.asm)
print_str:
        MOV     r1, r0
ps_loop:
        LB      r0, [r1]
        BZ      r0, ps_done
        SYS     0
        ADDI    r1, 1
        JMP     ps_loop
ps_done:
        RET

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------
; Tables indexed by combinator code (the codes are even, so entry c is at +c)
rules:  .word   0, r_i, r_k, r_s, r_b, r_c, r_sp, r_bs, r_cp, r_y, r_if
        .word   r_add, r_sub, r_mul, r_div, r_mod, r_eq, r_lt
arity2: .word   0, 2, 4, 6, 6, 6, 8, 8, 8, 2, 6     ; 2 * the number of arguments
        .word   4, 4, 4, 4, 4, 4, 4
names:  .word   0, n_i, n_k, n_s, n_b, n_c, n_sp, n_bs, n_cp, n_y, n_if
        .word   n_add, n_sub, n_mul, n_div, n_mod, n_eq, n_lt

FROM:     .word 0                       ; start of the current semispace
TO:       .word 0                       ; start of the other one
LOOK:     .word 0                       ; reader: the next input character
SHOW:     .word 0                       ; nonzero: print the compiled term
GCS:      .word 0                       ; garbage collections
STEPS_HI: .word 0                       ; reductions, high word
NUM:      .word 0, 0                    ; print_u32's argument
op_chars: .ascii "+-*/%=<"
          .byte 0

n_i:    .ascii "I"
        .byte 0
n_k:    .ascii "K"
        .byte 0
n_s:    .ascii "S"
        .byte 0
n_b:    .ascii "B"
        .byte 0
n_c:    .ascii "C"
        .byte 0
n_sp:   .ascii "S'"
        .byte 0
n_bs:   .ascii "B*"
        .byte 0
n_cp:   .ascii "C'"
        .byte 0
n_y:    .ascii "Y"
        .byte 0
n_if:   .ascii "IF"
        .byte 0
n_add:  .ascii "+"
        .byte 0
n_sub:  .ascii "-"
        .byte 0
n_mul:  .ascii "*"
        .byte 0
n_div:  .ascii "/"
        .byte 0
n_mod:  .ascii "%"
        .byte 0
n_eq:   .ascii "="
        .byte 0
n_lt:   .ascii "<"
        .byte 0

msg_error:    .ascii "error: "
              .byte 0
msg_unbound:  .ascii "unbound variable "
              .byte 0
msg_apply:    .ascii "only a function can be applied"
              .byte 0
msg_operand:  .ascii "an operator needs a number"
              .byte 0
msg_divzero:  .ascii "division by zero"
              .byte 0
msg_if:       .ascii "if needs a number"
              .byte 0
msg_oom:      .ascii "out of memory"
              .byte 0
msg_stack:    .ascii "out of stack"
              .byte 0
msg_loop:     .ascii "a value defined as itself"
              .byte 0
msg_syntax:   .ascii "syntax error at "
              .byte 0
msg_eof:      .ascii "end of input"
              .byte 0
msg_function: .ascii "<function>"
              .byte 0
msg_stats1:   .ascii "\n["
              .byte 0
msg_stats2:   .ascii " reductions, "
              .byte 0
msg_stats3:   .ascii " collections]\n"
              .byte 0
image_end:
