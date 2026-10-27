; lib.asm - the parts of graph.asm that are not about graph reduction: errors,
; a heap of two-word cells with a copying garbage collector, character input,
; and printing. Another program with two-word cells could use it too.
;
; Include it after the program's own code, inside its .org:
;
;       .include "lib.asm"
;
; The program must define these before using the heap:
;   HEAP1, HEAP2   the start of the two semispaces
;   SEMI           bytes per semispace
;   RESERVE        bytes kept free after each collection: collect makes sure
;                  that much room is left, or stops with "out of memory"
;   STACK_TOP      the initial data stack pointer (the collector's roots end there)
;
; Registers: r10 is the heap pointer and r11 the end of the current semispace
; minus RESERVE, throughout the program. A routine that allocates may compare
; them directly: if r10 <= r11, RESERVE bytes are free. Other registers are
; changed only as each routine says.
;
; The collector (Cheney's) assumes:
;   - a heap object is a cell of two words, and its first word is never 0
;     (0 marks a cell that has already been copied);
;   - the data stack, from DSP up to STACK_TOP, holds every live pointer, so it
;     is the only root. A routine must not keep a heap pointer only in a
;     register across a call of collect;
;   - a word is a pointer exactly when it is even and inside from-space. Odd
;     words and words outside the heap are left alone.

        .equ    CELL, 4                 ; bytes per cell
        .equ    FWD, 0                  ; first word of a cell copied by the collector
        .equ    EOF, 0xFFFF             ; what SYS 1 returns at the end of input

; ---------------------------------------------------------------------------
; Errors
; ---------------------------------------------------------------------------
; fail: print "error: " and the zero-terminated message r0, and halt with 1.
fail:   PUSH    r0
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

; syntax_error: print "error: syntax error at 'c'", where c is LOOK (or "end
; of input"), and halt with 2.
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
; heap_init: start allocating at HEAP1. Changes r0.
heap_init:
        LI      r10, HEAP1
        LI      r11, HEAP1+SEMI-RESERVE
        SWA     r10, FROM
        LI      r0, HEAP2
        SWA     r0, TO
        RET

; collect: collect garbage, and stop with "out of memory" unless RESERVE
; bytes are then free. Changes r0-r7.
collect:
        CALL    gc
        BGEU    r11, r10, cl_ok
oom:    LI      r0, msg_oom
        JMP     fail
cl_ok:  RET

; cons: r0 = a new cell (r1, r2). It never collects, and stops with "out of
; memory" if the RESERVE is used up. Changes nothing else.
cons:   BLTU    r11, r10, oom
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
        LI      r2, SEMI-RESERVE
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
; Input: LOOK holds the next character, read ahead
; ---------------------------------------------------------------------------
; nextc: r0 = LOOK = the next input character, or EOF.
nextc:  SYS     1
        SWA     r0, LOOK
        RET

; skipws: skip blanks, control characters and # comments; r0 = LOOK.
; Changes r1.
skipws: LWA     r0, LOOK
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

; is_end: r1 = 1 if r0 ends a word (a blank, a control character or EOF),
; else 0.
is_end: LI      r1, 33
        BLTU    r0, r1, ie_yes
        LI      r1, EOF
        BEQ     r0, r1, ie_yes
        LI      r1, 0
        RET
ie_yes: LI      r1, 1
        RET

; is_digit: r1 = 1 if r0 is 0-9, else 0.
is_digit:
        LI      r1, '0'
        BLTU    r0, r1, id_no
        LI      r1, '9'+1
        BGEU    r0, r1, id_no
        LI      r1, 1
        RET
id_no:  LI      r1, 0
        RET

; read_u16: r6 = the decimal number starting at LOOK, modulo 65536, reading
; up to the first character that is not a digit; r0 = LOOK. Changes r1.
read_u16:
        LI      r6, 0
ru_loop:
        LWA     r0, LOOK
        CALL    is_digit
        BZ      r1, ru_done
        ADDI    r0, -48
        LI      r1, 10
        MUL     r6, r1
        ADD     r6, r0
        CALL    nextc
        JMP     ru_loop
ru_done:
        RET

; ---------------------------------------------------------------------------
; Printing
; ---------------------------------------------------------------------------
; print_s16: print r0 as a signed decimal number. Changes r0-r2.
print_s16:
        LI      r1, 0
        BGE     r0, r1, print_u16
        PUSH    r0
        LI      r0, '-'
        SYS     0
        POP     r0
        NEG     r0
; print_u16: print r0 as an unsigned decimal number. Changes r0-r2.
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
; Changes r0-r6.
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

; print_str: print the zero-terminated string at r0. Changes r0, r1.
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
FROM:   .word   0                       ; start of the current semispace
TO:     .word   0                       ; start of the other one
GCS:    .word   0                       ; garbage collections so far
LOOK:   .word   0                       ; the next input character
NUM:    .word   0, 0                    ; print_u32's argument

msg_error:  .ascii "error: "
            .byte 0
msg_oom:    .ascii "out of memory"
            .byte 0
msg_stack:  .ascii "out of stack"
            .byte 0
msg_syntax: .ascii "syntax error at "
            .byte 0
msg_eof:    .ascii "end of input"
            .byte 0
