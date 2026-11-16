; HMOS BIOS MBR Bootloader - 修复光标闪烁、不显示文字
bits 16
org 0x7c00

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    sti

    ; 设置80x25文本模式，清屏
    mov ah, 0x00
    mov al, 0x03
    int 0x10

    ; 设置光标到 行0，列0
    mov ah, 0x02
    mov bh, 0
    mov dh, 0   ; 行
    mov dl, 0   ; 列
    int 0x10

    mov si, msg_hmos
    call print_str

hang:
    jmp hang

print_str:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0e
    mov bh, 0
    mov bl, 0x07
    int 0x10
    jmp print_str
.done:
    ret

msg_hmos db 'HMOS - BIOS Boot OK!', 0

; MBR 签名
times 510 - ($ - $$) db 0
dw 0xaa55
