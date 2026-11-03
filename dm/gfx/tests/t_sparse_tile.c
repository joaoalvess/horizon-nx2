#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../nvn/nvn_tex.h"
#include "../tex/nvn_deswizzle.h"

static int g_n, g_fail;

static void check(const char *name, int format, uint32_t w, uint32_t h, uint32_t levels, uint32_t layers) {
    nvn_texdesc d = {.target = layers > 1 ? 4 : 1, .format = format, .flags = 0x20, .width = w, .height = h, .depth = layers, .levels = levels};
    nvn_texlayout L; nvn_tex_layout(&d, &L);
    uint32_t tw, th, td; int ntl = nvn_tex_sparse_tiles(&d, &tw, &th, &td);
    int bw, bh, bpb = nvn_fmt_bpb(format, &bw, &bh);
    uint32_t rows = th / (uint32_t)bh, sh = 0; while ((8u << sh) < rows) sh++;
    nvn_texdesc t = {.target = 1, .format = format, .width = tw, .height = th, .depth = 1, .levels = 1, .pkg_block_h = (int)sh + 1};
    nvn_texlayout TL; nvn_tex_layout(&t, &TL);
    size_t tpitch = (size_t)tw / (size_t)bw * (size_t)bpb;
    uint8_t *mem = malloc(L.size), *tile = malloc(tpitch * rows);
    srand(format * 7919u + w); for (uint64_t i = 0; i < L.size; i++) mem[i] = (uint8_t)(rand() >> 5);
    int bad = TL.size != 0x10000 || ntl < 1, tiles = 0;
    for (uint32_t s = 0; s < layers; s++) for (int l = 0; l < ntl; l++) {
        uint32_t lw = w >> l ? w >> l : 1, lh = h >> l ? h >> l : 1;
        size_t pitch = (size_t)((lw + bw - 1) / bw) * bpb, lrows = (lh + bh - 1) / bh;
        uint8_t *lin = malloc(pitch * lrows);
        if (nvn_deswizzle(&d, (unsigned)l, s, mem, lin, pitch)) bad++;
        uint64_t lo = (uint64_t)s * L.layer_size + nvn_tex_level_offset(&d, (unsigned)l);
        uint32_t tx = nvn_tex_level_gobs(&d, (unsigned)l) / (uint32_t)(tpitch / 64), ty = (lh + th - 1) / th;
        if (nvn_tex_level_offset(&d, (unsigned)l + 1) - nvn_tex_level_offset(&d, (unsigned)l) != (uint64_t)tx * ty * 0x10000 || tx != (lw + tw - 1) / tw) bad++;
        for (uint32_t y = 0; y < ty; y++) for (uint32_t x = 0; x < tx; x++) {
            if (nvn_deswizzle(&t, 0, 0, mem + lo + ((uint64_t)y * tx + x) * 0x10000, tile, tpitch)) bad++;
            size_t nb = pitch - x * tpitch < tpitch ? pitch - x * tpitch : tpitch, nr = lrows - y * rows < rows ? lrows - y * rows : rows;
            for (size_t r = 0; r < nr; r++) bad += memcmp(tile + r * tpitch, lin + (y * rows + r) * pitch + x * tpitch, nb) != 0;
            tiles++;
        }
        free(lin);
    }
    g_n++; g_fail += bad != 0;
    printf("%-34s %ux%u x%u, %d tiled levels of %ux%u-texel tiles, GOB order %d: %d tiles, one-tile layout %#llx bytes %s\n", name, w, h, layers, ntl, tw, th, nvn_gob_switch2, tiles,
           (unsigned long long)TL.size, bad ? "FAIL" : "PASS");
    free(mem); free(tile);
}

int main(void) {
    for (int g = 0; g < 2; g++) {
        nvn_gob_switch2 = g;
        check("R8 (1-byte blocks)", 0x01, 1024, 768, 3, 1);
        check("R16 (2-byte blocks)", 0x06, 1100, 520, 3, 1);
        check("RGBA8 (4-byte blocks)", 0x25, 1000, 600, 4, 2);
        check("RGBA16F (8-byte blocks)", 0x29, 512, 512, 3, 1);
        check("RGBA32F (16-byte blocks)", 0x2E, 300, 260, 2, 1);
        check("DXT1 (8-byte 4x4 blocks)", 0x42, 2048, 1000, 3, 1);
        check("ASTC 8x8 (16-byte 8x8 blocks)", 0x80, 4096, 2000, 4, 2);
    }
    printf("== %d checks, %d failed ==\n", g_n, g_fail);
    return g_fail != 0;
}
