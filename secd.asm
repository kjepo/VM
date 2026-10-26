; secd.asm - Landin's SECD machine in VM16 assembly.
;
; Reads a lambda term from standard input, evaluates it with the interpreted
; SECD machine of secd-tutorial.tex (figure 4: rules Var, Abs, App, Call, Prim
; and Return), extended with integers and a conditional (rules If and Sel),
; and prints the result, followed by the number of transitions and garbage
; collections.
;
;   python3 vm16asm.py secd.asm
;   echo '(\a b.a) 4 3' | ./vm16 secd.v16          ->  4
;   ./vm16 secd.v16 < fac.lam                      ->  120
;
; Input syntax:
;   term   = atom atom ...               application, left-associative
;   atom   = x | 42 | -42 | op | (term) | \x y ... . term | if atom atom atom
;   x      single letter, a-z or A-Z;  \x y.M means \x.\y.M
;   42     a 16-bit signed number constant
;   op     + - * / % = <  curried two-argument primitives:  - 7 2 = 5.
;          / and % truncate towards zero. = and < return the Church booleans
;          \x y.x and \x y.y.
;   if c t e   evaluates c, then only one of t and e. The condition may be a
;          Church boolean, or a number (0 is false). "if" is a keyword, so
;          write "i f" to apply the variable i to f.
;   #      comment to the end of the line
; A Church numeral n prints as a number with  n (+ 1) 0.
;
; Heap: every object is one 3-word cell
;     +0  tag   low byte = type, high byte = variable name (VAR, LAM, ENV)
;               or operator character (PRIM)
;     +2  A
;     +4  B
; with these types:
;     VAR   name                          INT   A = value
;     LAM   name, A = body                PRIM  op, A = arguments so far (0, 1),
;     APP   A = rator, B = rand                     B = the first argument's value
;     IF    A = condition, B = SEL cell   SEL   A = then, B = else
;     CLO   A = the LAM cell, B = environment
;     ENV   name, A = value, B = next     CONS  A = head, B = tail
; S, C and D are lists of CONS cells. E is a list of ENV cells. A dump frame
; is three CONS cells: D = S' : E' : C' : D'. The control marker @ is the
; static cell at_cell, outside the heap, and so are the closures for true and
; false that = and < return. Nil is 0.
;
; Garbage collection: Cheney's copying collector over two semispaces. It runs
; only at the start of a transition, when everything live is reachable from
; S, E, C and D, and leaves room for RESERVE more cells.

        .equ    T_VAR, 1
        .equ    T_LAM, 2
        .equ    T_APP, 3
        .equ    T_INT, 4
        .equ    T_PRIM, 5
        .equ    T_IF, 6                 ; types from IF on have two pointers
        .equ    T_SEL, 7
        .equ    T_CLO, 8                ; types from CLO on are not expressions
        .equ    T_ENV, 9
        .equ    T_CONS, 10
        .equ    T_FWD, 11               ; a cell already copied by the collector
        .equ    T_AT, 12                ; the control marker @

        .equ    CELL, 6                 ; bytes per cell
        .equ    SEMI, 0x4000            ; bytes per semispace
        .equ    HEAP1, 0x4000
        .equ    HEAP2, 0x8000
        .equ    RESERVE, 5*CELL         ; the most one transition allocates (Call)
        .equ    EOF, 0xFFFF

        .org    0x2000
        .entry  start
        .stacks 0xE000, 0xF000

start:  LI      r0, HEAP1
        SWA     r0, HP
        SWA     r0, FROM
        LI      r0, HEAP1+SEMI
        SWA     r0, HEND
        LI      r0, HEAP2
        SWA     r0, TO
        CALL    nextc                   ; LOOK = first input character
        CALL    parse_term              ; r0 = the program
        PUSH    r0
        CALL    skipws
        LI      r1, EOF
        BEQ     r0, r1, st_ok
        JMP     syntax_error            ; something left over, such as ')'
st_ok:  POP     r1
        LI      r2, 0
        CALL    cons
        SWA     r0, C_REG               ; C = [program]; S, E, D start as nil

; ---------------------------------------------------------------------------
; The machine: one transition per pass
; ---------------------------------------------------------------------------
run:    LWA     r0, HP                  ; room for this transition?
        LWA     r1, HEND
        SUB     r1, r0
        LI      r2, RESERVE
        BGEU    r1, r2, run_ok
        CALL    gc
        LWA     r0, HP
        LWA     r1, HEND
        SUB     r1, r0
        LI      r2, RESERVE
        BGEU    r1, r2, run_ok
        LI      r0, msg_oom
        JMP     fail
run_ok: LWA     r6, C_REG
        BNZ     r6, step
        JMP     ctl_empty
step:   LWA     r0, STEPS
        ADDI    r0, 1
        SWA     r0, STEPS
        LW      r7, [r6+2]              ; x = head of C
        LW      r8, [r6+4]
        SWA     r8, C_REG               ; C = tail of C
        LI      r9, at_cell
        BNE     r7, r9, not_at
        JMP     rule_call
not_at: LW      r9, [r7]                ; dispatch on the type of x
        MOV     r11, r9
        LI      r10, 0xFF
        AND     r11, r10
        LI      r10, T_CLO
        BGEU    r11, r10, bad_expr
        SHL     r11
        LI      r10, exp_table
        ADD     r10, r11
        LW      r10, [r10]
        JR      r10

exp_table:
        .word   bad_expr, rule_var, rule_abs, rule_app, rule_const, rule_const
        .word   rule_if, rule_sel

bad_expr:
        LI      r0, msg_internal
        JMP     fail

; Var: (S, E, x:C, D) -> (E(x):S, E, C, D)
rule_var:
        ADDI    r9, T_ENV-T_VAR         ; the tag of a binding for this name
        LWA     r10, E_REG
rv_loop:
        BNZ     r10, rv_cmp
        JMP     unbound
rv_cmp: LW      r11, [r10]
        BEQ     r11, r9, rv_found
        LW      r10, [r10+4]
        JMP     rv_loop
rv_found:
        LW      r1, [r10+2]
push_r1:                                ; S = r1 : S, next transition
        LWA     r2, S_REG
        CALL    cons
        SWA     r0, S_REG
        JMP     run

; A constant (number or operator) is its own value.
rule_const:
        MOV     r1, r7
        JMP     push_r1

; Abs: (S, E, \x.B:C, D) -> (<\x.B, E>:S, E, C, D)
rule_abs:
        LI      r0, T_CLO
        MOV     r1, r7
        LWA     r2, E_REG
        CALL    alloc
        MOV     r1, r0
        JMP     push_r1

; App: (S, E, (M N):C, D) -> (S, E, N:M:@:C, D)
rule_app:
        LI      r1, at_cell
        LWA     r2, C_REG
        CALL    cons
        MOV     r2, r0
        LW      r1, [r7+2]              ; M
        CALL    cons
        MOV     r2, r0
        LW      r1, [r7+4]              ; N
        CALL    cons
        SWA     r0, C_REG
        JMP     run

; If: (S, E, (if c t e):C, D) -> (S, E, c:SEL(t,e):C, D)
rule_if:
        LW      r1, [r7+4]              ; the SEL cell
        LWA     r2, C_REG
        CALL    cons
        MOV     r2, r0
        LW      r1, [r7+2]              ; c
        CALL    cons
        SWA     r0, C_REG
        JMP     run

; Sel: (v:S, E, SEL(t,e):C, D) -> (S, E, t:C, D) if v is true, else (S, E, e:C, D)
rule_sel:
        LWA     r6, S_REG
        BNZ     r6, sel_ok
        JMP     stack_err
sel_ok: LW      r0, [r6+2]              ; v
        LW      r6, [r6+4]
        SWA     r6, S_REG
        CALL    truth
        LW      r1, [r7+2]              ; t
        BNZ     r0, sel_go
        LW      r1, [r7+4]              ; e
sel_go: LWA     r2, C_REG
        CALL    cons
        SWA     r0, C_REG
        JMP     run

; truth: r0 = 1 if the value r0 is true, 0 if it is false. A number is true
; unless it is 0. A closure must be a Church boolean, \x y.x or \x y.y (with
; any names). Changes r1-r4.
truth:  LW      r1, [r0]
        LI      r2, T_INT
        BNE     r1, r2, tr_clo
        LW      r0, [r0+2]
        BZ      r0, tr_ret
        LI      r0, 1
tr_ret: RET
tr_clo: LI      r2, T_CLO
        BNE     r1, r2, tr_bad
        LW      r1, [r0+2]              ; \x.
        LW      r2, [r1+2]              ; its body, which must be \y.
        LW      r3, [r2]
        MOV     r4, r3
        LI      r0, 0xFF
        AND     r4, r0
        LI      r0, T_LAM
        BNE     r4, r0, tr_bad
        LW      r4, [r2+2]              ; the body of \y.
        LW      r4, [r4]                ; its tag, matched against VAR y and VAR x
        ADDI    r3, T_VAR-T_LAM
        LI      r0, 0
        BEQ     r4, r3, tr_ret          ; \x y.y: false (checked first, for \x x.x)
        LW      r3, [r1]
        ADDI    r3, T_VAR-T_LAM
        LI      r0, 1
        BEQ     r4, r3, tr_ret          ; \x y.x: true
tr_bad: LI      r0, msg_if
        JMP     fail

stack_err_near:
        JMP     stack_err

; Call: (<\x.B, E'>:a:S, E, @:C, D) -> ([], E'[x->a], [B], (S, E, C):D)
; Prim: (op:a:S, E, @:C, D)          -> ((op a):S, E, C, D)
;       ((op a):b:S, E, @:C, D)      -> (a op b:S, E, C, D)
rule_call:
        LWA     r6, S_REG
        BZ      r6, stack_err_near
        LW      r7, [r6+2]              ; f
        LW      r6, [r6+4]
        BZ      r6, stack_err_near
        LW      r8, [r6+2]              ; a
        LW      r9, [r6+4]              ; S
        LW      r10, [r7]
        LI      r11, T_CLO
        BEQ     r10, r11, call_clo
        LI      r11, 0xFF               ; a PRIM tag holds the operator too
        AND     r10, r11
        LI      r11, T_PRIM
        BEQ     r10, r11, call_prim
        LI      r0, msg_apply
        JMP     fail
call_clo:
        LWA     r1, C_REG               ; D = S : E : C : D
        LWA     r2, D_REG
        CALL    cons
        MOV     r2, r0
        LWA     r1, E_REG
        CALL    cons
        MOV     r2, r0
        MOV     r1, r9
        CALL    cons
        SWA     r0, D_REG
        LW      r10, [r7+2]             ; the LAM cell of the closure
        LW      r0, [r10]               ; E = [x -> a] : E'
        ADDI    r0, T_ENV-T_LAM
        MOV     r1, r8
        LW      r2, [r7+4]
        CALL    alloc
        SWA     r0, E_REG
        LW      r1, [r10+2]             ; C = [B]
        LI      r2, 0
        CALL    cons
        SWA     r0, C_REG
        LI      r0, 0                   ; S = []
        SWA     r0, S_REG
        JMP     run
call_prim:
        LW      r10, [r8]
        LI      r11, T_INT
        BEQ     r10, r11, cp_int
        LI      r0, msg_operand
        JMP     fail
cp_int: LW      r2, [r8+2]              ; the argument's value
        LW      r0, [r7]                ; the operator's tag
        LW      r1, [r7+2]
        BNZ     r1, cp_two
        LI      r1, 1                   ; the first argument: (op a) waits for
        CALL    alloc                   ; the second
        MOV     r1, r0
        JMP     cp_push
cp_two: LW      r1, [r7+4]              ; r1 op r2
        LI      r3, 256
        DIVU    r0, r3                  ; r0 = the operator character
        LI      r3, '+'
        BNE     r0, r3, cp_sub
        ADD     r1, r2
        JMP     cp_num
cp_sub: LI      r3, '-'
        BNE     r0, r3, cp_mul
        SUB     r1, r2
        JMP     cp_num
cp_mul: LI      r3, '*'
        BNE     r0, r3, cp_div
        MUL     r1, r2
        JMP     cp_num
cp_div: LI      r3, '/'
        BNE     r0, r3, cp_mod
        CALL    sdiv
        JMP     cp_num
cp_mod: LI      r3, '%'
        BNE     r0, r3, cp_eq
        CALL    sdiv
        MOV     r1, r15
        JMP     cp_num
cp_eq:  LI      r3, '='
        BNE     r0, r3, cp_lt
        BEQ     r1, r2, cp_true
        JMP     cp_false
cp_lt:  BLT     r1, r2, cp_true         ; the only operator left is <
cp_false:
        LI      r1, false_clo
        JMP     cp_push
cp_true:
        LI      r1, true_clo
        JMP     cp_push
cp_num: LI      r0, T_INT               ; S = the number r1 : S
        LI      r2, 0
        CALL    alloc
        MOV     r1, r0
cp_push:                                ; S = r1 : S, without f and a
        MOV     r2, r9
        CALL    cons
        SWA     r0, S_REG
        JMP     run

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

; Return: (v:S, E, [], (S', E', C'):D) -> (v:S', E', C', D)
ctl_empty:
        LWA     r6, D_REG
        BZ      r6, finish
        LWA     r0, STEPS
        ADDI    r0, 1
        SWA     r0, STEPS
        LWA     r7, S_REG
        BZ      r7, stack_err
        LW      r1, [r7+2]              ; v
        LW      r2, [r6+2]              ; S'
        LW      r6, [r6+4]
        LW      r8, [r6+2]              ; E'
        LW      r6, [r6+4]
        LW      r9, [r6+2]              ; C'
        LW      r6, [r6+4]              ; D
        SWA     r8, E_REG
        SWA     r9, C_REG
        SWA     r6, D_REG
        CALL    cons
        SWA     r0, S_REG
        JMP     run

; Halt: C and D are empty, the result is on top of S.
finish: LWA     r6, S_REG
        BZ      r6, stack_err
        LW      r0, [r6+2]
        CALL    print_value
        LI      r0, msg_stats1          ; "\n["
        CALL    print_str
        LWA     r0, STEPS
        CALL    print_u16
        LI      r0, msg_stats2          ; " transitions, "
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
stack_err:
        LI      r0, msg_internal
fail:   PUSH    r0                      ; print "error: <message>" and stop
        LI      r0, msg_error
        CALL    print_str
        POP     r0
        CALL    print_str
        LI      r0, '\n'
        SYS     0
        LI      r0, 1
        HALT

unbound:
        LI      r0, msg_error
        CALL    print_str
        LI      r0, msg_unbound
        CALL    print_str
        MOV     r0, r9                  ; the name is the high byte of the tag
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
; cons: r0 = new CONS cell with head r1 and tail r2.
; alloc: r0 = new cell with tag r0 and fields r1, r2.  Both change r3-r5 only.
cons:   LI      r0, T_CONS
alloc:  LWA     r3, HP
        MOV     r4, r3
        ADDI    r4, CELL
        LWA     r5, HEND
        BLTU    r5, r4, alloc_full
        SWA     r4, HP
        SW      r0, [r3+0]
        SW      r1, [r3+2]
        SW      r2, [r3+4]
        MOV     r0, r3
        RET
alloc_full:                             ; only possible while reading the term
        LI      r0, msg_oom
        JMP     fail

; gc: copy everything reachable from S, E, C, D into the other semispace.
gc:     LWA     r0, GCS
        ADDI    r0, 1
        SWA     r0, GCS
        LWA     r6, TO                  ; r6 = scan pointer
        SWA     r6, HP
        LWA     r0, S_REG
        CALL    forward
        SWA     r0, S_REG
        LWA     r0, E_REG
        CALL    forward
        SWA     r0, E_REG
        LWA     r0, C_REG
        CALL    forward
        SWA     r0, C_REG
        LWA     r0, D_REG
        CALL    forward
        SWA     r0, D_REG
gc_scan:                                ; forward the fields of each copied cell
        LWA     r7, HP
        BEQ     r6, r7, gc_flip
        LW      r8, [r6]
        LI      r9, 0xFF
        AND     r8, r9
        LI      r9, T_LAM
        BEQ     r8, r9, gc_a            ; LAM: only A is a pointer
        LI      r9, T_APP
        BEQ     r8, r9, gc_ab
        LI      r9, T_IF
        BLTU    r8, r9, gc_next         ; VAR, INT, PRIM: no pointers
gc_ab:  LW      r0, [r6+4]              ; APP, IF, SEL, CLO, ENV, CONS: A and B
        CALL    forward
        SW      r0, [r6+4]
gc_a:   LW      r0, [r6+2]
        CALL    forward
        SW      r0, [r6+2]
gc_next:
        ADDI    r6, CELL
        JMP     gc_scan
gc_flip:                                ; the copy becomes the current space
        LWA     r0, FROM
        LWA     r1, TO
        SWA     r1, FROM
        SWA     r0, TO
        LI      r2, SEMI
        ADD     r2, r1
        SWA     r2, HEND
        RET

; forward: r0 = the new address of the cell r0, copying it if needed.
; Pointers outside from-space (nil, at_cell) are returned unchanged.
; Changes r1-r5 only.
forward:
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
        LWA     r5, HP
        SW      r3, [r5+0]
        LW      r1, [r0+2]
        SW      r1, [r5+2]
        LW      r1, [r0+4]
        SW      r1, [r5+4]
        SW      r4, [r0+0]              ; leave a forwarding address behind
        SW      r5, [r0+2]
        MOV     r0, r5
        ADDI    r5, CELL
        SWA     r5, HP
        RET

; ---------------------------------------------------------------------------
; Reader: builds the term from standard input
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

; parse_atom: r0 = a variable, number, operator, (term), lambda or if
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

pa_var: LI      r1, 256                 ; tag = name << 8 | T_VAR
        MUL     r0, r1
        ADDI    r0, T_VAR
        PUSH    r0
        CALL    nextc
        POP     r0
        LI      r1, 'i'*256+T_VAR       ; "if"?
        BNE     r0, r1, pv_make
        LWA     r1, LOOK
        LI      r2, 'f'
        BNE     r1, r2, pv_make
        JMP     pa_if
pv_make:
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
        LI      r1, 256                 ; tag = op << 8 | T_PRIM, no arguments yet
        MUL     r0, r1
        ADDI    r0, T_PRIM
        LI      r1, 0
        LI      r2, 0
        JMP     alloc

; is_op: r1 = r0 if r0 is an operator character, else 0. Changes r2.
is_op:  LI      r2, op_chars
io_loop:
        LB      r1, [r2]
        BZ      r1, io_ret
        BEQ     r1, r0, io_ret
        ADDI    r2, 1
        JMP     io_loop
io_ret: RET

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
; print_value: print the machine value r0: a number, an operator, an operator
; with its first argument such as (+ 3), or a closure <\x.B>
print_value:
        LW      r1, [r0]
        LI      r2, T_CLO
        BEQ     r1, r2, pv_clo
        JMP     print_expr              ; INT and PRIM print as expressions
pv_clo: PUSH    r0
        LI      r0, '<'
        SYS     0
        POP     r0
        LW      r0, [r0+2]
        CALL    print_expr
        LI      r0, '>'
        SYS     0
        RET

; print_expr: print the expression r0
print_expr:
        LW      r1, [r0]
        MOV     r2, r1
        LI      r3, 0xFF
        AND     r2, r3                  ; r2 = type
        LI      r3, 256
        DIVU    r1, r3                  ; r1 = name
        LI      r3, T_VAR
        BNE     r2, r3, pe_int
        MOV     r0, r1
        SYS     0
        RET
pe_int: LI      r3, T_INT
        BNE     r2, r3, pe_prim
        LW      r0, [r0+2]
        JMP     print_s16
pe_prim:
        LI      r3, T_PRIM
        BNE     r2, r3, pe_lam
        LW      r3, [r0+2]
        BNZ     r3, pe_part
        MOV     r0, r1
        SYS     0
        RET
pe_part:                                ; (op a)
        PUSH    r0
        LI      r0, '('
        SYS     0
        MOV     r0, r1
        SYS     0
        LI      r0, ' '
        SYS     0
        POP     r0
        LW      r0, [r0+4]
        CALL    print_s16
        LI      r0, ')'
        SYS     0
        RET
pe_lam: LI      r3, T_LAM
        BNE     r2, r3, pe_if
        PUSH    r0
        LI      r0, '\\'
        SYS     0
        MOV     r0, r1
        SYS     0
        LI      r0, '.'
        SYS     0
        POP     r0
        LW      r0, [r0+2]
        JMP     print_expr
pe_if:  LI      r3, T_IF
        BNE     r2, r3, pe_app
        PUSH    r0
        LI      r0, msg_ifkw            ; "if "
        CALL    print_str
        POP     r0
        PUSH    r0
        LW      r0, [r0+2]              ; the condition
        LI      r4, 1
        CALL    print_sub
        LI      r0, ' '
        SYS     0
        POP     r0
        LW      r0, [r0+4]              ; the SEL cell
        PUSH    r0
        LW      r0, [r0+2]
        LI      r4, 1
        CALL    print_sub
        LI      r0, ' '
        SYS     0
        POP     r0
        LW      r0, [r0+4]
        LI      r4, 1
        JMP     print_sub
pe_app: PUSH    r0
        LW      r0, [r0+2]              ; the function: brackets if a lambda
        LI      r4, 0
        CALL    print_sub
        LI      r0, ' '
        SYS     0
        POP     r0
        LW      r0, [r0+4]              ; the argument: brackets if a lambda or application
        LI      r4, 1
; print_sub: print r0, in brackets if it is a lambda or an if, or if r4 = 1
; and it is an application
print_sub:
        LW      r1, [r0]
        LI      r2, 0xFF
        AND     r1, r2
        LI      r2, T_LAM
        BEQ     r1, r2, sub_br
        LI      r2, T_IF
        BEQ     r1, r2, sub_br
        BZ      r4, sub_plain
        LI      r2, T_APP
        BEQ     r1, r2, sub_br
sub_plain:
        JMP     print_expr
sub_br: PUSH    r0
        LI      r0, '('
        SYS     0
        POP     r0
        CALL    print_expr
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
; print_u16: print r0 as an unsigned decimal number (from fact8.asm)
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

; print_str: print the zero-terminated string at r0 (from fact8.asm)
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
at_cell:  .word T_AT, 0, 0              ; the control marker @
true_clo: .word T_CLO, true_lam, 0      ; <\x y.x>, the value of 1 = 1
false_clo: .word T_CLO, false_lam, 0    ; <\x y.y>
true_lam: .word 'x'*256+T_LAM, true_y, 0
true_y:   .word 'y'*256+T_LAM, var_x, 0
false_lam: .word 'x'*256+T_LAM, false_y, 0
false_y:  .word 'y'*256+T_LAM, var_y, 0
var_x:    .word 'x'*256+T_VAR, 0, 0
var_y:    .word 'y'*256+T_VAR, 0, 0
op_chars: .ascii "+-*/%=<"
          .byte 0
S_REG:    .word 0                       ; the four SECD registers
E_REG:    .word 0
C_REG:    .word 0
D_REG:    .word 0
HP:       .word 0                       ; next free byte in the current semispace
HEND:     .word 0                       ; end of the current semispace
FROM:     .word 0                       ; start of the current semispace
TO:       .word 0                       ; start of the other one
LOOK:     .word 0                       ; reader: the next input character
STEPS:    .word 0                       ; transitions (modulo 65536)
GCS:      .word 0                       ; garbage collections

msg_error:    .ascii "error: "
              .byte 0
msg_unbound:  .ascii "unbound variable "
              .byte 0
msg_apply:    .ascii "a number cannot be applied"
              .byte 0
msg_operand:  .ascii "an operator needs a number"
              .byte 0
msg_divzero:  .ascii "division by zero"
              .byte 0
msg_if:       .ascii "if needs a boolean or a number"
              .byte 0
msg_ifkw:     .ascii "if "
              .byte 0
msg_oom:      .ascii "out of memory"
              .byte 0
msg_internal: .ascii "internal error: bad machine state"
              .byte 0
msg_syntax:   .ascii "syntax error at "
              .byte 0
msg_eof:      .ascii "end of input"
              .byte 0
msg_stats1:   .ascii "\n["
              .byte 0
msg_stats2:   .ascii " transitions, "
              .byte 0
msg_stats3:   .ascii " collections]\n"
              .byte 0
