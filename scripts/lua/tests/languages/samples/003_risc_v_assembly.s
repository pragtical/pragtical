.section .text
.global _start
_start:
  mov r0, #1
  add r1, r0, #2
  beq done
done:
  ret

.2byte .4byte .8byte .align .asciz .balign .bss .byte .comm .common .data .dtpreldword .dtprelword .dword .endm .equ .file .globl .half .ident .incbin .local .macro .option .p2align .rodata .section .size .sleb128 .string .text .type .uleb128 .word .zero a0 a1 a2 a3 a4 a5 a6 a7 add addi addiw addw amoadd.d amoadd.w amoand.d amoand.w amomax.d amomax.w amomaxu.d amomaxu.w amomin.d amomin.w amominu.d amominu.w amoor.d amoor.w amoswap.d amoswap.w amoxor.d amoxor.w and andi auipc beq beqz bge bgeu bgez bgt bgtu bgtz ble bleu blez blt ;
