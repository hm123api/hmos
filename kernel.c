/* HMOS Limine-protocol x86_64 kernel (shared BIOS + UEFI Limine chainload).
 * Higher-half, freestanding C. Draws 8x16 text directly to the framebuffer.
 *
 * Step 2: PS/2 keyboard polling, line buffer, cursor echo and a command
 * placeholder. ASCII only; CJK rendering is a later step.
 */
#include <stdint.h>
#include <stddef.h>
#include "limine.h"
#include "font.h"

/* ---- Limine requests (must live in .limine_requests, kept by linker) ---- */

__attribute__((used, section(".limine_requests")))
static volatile uint64_t limine_base_revision[] = LIMINE_BASE_REVISION(6);

__attribute__((used, section(".limine_requests")))
static volatile struct limine_framebuffer_request framebuffer_request = {
    .id = LIMINE_FRAMEBUFFER_REQUEST_ID,
    .revision = 0
};

__attribute__((used, section(".limine_requests")))
static volatile struct limine_firmware_type_request firmware_type_request = {
    .id = LIMINE_FIRMWARE_TYPE_REQUEST_ID,
    .revision = 0
};

__attribute__((used, section(".limine_requests")))
static volatile struct limine_tsc_frequency_request tsc_frequency_request = {
    .id = LIMINE_TSC_FREQUENCY_REQUEST_ID,
    .revision = 0
};

__attribute__((used, section(".limine_requests_start")))
static volatile uint64_t limine_requests_start_marker[] = LIMINE_REQUESTS_START_MARKER;

__attribute__((used, section(".limine_requests_end")))
static volatile uint64_t limine_requests_end_marker[] = LIMINE_REQUESTS_END_MARKER;

/* ---- screen geometry ---- */

#define CELL_W   FONT_W
#define CELL_H   FONT_H
#define CELL_XSP 1
#define CELL_YSP 1
#define STRIDE_X (CELL_W + CELL_XSP)
#define STRIDE_Y (CELL_H + CELL_YSP)

#define MAX_LINE 128

/* ---- PS/2 keyboard scan codes ---- */

#define KBD_DATA   0x60
#define KBD_STATUS 0x64

#define SCAN_ESC       0x01
#define SCAN_BACKSPACE 0x0e
#define SCAN_TAB       0x0f
#define SCAN_ENTER     0x1c
#define SCAN_LSHIFT    0x2a
#define SCAN_RSHIFT    0x36
#define SCAN_CAPS      0x3a
#define SCAN_LEFT      0x4b
#define SCAN_RIGHT     0x4d
#define SCAN_DEL       0x53

/* ---- kernel state ---- */

static struct limine_framebuffer *g_fb = 0;
static size_t g_cols;
static size_t g_rows;

static char   g_line[MAX_LINE];
static size_t g_len;      /* bytes currently in the line */
static size_t g_cursor;   /* insertion index, 0..g_len  */

static size_t g_cur_row;  /* row where the input prompt lives */
static int    g_shift;
static int    g_caps;

static uint64_t g_tsc_freq = 0;   /* TSC ticks per second, 0 if unavailable */

static inline uint64_t rdtsc(void) {
    uint32_t lo, hi;
    __asm__ volatile ("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
}

/* ---- helpers ---- */

static void hcf(void) { for (;;) { __asm__ volatile ("hlt"); } }

static size_t xstrlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }

static inline uint8_t inb(uint16_t port) {
    uint8_t v;
    __asm__ volatile ("inb %1, %0" : "=a"(v) : "Nd"(port));
    return v;
}

static inline void io_wait(void) {
    /* Short delay to let the 8042 catch up between port accesses. */
    __asm__ volatile ("outb %%al, $0x80" : : "a"(0));
}

/* ---- glyph / text drawing ---- */

static void put_glyph(struct limine_framebuffer *fb, const uint8_t *glyph,
                      size_t x, size_t y, uint32_t fg) {
    volatile uint32_t *base = fb->address;
    for (size_t row = 0; row < FONT_H; row++) {
        uint8_t bits = glyph[row];
        for (size_t col = 0; col < FONT_W; col++) {
            if (bits & (0x80 >> col)) {
                size_t px = x + col;
                size_t py = y + row;
                if (px < fb->width && py < fb->height) {
                    base[py * (fb->pitch / 4) + px] = fg;
                }
            }
        }
    }
}

static void draw_char_at(struct limine_framebuffer *fb, char c, size_t col, size_t row, uint32_t fg) {
    unsigned char idx = (unsigned char)c;
    put_glyph(fb, font8x16[idx], col * STRIDE_X, row * STRIDE_Y, fg);
}

/* Render one logical line (no null terminator required) at a screen row. */
static void draw_line_at(const char *buf, size_t len, size_t row, uint32_t fg) {
    for (size_t i = 0; i < len; i++) {
        draw_char_at(g_fb, buf[i], i, row, fg);
    }
}

static void fb_clear(struct limine_framebuffer *fb, uint32_t color) {
    volatile uint32_t *base = fb->address;
    size_t count = (fb->pitch / 4) * fb->height;
    for (size_t i = 0; i < count; i++) base[i] = color;
}

/* Erase a single character cell (full 8x16 block) to the background. */
static void erase_cell(size_t col, size_t row) {
    volatile uint32_t *base = g_fb->address;
    size_t px0 = col * STRIDE_X;
    size_t py0 = row * STRIDE_Y;
    for (size_t ry = 0; ry < CELL_H; ry++) {
        size_t py = py0 + ry;
        if (py >= g_fb->height) continue;
        for (size_t dx = 0; dx < CELL_W; dx++) {
            size_t px = px0 + dx;
            if (px < g_fb->width) base[py * (g_fb->pitch / 4) + px] = 0;
        }
    }
}

/* Erase every glyph on one screen row, then redraw the line content. */
static void redraw_input_row(void) {
    for (size_t col = 0; col < g_cols; col++) erase_cell(col, g_cur_row);
    /* prompt "> " then the buffered text */
    draw_char_at(g_fb, '>', 0, g_cur_row, 0x00CCCCCCu);
    draw_char_at(g_fb, ' ', 1, g_cur_row, 0x00CCCCCCu);
    draw_line_at(g_line, g_len, g_cur_row, 0x00FFFFFFu);
}

/* Cursor as an inverted block over the insertion cell: XOR white onto each
 * pixel. Toggling is reversible (XOR twice restores the glyph), so the cursor
 * never paints over or obscures a character. */
static void toggle_cursor(void) {
    if (!g_fb) return;
    size_t col = g_cursor + 2;  /* after "> " */
    size_t px0 = col * STRIDE_X;
    size_t py0 = g_cur_row * STRIDE_Y;
    volatile uint32_t *base = g_fb->address;
    for (size_t row = 0; row < CELL_H; row++) {
        size_t py = py0 + row;
        if (py >= g_fb->height) continue;
        for (size_t dx = 0; dx < CELL_W; dx++) {
            size_t px = px0 + dx;
            if (px >= g_fb->width) continue;
            volatile uint32_t *p = &base[py * (g_fb->pitch / 4) + px];
            *p = *p ^ 0x00FFFFFFu;
        }
    }
}

/* Redraw the input row and restore the cursor at the current position. */
static void refresh_input(int cursor_on) {
    redraw_input_row();
    if (cursor_on) toggle_cursor();
}

/* Move all rows up by one, clear the bottom row. Simple single-screen paging. */
static void scroll_up(void) {
    volatile uint32_t *base = g_fb->address;
    size_t line_bytes = STRIDE_Y;
    size_t dst_pitch = g_fb->pitch / 4;
    for (size_t row = 1; row < g_rows; row++) {
        for (size_t y = 0; y < STRIDE_Y; y++) {
            size_t src = (row * STRIDE_Y + y) * dst_pitch;
            size_t dst = ((row - 1) * STRIDE_Y + y) * dst_pitch;
            for (size_t x = 0; x < g_fb->width; x++) base[dst + x] = base[src + x];
        }
    }
    /* clear bottom row */
    for (size_t y = 0; y < line_bytes && (g_rows - 1) * STRIDE_Y + y < g_fb->height; y++) {
        size_t py = (g_rows - 1) * STRIDE_Y + y;
        for (size_t x = 0; x < g_fb->width; x++) base[py * dst_pitch + x] = 0;
    }
}

/* Write a message on a fresh new line; scroll if the prompt row hits the bottom. */
static void print_line(const char *msg, uint32_t fg) {
    if (g_cur_row + 1 >= g_rows) {
        scroll_up();
        g_cur_row = g_rows - 1;
    } else {
        g_cur_row++;
    }
    size_t len = xstrlen(msg);
    if (len > g_cols) len = g_cols;
    draw_line_at(msg, len, g_cur_row, fg);
}

/* ---- keyboard ---- */

/* Standard XT set-1 scancode to ASCII, shift-aware. Returns 0 for non-printable. */
static char scan_to_ascii(uint8_t code, int shift) {
    /* plain / shifted pairs */
    static const char lower[] = {
        0,  0, '1','2','3','4','5','6','7','8','9','0','-','=', 0, 0,
        'q','w','e','r','t','y','u','i','o','p','[',']','\\', 0,
        'a','s','d','f','g','h','j','k','l',';','\'','`',
        0, 'z','x','c','v','b','n','m',',','.','/'
    };
    static const char upper[] = {
        0,  0, '!','@','#','$','%','^','&','*','(',')','_','+', 0, 0,
        'Q','W','E','R','T','Y','U','I','O','P','{','}','|', 0,
        'A','S','D','F','G','H','J','K','L',':','"','~',
        0, 'Z','X','C','V','B','N','M','<','>','?'
    };
    if (code >= sizeof(lower)) return 0;
    return shift ? upper[code] : lower[code];
}

static int kbd_has_data(void) {
    return (inb(KBD_STATUS) & 0x01) != 0;
}

/* Drain any leftover bytes the firmware/bootloader left in the 8042 output
 * buffer, so stale scan codes are not mistaken for fresh input. */
static void kbd_flush(void) {
    while (kbd_has_data()) {
        (void)inb(KBD_DATA);
        io_wait();
    }
}

/* Place a printable char into the line buffer at the cursor index. */
static void line_insert(char c) {
    if (g_len >= MAX_LINE - 1) return;
    /* shift the tail right */
    for (size_t i = g_len; i > g_cursor; i--) g_line[i] = g_line[i - 1];
    g_line[g_cursor] = c;
    g_len++;
    g_cursor++;
}

static void line_backspace(void) {
    if (g_cursor == 0) return;
    g_cursor--;
    for (size_t i = g_cursor; i < g_len - 1; i++) g_line[i] = g_line[i + 1];
    g_len--;
    g_line[g_len] = 0;
}

static void line_del_at_cursor(void) {
    if (g_cursor >= g_len) return;
    for (size_t i = g_cursor; i < g_len - 1; i++) g_line[i] = g_line[i + 1];
    g_len--;
    g_line[g_len] = 0;
}

/* Command placeholder: echo the submitted line. Real dispatch hooks go here. */
static void run_command(void) {
    g_line[g_len] = 0;
    /* echo "> <cmd>" on its own line, then a reply line */
    char echo[MAX_LINE + 8];
    size_t p = 0;
    echo[p++] = '>'; echo[p++] = ' ';
    for (size_t i = 0; i < g_len && p < sizeof(echo) - 2; i++) echo[p++] = g_line[i];
    echo[p] = 0;
    print_line(echo, 0x00AAAAAAu);

    if (g_len == 0) {
        print_line("(empty)", 0x00888888u);
    } else {
        print_line("HMOS: command received.", 0x00FFFFFFu);
    }

    /* reset buffer for the next entry */
    g_len = 0;
    g_cursor = 0;
    g_line[0] = 0;
}

/* Drain one scancode from the data port and update the line. */
static void kbd_poll(int cursor_on) {
    while (kbd_has_data()) {
        uint8_t code = inb(KBD_DATA);
        io_wait();

        if (code & 0x80) {
            /* key release: 0x80 | make-code. Track shift release. */
            uint8_t make = code & 0x7f;
            if (make == SCAN_LSHIFT || make == SCAN_RSHIFT) g_shift = 0;
            continue;
        }

        switch (code) {
            case SCAN_LSHIFT:
            case SCAN_RSHIFT:
                g_shift = 1;
                break;
            case SCAN_CAPS:
                g_caps = !g_caps;
                break;
            case SCAN_ENTER:
                if (cursor_on) toggle_cursor();
                run_command();
                refresh_input(1);
                break;
            case SCAN_BACKSPACE:
                line_backspace();
                refresh_input(cursor_on);
                break;
            case SCAN_LEFT:
                if (g_cursor > 0) { g_cursor--; refresh_input(cursor_on); }
                break;
            case SCAN_RIGHT:
                if (g_cursor < g_len) { g_cursor++; refresh_input(cursor_on); }
                break;
            case SCAN_DEL:
                line_del_at_cursor();
                refresh_input(cursor_on);
                break;
            case SCAN_TAB:
            case SCAN_ESC:
                break;
            default: {
                int eff_shift = g_shift ^ g_caps;
                char c = scan_to_ascii(code, eff_shift);
                if (c) { line_insert(c); refresh_input(cursor_on); }
                break;
            }
        }
    }
}

/* ---- main ---- */

void kmain(void) {
    if (!LIMINE_BASE_REVISION_SUPPORTED(limine_base_revision)) hcf();
    if (framebuffer_request.response == NULL ||
        framebuffer_request.response->framebuffer_count < 1) hcf();

    struct limine_framebuffer *fb = framebuffer_request.response->framebuffers[0];
    if (fb->memory_model != LIMINE_FRAMEBUFFER_RGB || fb->bpp != 32) hcf();

    g_fb = fb;
    fb_clear(fb, 0x00000000u);

    g_cols = fb->width  / STRIDE_X;
    g_rows = fb->height / STRIDE_Y;
    if (g_cols < 8) g_cols = 8;
    if (g_rows < 4) g_rows = 4;

    g_len = 0; g_cursor = 0; g_line[0] = 0;
    g_shift = 0; g_caps = 0;
    g_cur_row = 1;

    if (tsc_frequency_request.response) {
        g_tsc_freq = tsc_frequency_request.response->frequency;
    }

    __asm__ volatile ("sti");
    kbd_flush();

    /* welcome banner on row 0, input prompt on row 1 */
    draw_line_at("HMOS shell (ASCII input). Type and press Enter.",
                 xstrlen("HMOS shell (ASCII input). Type and press Enter."),
                 0, 0x0088CCFFu);
    refresh_input(1);

    /* Blink every 500 ms using the TSC; fall back to a counter if the
     * frequency request was not provided by the bootloader. */
    const uint64_t BLINK_TICKS = g_tsc_freq ? g_tsc_freq / 2 : 0;
    uint64_t last_ts = g_tsc_freq ? rdtsc() : 0;
    uint64_t blink = 0;
    int cursor_on = 1;

    for (;;) {
        kbd_poll(cursor_on);

        if (g_tsc_freq) {
            uint64_t now = rdtsc();
            if (now - last_ts >= BLINK_TICKS) {
                last_ts = now;
                cursor_on = !cursor_on;
                toggle_cursor();
            }
        } else {
            blink++;
            if ((blink & 0x7f) == 0) {
                cursor_on = !cursor_on;
                refresh_input(cursor_on);
            }
        }
        /* Tight polling: do not hlt, so scan codes are picked up promptly. */
    }
}
