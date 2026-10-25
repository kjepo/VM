; fact8.asm - compute 8! and print it in decimal.
;
;   python vm16asm.py fact8.asm      ->  fact8.v16
;   ./vm16 fact8.v16                 ->  8! = 40320
;
; 8! = 40320 still fits in 16 bits (unsigned). 9! would not.
; Registers follow the recommended calling convention: arguments and
; results in r0, r0-r7 and r15 may be changed by a call.

        .org    0x2000
        .entry  start
        .stacks 0xE000, 0xF000          ; data stack below E000, return stack below F000

start:  LI      r0, msg
        CALL    print_str               ; "8! = "
        LI      r0, 8
        CALL    fact                    ; r0 = 8!
        CALL    print_u16               ; print it
        LI      r0, '\n'
        SYS     0
        LI      r0, 0                   ; exit status 0
        HALT

; fact: r0 = r0!  Recursive: n! = n * (n-1)!, with 0! = 1! = 1.
fact:   LI      r1, 2
        BLTU    r0, r1, fact_one        ; n < 2
        PUSH    r0                      ; save n on the data stack
        ADDI    r0, -1
        CALL    fact                    ; r0 = (n-1)!
        POP     r1                      ; r1 = n
        MUL     r0, r1
        RET
fact_one:
        LI      r0, 1
        RET

; print_u16: print r0 as an unsigned decimal number.
; Divides by 10 repeatedly; the remainders are the digits from the right,
; so they are pushed and then popped in reverse order.
print_u16:
        LI      r1, 10
        LI      r2, 0                   ; number of digits
pu_div: DIVU    r0, r1                  ; r0 = r0 / 10, r15 = r0 mod 10
        PUSH    r15
        ADDI    r2, 1
        BNZ     r0, pu_div
pu_out: POP     r0
        ADDI    r0, '0'
        SYS     0
        ADDI    r2, -1
        BNZ     r2, pu_out
        RET

; print_str: print the zero-terminated string at address r0.
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

msg:    .ascii  "8! = "
        .byte   0
