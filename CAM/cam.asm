; cam.asm - the Categorical Abstract Machine in VM16 assembly.
;
; The CAM of Cousineau, Curien and Mauny (1985). It reads a lambda term from
; standard input, compiles it to CAM code, runs the code and prints the result,
; followed by the number of CAM instructions executed and garbage collections.
;
;   python3 ../vm16asm.py cam.asm
;   ../vm16 cam.v16 < fac.lam                      ->  5040
;   echo '(\a b.a) 4 3' | ../vm16 cam.v16          ->  4
;
; Input syntax (as in ../secd.asm, plus rec):
;   term   = atom atom ...               application, left-associative
;   atom   = x | 42 | -42 | op | (term) | \x y ... . term
;          | if atom atom atom | rec f . term
;   x      single letter, a-z or A-Z;  \x y.M means \x.\y.M
;   42     a 15-bit signed number, -16384..16383
;   op     + - * / % = <  curried two-argument primitives: - 7 2 = 5.
;          / and % truncate towards zero. = and < return 1 or 0.
;   if c t e   evaluates c, then only one of t and e; 0 is false.
;   rec f.\x.M   the recursive function f, where M may call f.
;          "if" and "rec" are keywords: write "i f" and "r e" for applications.
;   #      comment to the end of the line
;
; The machine has three registers: the term (r8), which holds the current
; environment or the value just computed, the code pointer (r9), and the stack,
; which is the VM16 data stack. Its values are
;     numbers   tagged words n*2+1, so they are odd and never allocated
;     ()        0, the empty environment
;     pairs     heap cells (PAIR, fst, snd)
;     closures  heap cells (CLO, code address, environment)
; An environment is a chain of pairs ((((), v_n) ...), v_1), so the variable
; with de Bruijn index i is fst^i; snd.
;
; Instructions (one opcode byte, then the operands):
;     STOP              print the term and halt
;     ACC i             term = fst^i; snd of term      (the variable i)
;     PUSH              push term
;     SWAP              exchange term and the top of the stack
;     CONS              term = (pop, term)
;     CUR end           term = [code after the operand : term]; continue at end
;     APP               term = ([C : s], t)  ->  term = (s, t), push the return
;                       address, continue at C
;     RET               continue at the address popped from the stack
;     QUOTE v           term = v
;     BRANCH else       pop the environment into term; continue at else if the
;                       old term was 0
;     JUMP addr         continue at addr
;     REC end           term = k, a closure [code : (term, k)] that contains
;                       itself; continue at end
;     ADD .. LT         term = pop op term          (the + - * / % = < operators)
; Compilation, with the names of the environment in a compile-time list:
;     [[x]]          = ACC i, where i is the position of x in the list
;     [[42]]         = QUOTE 42
;     [[\x.M]]       = CUR end; [[M]] with x added; RET; end:
;     [[M N]]        = PUSH; [[M]]; SWAP; [[N]]; CONS; APP
;     [[op M N]]     = PUSH; [[M]]; SWAP; [[N]]; op     (CONS and op fused)
;     [[op]]         = [[\a b.op a b]]
;     [[if c t e]]   = PUSH; [[c]]; BRANCH else; [[t]]; JUMP end; else: [[e]]; end:
;     [[rec f.\x.M]] = REC end; [[M]] with f and x added; RET; end:
;
; Garbage collection: Cheney's copying collector over two semispaces. The roots
; are the term and the stack. Every instruction that allocates first makes sure
; there is room for two cells, so a collection never happens halfway through
; an instruction. Return addresses on the stack point outside the heap and the
; collector leaves them alone, as it does numbers.

        .equ    T_VAR, 1                ; syntax tree: name
        .equ    T_LAM, 2                ; name, A = body
        .equ    T_APP, 3                ; A = rator, B = rand
        .equ    T_INT, 4                ; A = value
        .equ    T_PRIM, 5               ; operator character
        .equ    T_IF, 6                 ; A = condition, B = SEL cell
        .equ    T_SEL, 7                ; A = then, B = else
        .equ    T_REC, 8                ; name, A = body
        .equ    T_NAME, 9               ; compile-time environment: name, B = next
        .equ    T_PAIR, 10              ; machine values: A = fst, B = snd
        .equ    T_CLO, 11               ; A = code address, B = environment
        .equ    T_FWD, 12               ; a cell already copied by the collector

        .equ    OP_STOP, 0
        .equ    OP_ACC, 1
        .equ    OP_PUSH, 2
        .equ    OP_SWAP, 3
        .equ    OP_CONS, 4
        .equ    OP_CUR, 5
        .equ    OP_APP, 6
        .equ    OP_RET, 7
        .equ    OP_QUOTE, 8
        .equ    OP_BRANCH, 9
        .equ    OP_JUMP, 10
        .equ    OP_REC, 11
        .equ    OP_ADD, 12              ; then SUB MUL DIV MOD EQ LT, as in op_chars

        .equ    CELL, 6                 ; bytes per cell
        .equ    CODE, 0x3000            ; compiled CAM code
        .equ    CODE_END, 0x4000
        .equ    SEMI, 0x4000            ; bytes per semispace
        .equ    HEAP1, 0x4000
        .equ    HEAP2, 0x8000
        .equ    STACK_TOP, 0xE000       ; the CAM stack grows down from here
        .equ    EOF, 0xFFFF

        .org    0x2000
        .entry  start
        .stacks STACK_TOP, 0xF000

start:  LI      r10, HEAP1              ; r10 = heap pointer, r11 = heap end
        LI      r11, HEAP1+SEMI
        SWA     r10, FROM
        LI      r0, HEAP2
        SWA     r0, TO
        CALL    nextc                   ; LOOK = first input character
        CALL    parse_term              ; r0 = the syntax tree
        PUSH    r0
        CALL    skipws
        LI      r1, EOF
        BEQ     r0, r1, st_ok
        JMP     syntax_error            ; something left over, such as ')'
st_ok:  POP     r0
        LI      r1, 0                   ; the empty compile-time environment
        CALL    compile
        LI      r0, OP_STOP
        CALL    emit_byte
        LWA     r10, FROM               ; the syntax tree is garbage now
        LI      r8, 0                   ; term = ()
        LI      r9, CODE
        LI      r12, 0                  ; r12 = instructions executed, low word

; ---------------------------------------------------------------------------
; The machine: one CAM instruction per pass
; ---------------------------------------------------------------------------
next:   ADDI    r12, 1
        BZ      r12, count_hi
nx_go:  LB      r0, [r9]
        ADDI    r9, 1
        SHL     r0
        LI      r1, op_table
        ADD     r1, r0
        LW      r1, [r1]
        JR      r1

op_table:
        .word   op_stop, op_acc, op_push, op_swap, op_cons, op_cur, op_app
        .word   op_ret, op_quote, op_branch, op_jump, op_rec
        .word   op_add, op_sub, op_mul, op_div, op_mod, op_eq, op_lt

count_hi:                               ; the high word of the count
        LWA     r0, STEPS_HI
        ADDI    r0, 1
        SWA     r0, STEPS_HI
        JMP     nx_go

op_acc: LB      r0, [r9]                ; fst^i; snd
        ADDI    r9, 1
acc_lp: BZ      r0, acc_snd
        LW      r8, [r8+2]
        ADDI    r0, -1
        JMP     acc_lp
acc_snd:
        LW      r8, [r8+4]
        JMP     next

op_push:
        PUSH    r8
        JMP     next

op_swap:
        POP     r0
        PUSH    r8
        MOV     r8, r0
        JMP     next

op_cons:
        CALL    reserve
        POP     r1
        MOV     r0, r10
        ADDI    r10, CELL
        LI      r2, T_PAIR
        SW      r2, [r0]
        SW      r1, [r0+2]
        SW      r8, [r0+4]
        MOV     r8, r0
        JMP     next

op_cur: CALL    reserve
        MOV     r0, r10
        ADDI    r10, CELL
        LI      r2, T_CLO
        SW      r2, [r0]
        MOV     r1, r9                  ; the code starts after the operand
        ADDI    r1, 2
        SW      r1, [r0+2]
        SW      r8, [r0+4]
        MOV     r8, r0
        LW      r9, [r9]                ; continue after the code
        JMP     next

op_app: CALL    reserve
        LW      r1, [r8+2]              ; the closure [C : s]
        LI      r2, 1
        AND     r2, r1
        BNZ     r2, app_err             ; a number
        BZ      r1, app_err             ; ()
        LW      r2, [r1]
        LI      r3, T_CLO
        BEQ     r2, r3, app_ok
app_err:
        LI      r0, msg_apply
        JMP     fail
app_ok: MOV     r0, r10                 ; term = (s, t)
        ADDI    r10, CELL
        LI      r2, T_PAIR
        SW      r2, [r0]
        LW      r2, [r1+4]
        SW      r2, [r0+2]
        LW      r2, [r8+4]
        SW      r2, [r0+4]
        MOV     r8, r0
        PUSH    r9                      ; the return address
        LW      r9, [r1+2]
        JMP     next

op_ret: POP     r9
        JMP     next

op_quote:
        LW      r8, [r9]
        ADDI    r9, 2
        JMP     next

op_branch:
        MOV     r1, r8                  ; the condition
        POP     r8                      ; the environment
        LI      r2, 1
        AND     r2, r1
        BZ      r2, branch_err
        LI      r2, 1                   ; the number 0
        BEQ     r1, r2, op_jump
        ADDI    r9, 2
        JMP     next
op_jump:
        LW      r9, [r9]
        JMP     next
branch_err:
        LI      r0, msg_if
        JMP     fail

op_rec: CALL    reserve
        MOV     r0, r10                 ; r0 = the pair (term, k)
        ADDI    r10, CELL
        MOV     r1, r10                 ; r1 = the closure k
        ADDI    r10, CELL
        LI      r2, T_PAIR
        SW      r2, [r0]
        SW      r8, [r0+2]
        SW      r1, [r0+4]
        LI      r2, T_CLO
        SW      r2, [r1]
        MOV     r2, r9
        ADDI    r2, 2
        SW      r2, [r1+2]
        SW      r0, [r1+4]
        MOV     r8, r1
        LW      r9, [r9]
        JMP     next

; The operators: r1 = the popped number a, r8 = the number b, both tagged.
op_add: CALL    arith                   ; (2a+1) + (2b+1) - 1
        ADD     r8, r1
        ADDI    r8, -1
        JMP     next
op_sub: CALL    arith                   ; (2a+1) - (2b+1) + 1
        SUB     r1, r8
        ADDI    r1, 1
        MOV     r8, r1
        JMP     next
op_mul: CALL    arith                   ; a * 2b + 1
        SAR     r1
        ADDI    r8, -1
        MUL     r8, r1
        ADDI    r8, 1
        JMP     next
op_div: CALL    arith
        SAR     r1
        MOV     r2, r8
        SAR     r2
        CALL    sdiv
        MOV     r8, r1
        JMP     tag_r8
op_mod: CALL    arith
        SAR     r1
        MOV     r2, r8
        SAR     r2
        CALL    sdiv
        MOV     r8, r15
tag_r8: SHL     r8
        ADDI    r8, 1
        JMP     next
op_eq:  CALL    arith
        LI      r0, 3                   ; 1
        BEQ     r1, r8, cmp_set
        LI      r0, 1                   ; 0
cmp_set:
        MOV     r8, r0
        JMP     next
op_lt:  CALL    arith                   ; tagging keeps the order
        LI      r0, 3
        BLT     r1, r8, cmp_set
        LI      r0, 1
        JMP     cmp_set

; arith: r1 = the number popped from the CAM stack; fail unless r1 and r8
; are both numbers. Changes r2, r3.
arith:  POP     r1
        MOV     r2, r1
        AND     r2, r8
        LI      r3, 1
        AND     r2, r3
        BZ      r2, arith_err
        RET
arith_err:
        LI      r0, msg_operand
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

op_stop:
        MOV     r0, r8
        CALL    print_value
        LI      r0, msg_stats1          ; "\n["
        CALL    print_str
        SWA     r12, NUM
        LWA     r0, STEPS_HI
        SWA     r0, NUM+2
        CALL    print_u32
        LI      r0, msg_stats2          ; " instructions, "
        CALL    print_str
        LWA     r0, GCS
        CALL    print_u16
        LI      r0, msg_stats3          ; " collections]\n"
        CALL    print_str
        LI      r0, 0
        HALT

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

unbound:                                ; the name is the high byte of r2
        LI      r0, msg_error
        CALL    print_str
        LI      r0, msg_unbound
        CALL    print_str
        MOV     r0, r2
        LI      r1, 256
        DIVU    r0, r1
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
; reserve: make sure two cells are free, collecting garbage if needed.
reserve:
        MOV     r0, r11
        SUB     r0, r10
        LI      r1, 2*CELL
        BLTU    r0, r1, rs_gc
        RET
rs_gc:  CALL    gc
        MOV     r0, r11
        SUB     r0, r10
        LI      r1, 2*CELL
        BLTU    r0, r1, rs_oom
        RET
rs_oom: LI      r0, msg_oom
        JMP     fail

; alloc: r0 = new cell with tag r0 and fields r1, r2, for the reader and the
; compiler. Changes r3 only.
alloc:  MOV     r3, r10
        ADDI    r3, CELL
        BLTU    r11, r3, rs_oom
        SW      r0, [r10]
        SW      r1, [r10+2]
        SW      r2, [r10+4]
        MOV     r0, r10
        MOV     r10, r3
        RET

; gc: copy everything reachable from the term and the stack into the other
; semispace. Changes r0-r7.
gc:     LWA     r0, GCS
        ADDI    r0, 1
        SWA     r0, GCS
        LWA     r10, TO
        MOV     r6, r10                 ; r6 = scan pointer
        MOV     r0, r8
        CALL    forward
        MOV     r8, r0
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
        LW      r0, [r6+2]
        CALL    forward
        SW      r0, [r6+2]
        LW      r0, [r6+4]
        CALL    forward
        SW      r0, [r6+4]
        ADDI    r6, CELL
        JMP     gc_scan
gc_flip:                                ; the copy becomes the current space
        LWA     r0, FROM
        LWA     r1, TO
        SWA     r1, FROM
        SWA     r0, TO
        MOV     r11, r1
        LI      r2, SEMI
        ADD     r11, r2
        RET

; forward: r0 = the new address of the cell r0, copying it if needed.
; Numbers and addresses outside from-space (code, ()) are returned unchanged.
; Changes r1-r5.
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
        LI      r4, T_FWD
        BNE     r3, r4, fw_copy
        LW      r0, [r0+2]              ; copied before: follow the forwarding address
fw_ret: RET
fw_copy:
        SW      r3, [r10]
        LW      r1, [r0+2]
        SW      r1, [r10+2]
        LW      r1, [r0+4]
        SW      r1, [r10+4]
        SW      r4, [r0]                ; leave a forwarding address behind
        SW      r10, [r0+2]
        MOV     r0, r10
        ADDI    r10, CELL
        RET

; ---------------------------------------------------------------------------
; Compiler: syntax tree to CAM code at CP
; ---------------------------------------------------------------------------
; compile: emit the code of the expression r0, in the compile-time
; environment r1 (a list of NAME cells, innermost first).
compile:
        LW      r2, [r0]
        LI      r3, 0xFF
        AND     r2, r3                  ; r2 = type
        LI      r3, T_VAR
        BNE     r2, r3, c_int
        LW      r2, [r0]                ; find the name: its tag as a NAME
        ADDI    r2, T_NAME-T_VAR
        LI      r3, 0                   ; r3 = de Bruijn index
cv_loop:
        BNZ     r1, cv_cmp
        JMP     unbound
cv_cmp: LW      r4, [r1]
        BEQ     r4, r2, cv_found
        LW      r1, [r1+4]
        ADDI    r3, 1
        JMP     cv_loop
cv_found:
        LI      r0, OP_ACC
        CALL    emit_byte
        MOV     r0, r3
        JMP     emit_byte

c_int:  LI      r3, T_INT
        BNE     r2, r3, c_lam
        LW      r3, [r0+2]              ; tag the number
        SHL     r3
        ADDI    r3, 1
        LI      r0, OP_QUOTE
        CALL    emit_byte
        MOV     r0, r3
        JMP     emit_word

c_lam:  LI      r3, T_LAM
        BNE     r2, r3, c_rec
        PUSH    r0                      ; CUR end; body with x added; RET
        LW      r0, [r0]
        ADDI    r0, T_NAME-T_LAM
        MOV     r2, r1
        LI      r1, 0
        CALL    alloc
        MOV     r1, r0
        POP     r0
        LW      r0, [r0+2]
        LI      r2, OP_CUR
        JMP     emit_closure

c_rec:  LI      r3, T_REC
        BNE     r2, r3, c_if
        LW      r4, [r0+2]              ; the body must be \x.M
        LW      r2, [r4]
        LI      r3, 0xFF
        AND     r2, r3
        LI      r3, T_LAM
        BEQ     r2, r3, cr_ok
        LI      r0, msg_rec
        JMP     fail
cr_ok:  PUSH    r4                      ; REC end; M with f and x added; RET
        LW      r0, [r0]
        ADDI    r0, T_NAME-T_REC
        MOV     r2, r1
        LI      r1, 0
        CALL    alloc                   ; f : env
        MOV     r2, r0
        POP     r4
        PUSH    r4
        LW      r0, [r4]
        ADDI    r0, T_NAME-T_LAM
        LI      r1, 0
        CALL    alloc                   ; x : f : env
        MOV     r1, r0
        POP     r4
        LW      r0, [r4+2]
        LI      r2, OP_REC
        JMP     emit_closure

c_if:   LI      r3, T_IF
        BEQ     r2, r3, ci_1
        JMP     c_app
ci_1:   PUSH    r1                      ; frame: [dsp] = node, [dsp+2] = env
        PUSH    r0
        LI      r0, OP_PUSH
        CALL    emit_byte
        GETDSP  r5
        LW      r1, [r5+2]
        LW      r0, [r5]
        LW      r0, [r0+2]
        CALL    compile                 ; c
        LI      r0, OP_BRANCH
        CALL    emit_byte
        LWA     r0, CP
        PUSH    r0                      ; [dsp] = where to patch else
        CALL    emit_word
        GETDSP  r5
        LW      r1, [r5+4]
        LW      r0, [r5+2]
        LW      r0, [r0+4]
        LW      r0, [r0+2]
        CALL    compile                 ; t
        LI      r0, OP_JUMP
        CALL    emit_byte
        LWA     r0, CP
        PUSH    r0                      ; [dsp] = where to patch end
        CALL    emit_word
        GETDSP  r5
        LW      r1, [r5+2]              ; else:
        LWA     r0, CP
        SW      r0, [r1]
        LW      r1, [r5+6]
        LW      r0, [r5+4]
        LW      r0, [r0+4]
        LW      r0, [r0+4]
        CALL    compile                 ; e
        POP     r1                      ; end:
        LWA     r0, CP
        SW      r0, [r1]
        POP     r0
        POP     r0
        POP     r0
        RET

c_app:  LI      r3, T_APP
        BEQ     r2, r3, ca_1
        JMP     c_prim
ca_1:   PUSH    r1                      ; frame: [dsp] = node, [dsp+2] = env
        PUSH    r0
        LI      r0, OP_PUSH
        CALL    emit_byte
        GETDSP  r5                      ; is it (op M) N?
        LW      r0, [r5]
        LW      r2, [r0+2]
        LW      r3, [r2]
        LI      r4, 0xFF
        AND     r3, r4
        LI      r4, T_APP
        BNE     r3, r4, ca_gen
        LW      r3, [r2+2]
        LW      r3, [r3]
        LI      r4, 0xFF
        AND     r3, r4
        LI      r4, T_PRIM
        BNE     r3, r4, ca_gen
        LW      r1, [r5+2]              ; PUSH; M; SWAP; N; op
        LW      r0, [r2+4]
        CALL    compile
        LI      r0, OP_SWAP
        CALL    emit_byte
        GETDSP  r5
        LW      r1, [r5+2]
        LW      r0, [r5]
        LW      r0, [r0+4]
        CALL    compile
        POP     r0
        POP     r1
        LW      r0, [r0+2]
        LW      r0, [r0+2]
        LW      r0, [r0]
        CALL    prim_opcode
        JMP     emit_byte
ca_gen: LW      r1, [r5+2]              ; PUSH; M; SWAP; N; CONS; APP
        LW      r0, [r0+2]
        CALL    compile
        LI      r0, OP_SWAP
        CALL    emit_byte
        POP     r0
        POP     r1
        LW      r0, [r0+4]
        CALL    compile
        LI      r0, OP_CONS
        CALL    emit_byte
        LI      r0, OP_APP
        JMP     emit_byte

c_prim: LI      r3, T_PRIM              ; op on its own: \a b.op a b, that is
        BEQ     r2, r3, cp_ok           ; CUR e1; CUR e2; PUSH; ACC 1; SWAP; ACC 0;
        LI      r0, msg_internal        ; op; RET; e2: RET; e1:
        JMP     fail
cp_ok:  LW      r0, [r0]
        CALL    prim_opcode
        PUSH    r0
        LI      r0, OP_CUR
        CALL    emit_byte
        LWA     r0, CP
        ADDI    r0, 14                  ; e1
        CALL    emit_word
        LI      r0, OP_CUR
        CALL    emit_byte
        LWA     r0, CP
        ADDI    r0, 10                  ; e2
        CALL    emit_word
        LI      r0, OP_PUSH
        CALL    emit_byte
        LI      r0, OP_ACC
        CALL    emit_byte
        LI      r0, 1
        CALL    emit_byte
        LI      r0, OP_SWAP
        CALL    emit_byte
        LI      r0, OP_ACC
        CALL    emit_byte
        LI      r0, 0
        CALL    emit_byte
        POP     r0
        CALL    emit_byte
        LI      r0, OP_RET
        CALL    emit_byte
        LI      r0, OP_RET
        JMP     emit_byte

; emit_closure: emit "op end; the code of r0 in environment r1; RET; end:",
; where op = r2 is CUR or REC.
emit_closure:
        PUSH    r1
        PUSH    r0
        MOV     r0, r2
        CALL    emit_byte
        LWA     r3, CP                  ; where to patch end
        CALL    emit_word
        POP     r0
        POP     r1
        PUSH    r3
        CALL    compile
        LI      r0, OP_RET
        CALL    emit_byte
        POP     r3
        LWA     r0, CP
        SW      r0, [r3]
        RET

; prim_opcode: r0 = the opcode for the PRIM tag r0. Changes r1-r3.
prim_opcode:
        LI      r1, 256
        DIVU    r0, r1                  ; the operator character
        LI      r1, op_chars
        LI      r2, OP_ADD
po_loop:
        LB      r3, [r1]
        BEQ     r3, r0, po_done
        ADDI    r1, 1
        ADDI    r2, 1
        JMP     po_loop
po_done:
        MOV     r0, r2
        RET

; emit_byte, emit_word: append r0 to the code. Change r1, r2.
emit_byte:
        LWA     r1, CP
        SB      r0, [r1]
        ADDI    r1, 1
        JMP     emit_end
emit_word:
        LWA     r1, CP
        SW      r0, [r1]
        ADDI    r1, 2
emit_end:
        SWA     r1, CP
        LI      r2, CODE_END
        BGEU    r1, r2, code_full
        RET
code_full:
        LI      r0, msg_code
        JMP     fail

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

; is_op: r1 = r0 if r0 is an operator character, else 0. Changes r2.
is_op:  LI      r2, op_chars
io_loop:
        LB      r1, [r2]
        BZ      r1, io_ret
        BEQ     r1, r0, io_ret
        ADDI    r2, 1
        JMP     io_loop
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
        LI      r0, T_APP
        CALL    alloc
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
        LI      r1, 256                 ; tag = name << 8 | T_VAR
        MUL     r0, r1
        ADDI    r0, T_VAR
        LI      r1, 0
        LI      r2, 0
        JMP     alloc

pa_if:  CALL    nextc                   ; if c t e: IF(c, SEL(t, e))
        CALL    parse_atom
        PUSH    r0
        CALL    parse_atom
        PUSH    r0
        CALL    parse_atom
        MOV     r2, r0
        POP     r1
        LI      r0, T_SEL
        CALL    alloc
        MOV     r2, r0
        POP     r1
        LI      r0, T_IF
        JMP     alloc

pa_rec: CALL    nextc                   ; rec f . term
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
        LI      r1, 256                 ; tag = name << 8 | T_REC
        MUL     r0, r1
        ADDI    r0, T_REC
        PUSH    r0
        CALL    nextc
        CALL    skipws
        LI      r1, '.'
        BEQ     r0, r1, pr_dot
        JMP     syntax_error
pr_dot: CALL    nextc
        CALL    parse_term
        MOV     r1, r0
        POP     r0
        LI      r2, 0
        JMP     alloc

pa_number:
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
        LI      r0, T_INT
        MOV     r1, r6
        LI      r2, 0
        JMP     alloc

pa_op:  PUSH    r0                      ; an operator, or - and a digit
        CALL    nextc
        POP     r0
        LI      r1, '-'
        BNE     r0, r1, po_prim
        LWA     r1, LOOK
        LI      r2, '0'
        BLTU    r1, r2, po_prim
        LI      r2, '9'+1
        BGEU    r1, r2, po_prim
        CALL    pa_number               ; a negative number
        LW      r1, [r0+2]
        NEG     r1
        SW      r1, [r0+2]
        RET
po_prim:
        LI      r1, 256                 ; tag = op << 8 | T_PRIM
        MUL     r0, r1
        ADDI    r0, T_PRIM
        LI      r1, 0
        LI      r2, 0
        JMP     alloc

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
        LI      r1, 256                 ; tag = name << 8 | T_LAM
        MUL     r0, r1
        ADDI    r0, T_LAM
        PUSH    r0
        CALL    nextc
        CALL    lam_rest                ; the remaining binders and the body
        MOV     r1, r0
        POP     r0
        LI      r2, 0
        JMP     alloc
lr_body:
        CALL    nextc
        JMP     parse_term

; ---------------------------------------------------------------------------
; Printing
; ---------------------------------------------------------------------------
; print_value: print the machine value r0: a number, (), <closure> or a pair
print_value:
        LI      r1, 1
        AND     r1, r0
        BZ      r1, pv_ptr
        SAR     r0
        JMP     print_s16
pv_ptr: BNZ     r0, pv_cell
        LI      r0, msg_unit
        JMP     print_str
pv_cell:
        LW      r1, [r0]
        LI      r2, T_CLO
        BNE     r1, r2, pv_pair
        LI      r0, msg_closure
        JMP     print_str
pv_pair:
        PUSH    r0
        LI      r0, '('
        SYS     0
        POP     r0
        PUSH    r0
        LW      r0, [r0+2]
        CALL    print_value
        LI      r0, msg_comma
        CALL    print_str
        POP     r0
        LW      r0, [r0+4]
        CALL    print_value
        LI      r0, ')'
        SYS     0
        RET

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
FROM:     .word 0                       ; start of the current semispace
TO:       .word 0                       ; start of the other one
CP:       .word CODE                    ; compiler: the next free code byte
LOOK:     .word 0                       ; reader: the next input character
GCS:      .word 0                       ; garbage collections
STEPS_HI: .word 0                       ; instructions executed, high word
NUM:      .word 0, 0                    ; print_u32's argument
op_chars: .ascii "+-*/%=<"
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
msg_rec:      .ascii "rec needs a lambda: rec f.\\x.M"
              .byte 0
msg_oom:      .ascii "out of memory"
              .byte 0
msg_code:     .ascii "out of code space"
              .byte 0
msg_internal: .ascii "internal error"
              .byte 0
msg_syntax:   .ascii "syntax error at "
              .byte 0
msg_eof:      .ascii "end of input"
              .byte 0
msg_unit:     .ascii "()"
              .byte 0
msg_closure:  .ascii "<closure>"
              .byte 0
msg_comma:    .ascii ", "
              .byte 0
msg_stats1:   .ascii "\n["
              .byte 0
msg_stats2:   .ascii " instructions, "
              .byte 0
msg_stats3:   .ascii " collections]\n"
              .byte 0
