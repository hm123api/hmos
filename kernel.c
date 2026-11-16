/* HMOS Limine-protocol x86_64 kernel (shared BIOS + UEFI Limine chainload).
 * Higher-half, freestanding C. Draws 8x16 text directly to the framebuffer.
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

__attribute__((used, section(".limine_requests_start")))
static volatile uint64_t limine_requests_start_marker[] = LIMINE_REQUESTS_START_MARKER;

__attribute__((used, section(".limine_requests_end")))
static volatile uint64_t limine_requests_end_marker[] = LIMINE_REQUESTS_END_MARKER;

/* ---- helpers ---- */

static void hcf(void) { for (;;) { __asm__ volatile ("hlt"); } }

static size_t xstrlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }

static inline uint32_t fb_channel(uint8_t value, uint8_t size, uint8_t shift) {
    return (uint32_t)(value >> (8 - size)) << shift;
}

static uint32_t fb_pixel(struct limine_framebuffer *fb, uint8_t r, uint8_t g, uint8_t b) {
    return fb_channel(r, fb->red_mask_size,   fb->red_mask_shift)
         | fb_channel(g, fb->green_mask_size, fb->green_mask_shift)
         | fb_channel(b, fb->blue_mask_size,  fb->blue_mask_shift);
}

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

static void print_text(struct limine_framebuffer *fb, const char *str,
                       size_t x, size_t y, uint32_t fg) {
    size_t cx = x;
    while (*str) {
        unsigned char c = (unsigned char)*str++;
        if (c >= 128) c = ' ';
        put_glyph(fb, font8x16[c], cx, y, fg);
        cx += FONT_W + 1;
    }
}

static void fb_clear(struct limine_framebuffer *fb, uint32_t color) {
    volatile uint32_t *base = fb->address;
    size_t count = (fb->pitch / 4) * fb->height;
    for (size_t i = 0; i < count; i++) base[i] = color;
}

void kmain(void) {
    if (!LIMINE_BASE_REVISION_SUPPORTED(limine_base_revision)) hcf();
    if (framebuffer_request.response == NULL ||
        framebuffer_request.response->framebuffer_count < 1) hcf();

    uint64_t fw = firmware_type_request.response ? firmware_type_request.response->firmware_type : 0;
    const char *msg = (fw == LIMINE_FIRMWARE_TYPE_EFI32 || fw == LIMINE_FIRMWARE_TYPE_EFI64)
                      ? "HMOS - UEFI Boot OK!"
                      : "HMOS - BIOS Boot OK!";

    for (uint64_t i = 0; i < framebuffer_request.response->framebuffer_count; i++) {
        struct limine_framebuffer *fb = framebuffer_request.response->framebuffers[i];
        if (fb->memory_model != LIMINE_FRAMEBUFFER_RGB || fb->bpp != 32) continue;
        fb_clear(fb, 0x00000000u);
        size_t x = (fb->width  - (size_t)(xstrlen(msg) * (FONT_W + 1))) / 2;
        size_t y = fb->height / 2;
        print_text(fb, msg, x < 1 ? 1 : x, y, 0x00FFFFFFu);
    }

    hcf();
}
