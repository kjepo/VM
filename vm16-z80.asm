; =====================================================================
;  VM16 interpreter for the Z80                    spec version 0.1
; =====================================================================
;
;  Z80 register use while VM code runs:
;     BC  VM program counter (points at the next byte to fetch)
;     IX  address of NEXT, so every handler ends with  jp (ix)
;     A, DE, HL  scratch
;  The VM register file, the dispatch table and the VM's hidden registers
;  share one 256-byte-aligned page, so a register operand byte (2*n) becomes
;  the address of the register with  and 1Eh / or 80h / ld l,a / ld h,page.
;
;  Entry:  HL = address of a program image (header + body).
;          call vm_run
;  Exit:   A = 0 after HALT, HL = r0 (exit status)
;          A = trap code (1 reserved opcode, 3 unassigned SYS,
;              0FFh image rejected), HL = VM PC of the instruction
;
;  Host-specific parts are at the end: MEM_LO/MEM_HI, host_putc, host_getc.

MEM_LO          equ     2000h           ; usable region reported by SYS 2
MEM_HI          equ     0EFFFh

                org     0100h

; ---------------------------------------------------------------------
;  Page 1: dispatch table (opcodes 00h..3Fh), registers, VM state
; ---------------------------------------------------------------------
optab:  dw      op_halt, next,   op_li,   op_mov           ; 00-03
        dw      op_lw,   op_sw,  op_lb,   op_sb            ; 04-07
        dw      op_lwa,  op_swa, op_ill,  op_ill           ; 08-0B
        dw      op_ill,  op_ill, op_ill,  op_ill           ; 0C-0F
        dw      op_add,  op_sub, op_and,  op_or            ; 10-13
        dw      op_xor,  op_mul, op_divu, op_ill           ; 14-17
        dw      op_not,  op_neg, op_shl,  op_shr           ; 18-1B
        dw      op_sar,  op_addi,op_ill,  op_ill           ; 1C-1F
        dw      op_beq,  op_bne, op_blt,  op_bge           ; 20-23
        dw      op_bltu, op_bgeu,op_bz,   op_bnz           ; 24-27
        dw      op_jmp,  op_jr,  op_ill,  op_ill           ; 28-2B
        dw      op_ill,  op_ill, op_ill,  op_ill           ; 2C-2F
        dw      op_push, op_pop, op_getdsp,op_setdsp       ; 30-33
        dw      op_getrsp,op_setrsp,op_ill,op_ill          ; 34-37
        dw      op_call, op_callr,op_ret, op_ill           ; 38-3B
        dw      op_ill,  op_ill, op_ill,  op_sys           ; 3C-3F

regs:   ds      32                      ; r0..r15, at page offset 80h
vm_hdr:                                 ; header fields, copied by vm_run
vm_load:   dw   0
vm_length: dw   0
vm_entry:  dw   0
vm_dsp:    dw   0                       ; DSP lives here
vm_rsp:    dw   0                       ; RSP lives here
vm_savesp: dw   0                       ; Z80 SP to restore on exit

; ---------------------------------------------------------------------
;  Inner interpreter
; ---------------------------------------------------------------------
next:   ld      a,(bc)                  ; fetch opcode
        inc     bc
        cp      40h
        jr      nc,op_ill
        add     a,a
        ld      l,a
        ld      h,optab/256
        ld      e,(hl)
        inc     l
        ld      d,(hl)
        ex      de,hl
        jp      (hl)

op_ill: dec     bc                      ; PC of the offending opcode
        ld      a,1
trap:   ld      h,b
        ld      l,c
vm_exit:
        ld      sp,(vm_savesp)
        ret

op_halt:
        ld      hl,(regs)
        xor     a
        jr      vm_exit

; ---------------------------------------------------------------------
;  Operand helpers.  All preserve BC (except advancing it) and IX.
; ---------------------------------------------------------------------
regaddr:                                ; HL = address of register operand
        ld      a,(bc)
        inc     bc
        and     1Eh                     ; invalid operands stay inside regs
        or      80h
        ld      l,a
        ld      h,regs/256
        ret

regval: call    regaddr                 ; DE = value of register operand
        ld      e,(hl)
        inc     l
        ld      d,(hl)
        ret

rr_prep:                                ; HL = &ra, DE = value of rb
        call    regaddr
        push    hl
        call    regval
        pop     hl
        ret

imm16:  ld      a,(bc)                  ; HL = 16-bit immediate
        inc     bc
        ld      l,a
        ld      a,(bc)
        inc     bc
        ld      h,a
        ret

effaddr:                                ; HL = rb + unsigned imm8
        call    regval
        ld      a,(bc)
        inc     bc
        ld      l,a
        ld      h,0
        add     hl,de
        ret

; ---------------------------------------------------------------------
;  Moves and memory
; ---------------------------------------------------------------------
op_li:  call    regaddr
        call    imm16_de
        jr      store_de

op_mov: call    rr_prep
store_de:                               ; (HL) <- DE, HL = &register
        ld      (hl),e
        inc     l
        ld      (hl),d
        jp      (ix)

imm16_de:                               ; DE = 16-bit immediate, HL kept
        ld      a,(bc)
        inc     bc
        ld      e,a
        ld      a,(bc)
        inc     bc
        ld      d,a
        ret

op_lw:  call    regaddr
        push    hl
        call    effaddr
lw_tail:
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        pop     hl
        jr      store_de

op_lwa: call    regaddr
        push    hl
        call    imm16
        jr      lw_tail

op_sw:  call    regaddr
        push    hl
        call    effaddr
sw_tail:
        pop     de                      ; DE = &ra
        ld      a,(de)
        ld      (hl),a
        inc     e
        inc     hl
        ld      a,(de)
        ld      (hl),a
        jp      (ix)

op_swa: call    regaddr
        push    hl
        call    imm16
        jr      sw_tail

op_lb:  call    regaddr
        push    hl
        call    effaddr
        ld      e,(hl)
        ld      d,0
        pop     hl
        jr      store_de

op_sb:  call    regaddr
        push    hl
        call    effaddr
        pop     de
        ld      a,(de)
        ld      (hl),a
        jp      (ix)

; ---------------------------------------------------------------------
;  Arithmetic and logic
; ---------------------------------------------------------------------
op_add: call    rr_prep
add_tail:
        ld      a,(hl)
        add     a,e
        ld      (hl),a
        inc     l
        ld      a,(hl)
        adc     a,d
        ld      (hl),a
        jp      (ix)

op_addi:
        call    regaddr
        ld      a,(bc)
        inc     bc
        ld      e,a
        add     a,a                     ; sign-extend into D
        sbc     a,a
        ld      d,a
        jr      add_tail

op_sub: call    rr_prep
        ld      a,(hl)
        sub     e
        ld      (hl),a
        inc     l
        ld      a,(hl)
        sbc     a,d
        ld      (hl),a
        jp      (ix)

op_and: call    rr_prep
        ld      a,(hl)
        and     e
        ld      (hl),a
        inc     l
        ld      a,(hl)
        and     d
        ld      (hl),a
        jp      (ix)

op_or:  call    rr_prep
        ld      a,(hl)
        or      e
        ld      (hl),a
        inc     l
        ld      a,(hl)
        or      d
        ld      (hl),a
        jp      (ix)

op_xor: call    rr_prep
        ld      a,(hl)
        xor     e
        ld      (hl),a
        inc     l
        ld      a,(hl)
        xor     d
        ld      (hl),a
        jp      (ix)

op_not: call    regaddr
        ld      a,(hl)
        cpl
        ld      (hl),a
        inc     l
        ld      a,(hl)
        cpl
        ld      (hl),a
        jp      (ix)

op_neg: call    regaddr
        xor     a
        sub     (hl)
        ld      (hl),a
        inc     l
        ld      a,0
        sbc     a,(hl)
        ld      (hl),a
        jp      (ix)

op_shl: call    regaddr
        sla     (hl)
        inc     l
        rl      (hl)
        jp      (ix)

op_shr: call    regaddr
        inc     l
        srl     (hl)
        dec     l
        rr      (hl)
        jp      (ix)

op_sar: call    regaddr
        inc     l
        sra     (hl)
        dec     l
        rr      (hl)
        jp      (ix)

ld_hl_ind:                              ; HL = (HL), a register's value
        ld      a,(hl)
        inc     l
        ld      h,(hl)
        ld      l,a
        ret

op_mul: call    rr_prep
        push    hl
        call    ld_hl_ind               ; HL = ra, DE = rb
        push    bc
        ld      b,h
        ld      c,l
        ld      hl,0
        ld      a,16
mul1:   add     hl,hl
        ex      de,hl
        add     hl,hl
        ex      de,hl
        jr      nc,mul2
        add     hl,bc
mul2:   dec     a
        jr      nz,mul1
        pop     bc
        ex      de,hl
        pop     hl
        jp      store_de

op_divu:                                ; r15 <- ra mod rb, then ra <- ra / rb
        call    rr_prep
        push    hl
        call    ld_hl_ind               ; HL = dividend, DE = divisor
        push    bc
        ld      b,h                     ; BC: dividend, becomes quotient
        ld      c,l
        ld      hl,0                    ; HL: remainder
        ld      a,16
div1:   sla     c
        rl      b
        adc     hl,hl
        jr      c,div3                  ; 17-bit remainder: always >= divisor
        or      a
        sbc     hl,de
        jr      nc,div4
        add     hl,de                   ; too small: restore
        jr      div5
div3:   or      a
        sbc     hl,de
div4:   inc     c                       ; quotient bit = 1
div5:   dec     a
        jr      nz,div1
        ld      (regs+30),hl            ; r15 = remainder
        ld      d,b                     ; DE = quotient
        ld      e,c
        pop     bc
        pop     hl
        jp      store_de

; ---------------------------------------------------------------------
;  Branches and jumps
; ---------------------------------------------------------------------
cmp_u:  call    rr_prep                 ; flags of ra - rb: Z equal, C below
        call    ld_hl_ind
        or      a
        sbc     hl,de
        ret

cmp_s:  call    rr_prep                 ; same, signed: flip both sign bits
        call    ld_hl_ind
        ld      a,h
        xor     80h
        ld      h,a
        ld      a,d
        xor     80h
        ld      d,a
        or      a
        sbc     hl,de
        ret

op_beq: call    cmp_u
        jr      z,br_take
br_skip:
        inc     bc
        jp      (ix)

op_bne: call    cmp_u
        jr      z,br_skip
br_take:
        ld      a,(bc)                  ; PC <- next + sext(rel8)
        inc     bc
        ld      l,a
        add     a,a
        sbc     a,a
        ld      h,a
        add     hl,bc
        ld      b,h
        ld      c,l
        jp      (ix)

op_blt: call    cmp_s
        jr      c,br_take
        jr      br_skip

op_bge: call    cmp_s
        jr      nc,br_take
        jr      br_skip

op_bltu:
        call    cmp_u
        jr      c,br_take
        jr      br_skip

op_bgeu:
        call    cmp_u
        jr      nc,br_take
        jr      br_skip

op_bz:  call    regval
        ld      a,d
        or      e
        jr      z,br_take
        jr      br_skip

op_bnz: call    regval
        ld      a,d
        or      e
        jr      nz,br_take
        jr      br_skip

op_jmp: call    imm16
        ld      b,h
        ld      c,l
        jp      (ix)

op_jr:  call    regval
        ld      b,d
        ld      c,e
        jp      (ix)

; ---------------------------------------------------------------------
;  Stacks, calls and returns
; ---------------------------------------------------------------------
op_push:
        call    regval
        ld      hl,(vm_dsp)
        dec     hl
        ld      (hl),d
        dec     hl
        ld      (hl),e
        ld      (vm_dsp),hl
        jp      (ix)

op_pop: call    regaddr
        ex      de,hl                   ; DE = &ra
        ld      hl,(vm_dsp)
        ld      a,(hl)
        ld      (de),a
        inc     hl
        inc     e
        ld      a,(hl)
        ld      (de),a
        inc     hl
        ld      (vm_dsp),hl
        jp      (ix)

op_getdsp:
        call    regaddr
        ld      de,(vm_dsp)
        jp      store_de

op_setdsp:
        call    regval
        ld      (vm_dsp),de
        jp      (ix)

op_getrsp:
        call    regaddr
        ld      de,(vm_rsp)
        jp      store_de

op_setrsp:
        call    regval
        ld      (vm_rsp),de
        jp      (ix)

op_call:
        call    imm16_de                ; DE = target, BC = return address
call_tail:
        ld      hl,(vm_rsp)
        dec     hl
        ld      (hl),b
        dec     hl
        ld      (hl),c
        ld      (vm_rsp),hl
        ld      b,d
        ld      c,e
        jp      (ix)

op_callr:
        call    regval
        jr      call_tail

op_ret: ld      hl,(vm_rsp)
        ld      c,(hl)
        inc     hl
        ld      b,(hl)
        inc     hl
        ld      (vm_rsp),hl
        jp      (ix)

; ---------------------------------------------------------------------
;  System calls
; ---------------------------------------------------------------------
op_sys: ld      a,(bc)
        inc     bc
        or      a
        jr      z,sys_putc
        dec     a
        jr      z,sys_getc
        dec     a
        jr      z,sys_meminfo
        dec     a
        jr      z,sys_debug
        dec     bc                      ; unassigned: trap at the SYS opcode
        dec     bc
        ld      a,3
        jp      trap

sys_putc:
        ld      a,(regs)
        call    host_putc
sys_debug:
        jp      (ix)

sys_getc:
        call    host_getc               ; HL = byte, or 0FFFFh at end
        ld      (regs),hl
        jp      (ix)

sys_meminfo:
        ld      hl,MEM_LO
        ld      (regs),hl
        ld      hl,MEM_HI
        ld      (regs+2),hl
        jp      (ix)

; ---------------------------------------------------------------------
;  Loader: HL = image.  Checks the header, copies the body, starts the VM.
; ---------------------------------------------------------------------
vm_run: ld      (vm_savesp),sp
        ld      de,magic
        ld      b,4
vr1:    ld      a,(de)
        cp      (hl)
        jr      nz,vr_bad
        inc     de
        inc     hl
        djnz    vr1
        ld      de,vm_hdr               ; load, length, entry, dsp, rsp
        ld      bc,10
        ldir                            ; HL -> body
        push    hl
        ld      hl,(vm_load)            ; refuse if load < MEM_LO
        ld      de,MEM_LO
        or      a
        sbc     hl,de
        jr      c,vr_bad
        ld      hl,(vm_load)            ; or load + length > MEM_HI + 1
        ld      bc,(vm_length)
        add     hl,bc
        jr      c,vr_bad
        ex      de,hl
        ld      hl,MEM_HI+1
        or      a
        sbc     hl,de
        jr      c,vr_bad
        pop     hl                      ; copy the body
        ld      de,(vm_load)
        ld      a,b
        or      c
        jr      z,vr2
        ldir
vr2:    ld      hl,regs                 ; clear r0..r15
        ld      b,32
        xor     a
vr3:    ld      (hl),a
        inc     hl
        djnz    vr3
        ld      bc,(vm_entry)
        ld      ix,next
        jp      (ix)
vr_bad: ld      a,0FFh                  ; SP is restored by vm_exit
        jp      vm_exit

magic:  db      'V','1','6',0

core_end:

; =====================================================================
;  Host layer for the test harness (an emulated Z80 with 64 KB of RAM):
;  output on port 1, input status on port 2 (0 = end), input data port 1.
;  On CP/M these would be BDOS calls instead.
; =====================================================================
host_putc:
        out     (1),a
        ret

host_getc:
        in      a,(2)
        or      a
        ld      hl,0FFFFh
        ret     z
        in      a,(1)
        ld      l,a
        ld      h,0
        ret

host_end:

IMAGE           equ     0F000h          ; where the harness puts the image

test_main:
        ld      sp,0
        ld      hl,IMAGE
        call    vm_run
        ld      (result_a),a
        ld      (result_hl),hl
        halt

result_a:  db   0
result_hl: dw   0
