/*! \file
 * Startup code for standalone programs usable in monitor
 * without RAM extensions. 
 * Requires TOPSYS to be defined * e.g. -DTOPSYS=040000
 *
 * \section Physical memory map
 * 000000-177777 regular ram/rom/regs
 * 200000-237777 kernel/bin loader space
 * 240000-267777 kernel screen backup
 *
 * \section external functions
 * findrom() mount fs and open rom image file
 * loadrom() load rom image into 0100000 
 * kenter()  handle ScrollLock key, load bin files
 *
 * This file is based on BKUNIX project. 
 */

/*
 * This file is part of BKUNIX project, which is distributed
 * under the terms of the GNU General Public License (GPL).
 * See the accompanying file "COPYING" for more details.
 */

    / MFPI move from previous space to -(sp)
    mfpi = 06500^tst

    .globl  _edata
    .globl  _findrom
    .globl  _loadrom
    .globl  _kenter
    /.globl  _printhex
    .globl  _emtCB
    .globl  _umap0              / map user 000000-037777 to 120000-157777
    .globl  _umap1              / map user 040000-077777 to 120000-157777

    KISA = 0177600
    UISA = 0177620

    / bit 0: 1 = shadow on
    / bit 1: 1 = mapping on
    / bit 2: 1 = user mode, 0 = kernel mode
    MMUCTL = 0177700

    .data
_spsave:    .word 0
_rollsave:  .word 0

    / startup icon
_ohai:
    .word 0037777,0060001,0102235,0161205,0100635
    .word 0161245,0102245,0162235,0100001,0177777
_boobad:
    .word 0037777,0060001,0100001,0160501,0100501
    .word 0160001,0101741,0162021,0100001,0177777
_bootok:
    .word 0037777,0060001,0100001,0160501,0100501
    .word 0160001,0102021,0161741,0100001,0177777


/-----------------------
/ System starts here.
/
    .text
init:
    / we start in kernel mode, MMU disabled
    mtps $0200

    / clear screen
    mov $040000, r0
1:  clr (r0)+
    tst r0
    bpl 1b

mmuinit:
    / init default ram map for K and U: linear, all writable in K (bit 15 set)
    mov $0100000, r0
    mov $0100000, r3
    mov $KISA, r1
    mov $UISA, r2
9:
    mov r0, (r1)+
    mov r3, (r2)+

    / make pages above 0100000 read-only in U
    add $0200, r3
    cmp $0101000, r3
    bne 8f
    bic $0100000, r3
8:
    add $0200, r0
    bit $02000, r0
    beq 9b

    / map kernel pages 0 and 200 to the second 64K
    mov r0, *$KISA
    add $0200, r0
    mov r0, *$KISA+2

    / enable mapping
    bis $2, *$MMUCTL  

    / copy self to virtual ram area at 01000 (physical 201000)
    mov $0100000, r0
    mov $01000, r1
    mov $4096, r3 / decimal
5:  mov (r0)+,(r1)+
    sob r3, 5b

    mov    $_edata,r0        / clear bss and stack
1:  clr    (r0)+
    cmp    r0,$ TOPSYS
    blo    1b

    mov    r0,sp            / set up kernel stack pointer

helo:                   / display boot icon
    mov $_ohai, r1
    jsr pc, dispico

themain:
    / call main and make it return into 01000-space
    jmp *$in1000
    / in 01000-address space since this moment
in1000:
    jsr pc, *$_findrom
    tst r0
    bne fatal

    jsr pc, _happyico

    jsr pc, *$_loadrom
    tst r0
    bne fatal

    / this will execute in 01000-space after return from main
    / disable shadow 
    bic $1, *$MMUCTL

    jsr pc, _vinst         / setup vectors

    / set usermode request bit
    bis $4, *$MMUCTL
    clr -(sp)
    mov $0100000, -(sp)
    / boot bios in user mode
    rti 

    / setup vectors
_vinst:
    / emt handler 
    mov $_emt, *$030
    mov $0200, *$032
     
    / keyboard handler for k-mode (060)
    mov $_kkirq, *$060
_vinst2:
    mov $0200, r0
    mov r0, *$062

    mov $_abort, *$04
    mov r0, *$06

    mov $_abort, *$010
    mov r0, *$012
    rts pc
  
_abort:
    mov *$_spsave, sp
    jmp _restore

fatal:
    mov $_boobad, r1
    jsr pc, dispico
    br .

_emt:
    add $0120000, r1
    mov r1, *$_emtCB                / r1 points to emt control block, save it there
    jsr pc, _kkommon

    / Check if loaded block overwrites user stack.
    / If it does, we simulate return from EMT by
    / using the new return address.
    mov r2, -(sp)
    mov 2(r1), r2                   / r2 = emtCB->start

    mfpi sp                         / push uSP
    sub $4, (sp)                    / offset by -4 to simulate EMT in user space

    cmp (sp), r2
    ble 0f                          / uSP < start, not affected
    add 4(r1),r2                    / r2 = start + length
    cmp (sp), r2                    / uSP < start + length ?
    ble 1f                          /   yes -> do tricks

0:                                  / no overlapping stack
    tst (sp)+                       / dump uSP
    mov (sp)+, r2                   / restore r2
    br 2f                           / return to normal return address
1:
    / return to where uSP points to in the user space
    / (sp)    user sp
    / (sp+2)  r2
    / (sp+4)  return address
    / (sp+6)  return PS
    mfpi (sp)+                      / mov user(sp)+, -(sp) - top of the stack has return address 
    mov 2(sp), r2                   / restore r1
    mov (sp), 4(sp)                 / shift the frame up
    add $4, sp
2:  sub $0120000, r1                / restore r1
    br  _iret

_kkirq:
    clr *$_emtCB                    / if emtCB is NULL, this is ScrollLock
    jsr pc, _kkommon

_iret:
    bis $4, *$MMUCTL                / kate, we have to go back!
    rti

_kkommon:
    mov r0,-(sp)
    mov r1,-(sp)
    mov r2,-(sp)
    mov r3,-(sp)
    mov r4,-(sp)
    mov r5,-(sp)
    mov sp, *$_spsave

    mov *$0177662, r0               / clear keyboard ready bit

    jsr pc, _scrprep                / backup screen contents

    / copy userspace interrupt vectors to kernelspace
    
    jsr pc, _umap0                  / map user 000000-037777 to 120000-157777
    
    mov $0120400, r0                / copy vectors that are now in 0120000-0120400...
    mov $0400, r1                   / ...to 0000-0400
3:
    mov -(r0),-(r1)
    tst r1
    bne 3b
    
    jsr pc, _vinst2                 / install abort handlers
    
    mtps $0                         / enable interrupts

    / print user SP
    / mfpi    sp                    / load uSP to -(sp)
    / jsr pc, _printhex
    / mov (sp)+, r0

    / ready to use bios in kernel mode

    jsr pc, _kenter

    clr *$0120300                   / clear 0300 = PROH (error flag)
    
    / test if loaded image used screen area
    / and don't restore display if it did
    tst r0
    bne _noclr

_restore:
    jsr pc, _pause                  / pause before restoring..
    jsr pc, _scrrest                / restore original display
_noclr:
    jsr pc, _vinst                  / reinstall the initial hook

    jsr pc, _umap0                  / map user 00-03 to kernel 12-15

    mov (sp)+,r5
    mov (sp)+,r4
    mov (sp)+,r3
    mov (sp)+,r2
    mov (sp)+,r1
    mov (sp)+,r0

    rts pc

_umap0:
    mov $0100000, *$KISA+10         / map userspace 0000000 to 0120000, RW
    mov $0100200, *$KISA+12         / map userspace 0020000 to 0140000, RW
    rts pc

_umap1:
    mov $0100400, *$KISA+10         / map userspace 0000000 to 0120000, RW
    mov $0100600, *$KISA+12         / map userspace 0020000 to 0140000, RW
    rts pc

_scrprep:
    mov *$0177664, *$_rollsave    / save scroll position

    mov $0102400, *$KISA+10      / map 0100000v, rw 0240000p to 
    mov $0102600, *$KISA+12      / map 0120000v, rw 0260000p to 

    mov  $040000, r1
    mov $0120000, r2
_scrcopy:
    mov $020000, r3
1:  mov (r1)+,(r2)+
    sob r3, 1b
    rts pc

_scrrest:
    mov *$_rollsave, *$0177664    / restore scroll position

    mov $0002400, *$KISA+10      / map 0240000p to 0120000v, ro
    mov $0002600, *$KISA+12      / map 0260000p to 0100000v, ro

    mov  $0120000, r1
    mov  $040000,  r2
    br  _scrcopy

_pause:
    mov $0177777, r0
1:  mov $040, r1
    sob r1, .
    sob r0, 1b
    rts pc

_happyico:
    mov $_bootok, r1
    jmp dispico

    / display a fattened up icon in the middle of screen
    / r1 - pointer to 10 words of icon data
dispico:
    mov $060140, r0
    mov $10, r2
1:
    mov (r1)+,r3
    clr r4

    mov $15, r5
2:
    ror r3
    ror r4
    clc
    bpl 4f
    sec
4:
    ror r4
    bit $7, r5
    bne 3f
    mov r4, 0100(r0)
    mov r4, (r0)+
3:
    dec r5
    bpl 2b

    add $0174, r0
    sob r2, 1b
    rts pc

