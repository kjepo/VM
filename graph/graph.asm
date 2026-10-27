; graph.asm - combinator graph reduction in VM16 assembly.
;
; Reads a combinator graph from standard input, reduces it lazily, and prints
; the result, followed by the number of reductions and garbage collections.
; The graph is compiled from a lambda term by lam2graph.py:
;
;   python3 ../vm16asm.py graph.asm
;   python3 lam2graph.py fac.lam                   ->  fac.graph
;   ../vm16 graph.v16 < fac.graph                  ->  5040
;   echo 'K 4 @ 3 @' | ../vm16 graph.v16           ->  4   (K 4 3)
;   ./run fac.lam                                  ->  both steps
;
; Input: the graph in postfix, as tokens separated by blanks:
;   I K S B C S' B* C' Y IF + - * / % = <    a combinator
;   42 -42                                   a 15-bit signed number
;   @                                        f a @ is f applied to a
;   #                                        comment to the end of the line
; so "K 4 @ 3 @" is K 4 3, and "K 4 3 @ @" is K (4 3). Each token pushes a
; word on the data stack, and @ replaces the top two by a new cell.
;
; The graph. Every heap cell is an application node of two words, (fun, arg).
; Everything else is a word that is not a heap address:
;     numbers       odd words n*2+1
;     combinators   small even codes C_I .. C_LT
; so a word is a cell exactly when it is even and at least HEAP_LO.
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
        .equ    C_ADD, 22               ; then SUB MUL DIV MOD EQ LT
        .equ    C_LT, 34
        .equ    FWD, 0                  ; fun field of a cell copied by the collector

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
        CALL    load                    ; r0 = the graph
        LI      r12, 0
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

; mkapp: r0 = a new cell (r1, r2), for the loader, which never collects. Changes nothing else.
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
; Loader: builds the graph from its postfix text on standard input
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

; is_end: r1 = 1 if r0 ends a token (a blank, a control character or EOF),
; else 0.
is_end: LI      r1, 33
        BLTU    r0, r1, ie_yes
        LI      r1, EOF
        BEQ     r0, r1, ie_yes
        LI      r1, 0
        RET
ie_yes: LI      r1, 1
        RET

; is_digit: r1 = 1 if r0 is 0-9, else 0
is_digit:
        LI      r1, '0'
        BLTU    r0, r1, id_no
        LI      r1, '9'+1
        BGEU    r0, r1, id_no
        LI      r1, 1
        RET
id_no:  LI      r1, 0
        RET

; load: r0 = the graph read from standard input. Each token pushes a word on
; the data stack, and @ replaces the top two (fun, arg) by a cell. No
; collection happens while loading, so mkapp's "out of memory" is final.
load:
ld_loop:
        CALL    skipws
        LI      r1, EOF
        BNE     r0, r1, ld_more
        JMP     ld_end
ld_more:
        GETDSP  r1                      ; room for one more word?
        BGEU    r1, r13, ld_room
        JMP     stack_full
ld_room:
        LI      r1, '@'
        BEQ     r0, r1, ld_app
        CALL    is_digit
        BZ      r1, ld_name
        CALL    pa_number
        JMP     ld_push
ld_app: GETDSP  r1                      ; f a @: needs two words
        LI      r2, STACK_TOP-4
        BLTU    r2, r1, ld_bad
        CALL    nextc
        POP     r2
        POP     r1
        CALL    mkapp
        JMP     ld_push
ld_name:                                ; r6 = the first one or two characters
        MOV     r6, r0
        CALL    nextc                   ; r0 = LOOK
        LI      r1, '-'
        BNE     r6, r1, ln_2
        CALL    is_digit                ; - and a digit: a negative number
        BZ      r1, ln_2
        CALL    pa_number               ; -(2n+1) + 2
        NEG     r0
        ADDI    r0, 2
        JMP     ld_push
ln_2:   CALL    is_end
        BNZ     r1, ln_find
        LI      r1, 256                 ; a second character, in the high byte
        MUL     r0, r1
        OR      r6, r0
        CALL    nextc
        CALL    is_end
        BZ      r1, ld_bad
ln_find:                                ; compare with the first word of each name
        LI      r0, C_I
ln_loop:
        LI      r1, names
        ADD     r1, r0
        LW      r1, [r1]
        LW      r1, [r1]                ; a one-letter name is followed by its 0
        BEQ     r1, r6, ld_push
        ADDI    r0, 2
        LI      r1, C_LT+2
        BNE     r0, r1, ln_loop
        LI      r0, msg_token
        JMP     fail
ld_bad: JMP     syntax_error
ld_push:
        PUSH    r0
        JMP     ld_loop
ld_end: GETDSP  r1                      ; exactly one word must be left
        LI      r2, STACK_TOP-2
        BNE     r1, r2, ld_bad
        POP     r0
        RET

pa_number:                              ; r0 = the tagged number at LOOK
        LI      r6, 0
pn_loop:
        LWA     r0, LOOK
        CALL    is_digit
        BZ      r1, pn_done
        ADDI    r0, -48
        LI      r1, 10
        MUL     r6, r1
        ADD     r6, r0
        CALL    nextc
        JMP     pn_loop
pn_done:
        CALL    is_end                  ; 12x is not a number
        BZ      r1, ld_bad
        MOV     r0, r6
        SHL     r0
        ADDI    r0, 1
        RET
; ---------------------------------------------------------------------------
; Printing
; ---------------------------------------------------------------------------
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
LOOK:     .word 0                       ; loader: the next input character
GCS:      .word 0                       ; garbage collections
STEPS_HI: .word 0                       ; reductions, high word
NUM:      .word 0, 0                    ; print_u32's argument

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
msg_token:    .ascii "unknown combinator"
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

