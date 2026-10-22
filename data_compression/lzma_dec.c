/* lzma_dec.c - minimal reference decoder for the .lzma ("LZMA-alone") format.
 * Clarity over speed. Build:  gcc -O2 -Wall -o lzma_dec lzma_dec.c
 * Usage: ./lzma_dec input.lzma output.bin      
 *
 *
 gcc -O2 -Wall -o lzma_dec lzma_dec.c
 xz --format=lzma -c somefile > somefile.lzma
 ./lzma_dec somefile.lzma roundtrip
 *
 * 
*/
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint16_t Prob;
#define TOP_VALUE (1u << 24)

static void die(const char *msg) { fprintf(stderr, "error: %s\n", msg); exit(1); }

static void init_probs(Prob *p, size_t n) { while (n--) *p++ = 1024; }

/* ---------------- range decoder (Chapter 4) ---------------- */
typedef struct { const uint8_t *in, *end; uint32_t range, code; } RC;

static uint8_t next_byte(RC *rc) {
    if (rc->in >= rc->end) die("truncated input");
    return *rc->in++;
}
static void rc_init(RC *rc, const uint8_t *in, const uint8_t *end) {
    rc->in = in; rc->end = end; rc->range = 0xFFFFFFFFu; rc->code = 0;
    if (next_byte(rc) != 0) die("first range-coder byte must be 0");
    for (int i = 0; i < 4; i++) rc->code = (rc->code << 8) | next_byte(rc);
}
static void normalize(RC *rc) {
    if (rc->range < TOP_VALUE) {
        rc->range <<= 8;
        rc->code = (rc->code << 8) | next_byte(rc);
    }
}
/* decode one bit with adaptive probability *p */
static int rc_bit(RC *rc, Prob *p) {
    uint32_t bound = (rc->range >> 11) * *p;
    int bit;
    if (rc->code < bound) { rc->range = bound;  *p += (2048 - *p) >> 5; bit = 0; }
    else { rc->range -= bound; rc->code -= bound; *p -= *p >> 5;        bit = 1; }
    normalize(rc);
    return bit;
}
/* n bits with fixed probability 1/2 */
static uint32_t rc_direct(RC *rc, int n) {
    uint32_t r = 0;
    while (n--) {
        rc->range >>= 1;
        uint32_t b = rc->code >= rc->range;
        if (b) rc->code -= rc->range;
        r = (r << 1) | b;
        normalize(rc);
    }
    return r;
}
/* bit tree, MSB first; probs has 2^nbits entries (index 0 unused) */
static uint32_t rc_tree(RC *rc, Prob *probs, int nbits) {
    uint32_t m = 1;
    for (int i = 0; i < nbits; i++) m = (m << 1) | rc_bit(rc, &probs[m]);
    return m - (1u << nbits);
}
/* reverse bit tree, LSB first */
static uint32_t rc_rtree(RC *rc, Prob *probs, int nbits) {
    uint32_t m = 1, sym = 0;
    for (int i = 0; i < nbits; i++) {
        uint32_t b = rc_bit(rc, &probs[m]);
        m = (m << 1) | b;
        sym |= b << i;
    }
    return sym;
}

/* ---------------- length coder (Chapter 7) ---------------- */
typedef struct { Prob choice, choice2, low[16][8], mid[16][8], high[256]; } LenDec;

static void len_init(LenDec *l) { init_probs((Prob *)l, sizeof *l / sizeof(Prob)); }
static uint32_t len_decode(RC *rc, LenDec *l, unsigned pos_state) {
    if (!rc_bit(rc, &l->choice))  return 2  + rc_tree(rc, l->low[pos_state], 3);
    if (!rc_bit(rc, &l->choice2)) return 10 + rc_tree(rc, l->mid[pos_state], 3);
    return 18 + rc_tree(rc, l->high, 8);
}

/* ---------------- output buffer (the whole output is the dictionary) ---------------- */
typedef struct { uint8_t *buf; size_t len, cap; } Out;
static void out_put(Out *o, uint8_t b) {
    if (o->len == o->cap) {
        o->cap = o->cap ? o->cap * 2 : 4096;
        o->buf = realloc(o->buf, o->cap);
        if (!o->buf) die("out of memory");
    }
    o->buf[o->len++] = b;
}

/* ---------------- main decoder ---------------- */
static Out lzma_alone_decode(const uint8_t *data, size_t size) {
    if (size < 13) die("file too short");
    unsigned d = data[0];
    if (d >= 9 * 5 * 5) die("bad properties byte");
    unsigned lc = d % 9; d /= 9;
    unsigned lp = d % 5; unsigned pb = d / 5;
    uint64_t usize = 0;
    for (int i = 0; i < 8; i++) usize |= (uint64_t)data[5 + i] << (8 * i);
    int unknown = (usize == UINT64_MAX);

    RC rc; rc_init(&rc, data + 13, data + size);

    size_t nlit = (size_t)0x300 << (lc + lp);
    Prob *literal = malloc(nlit * sizeof(Prob));
    if (!literal) die("out of memory");
    init_probs(literal, nlit);

    Prob is_match[12][16], is_rep[12], is_rep_g0[12], is_rep_g1[12], is_rep_g2[12];
    Prob is_rep0_long[12][16], pos_slot[4][64], pos_special[115], align[16];
    init_probs(&is_match[0][0], 12 * 16);  init_probs(is_rep, 12);
    init_probs(is_rep_g0, 12); init_probs(is_rep_g1, 12); init_probs(is_rep_g2, 12);
    init_probs(&is_rep0_long[0][0], 12 * 16);
    init_probs(&pos_slot[0][0], 4 * 64);   init_probs(pos_special, 115);
    init_probs(align, 16);
    LenDec len_dec, rep_len_dec; len_init(&len_dec); len_init(&rep_len_dec);

    Out out = {0};
    unsigned state = 0;
    uint32_t rep[4] = {0, 0, 0, 0};

    while (unknown || out.len < usize) {
        size_t pos = out.len;
        unsigned ps = pos & ((1u << pb) - 1);

        if (!rc_bit(&rc, &is_match[state][ps])) {                 /* ---- literal */
            unsigned prev = pos ? out.buf[pos - 1] : 0;
            Prob *probs = literal + 0x300 * (((pos & ((1u << lp) - 1)) << lc) + (prev >> (8 - lc)));
            unsigned sym = 1;
            if (state >= 7) {                                      /* matched literal */
                unsigned mb = out.buf[pos - rep[0] - 1];
                while (sym < 0x100) {
                    unsigned match_bit = (mb >> 7) & 1; mb <<= 1;
                    unsigned bit = rc_bit(&rc, &probs[((1 + match_bit) << 8) + sym]);
                    sym = (sym << 1) | bit;
                    if (match_bit != bit) break;
                }
            }
            while (sym < 0x100) sym = (sym << 1) | rc_bit(&rc, &probs[sym]);
            out_put(&out, (uint8_t)sym);
            state = state < 4 ? 0 : (state < 10 ? state - 3 : state - 6);
            continue;
        }

        uint32_t len;
        if (!rc_bit(&rc, &is_rep[state])) {                        /* ---- simple match */
            rep[3] = rep[2]; rep[2] = rep[1]; rep[1] = rep[0];
            len = len_decode(&rc, &len_dec, ps);
            state = state < 7 ? 7 : 10;
            uint32_t slot = rc_tree(&rc, pos_slot[len - 2 < 3 ? len - 2 : 3], 6);
            uint32_t dist;
            if (slot < 4) dist = slot;
            else {
                int nd = (slot >> 1) - 1;
                dist = (2 | (slot & 1)) << nd;
                if (slot < 14) dist += rc_rtree(&rc, pos_special + dist - slot, nd);
                else {
                    dist += rc_direct(&rc, nd - 4) << 4;
                    dist += rc_rtree(&rc, align, 4);
                }
            }
            if (dist == 0xFFFFFFFFu) break;                        /* end marker */
            rep[0] = dist;
        } else {                                                   /* ---- rep match */
            if (!rc_bit(&rc, &is_rep_g0[state])) {
                if (!rc_bit(&rc, &is_rep0_long[state][ps])) {      /* short rep */
                    state = state < 7 ? 9 : 11;
                    if (rep[0] >= pos) die("bad distance");
                    out_put(&out, out.buf[pos - rep[0] - 1]);
                    continue;
                }
            } else {
                uint32_t dist;
                if (!rc_bit(&rc, &is_rep_g1[state])) dist = rep[1];
                else {
                    if (!rc_bit(&rc, &is_rep_g2[state])) dist = rep[2];
                    else { dist = rep[3]; rep[3] = rep[2]; }
                    rep[2] = rep[1];
                }
                rep[1] = rep[0]; rep[0] = dist;
            }
            len = len_decode(&rc, &rep_len_dec, ps);
            state = state < 7 ? 8 : 11;
        }
        if (rep[0] >= pos) die("bad distance");
        if (!unknown && len > usize - out.len) die("match exceeds declared size");
        for (uint32_t i = 0; i < len; i++)                         /* byte-by-byte copy */
            out_put(&out, out.buf[out.len - rep[0] - 1]);
    }
    free(literal);
    return out;
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s in.lzma out\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) die("cannot open input");
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *data = malloc(n > 0 ? n : 1);
    if (!data || fread(data, 1, n, f) != (size_t)n) die("read failed");
    fclose(f);
    Out out = lzma_alone_decode(data, (size_t)n);
    FILE *g = fopen(argv[2], "wb");
    if (!g) die("cannot open output");
    if (out.len && fwrite(out.buf, 1, out.len, g) != out.len) die("write failed");
    fclose(g);
    free(out.buf); free(data);
    return 0;
}
