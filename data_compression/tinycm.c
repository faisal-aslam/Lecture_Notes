/* tinycm.c -- a small, readable context-mixing compressor (teaching code).
 * Usage:  tinycm c in out   |   tinycm d in out                         */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>
typedef uint8_t U8; typedef uint32_t U32; typedef uint64_t U64; typedef uint16_t U16;

/* ---------- logistic helpers: squash(x)=4096/(1+e^-x/256), stretch=inverse ---------- */
static int squash(int d) {
  static const int t[33] = {1,2,3,6,10,16,27,45,73,120,194,310,488,747,1101,
    1546,2047,2549,2994,3348,3607,3785,3901,3975,4022,4050,4068,4079,4085,
    4089,4092,4093,4094};
  if (d > 2047) return 4095;
  if (d < -2047) return 0;
  int w = d & 127; d = (d >> 7) + 16;
  return (t[d] * (128 - w) + t[d + 1] * w + 64) >> 7;
}
static short stretch_t[4096];
static void init_stretch(void) {
  int pi = 0;
  for (int x = -2047; x <= 2047; x++) {
    int v = squash(x);
    for (int i = pi; i <= v; i++) stretch_t[i] = x;
    pi = v + 1;
  }
  for (int i = pi; i < 4096; i++) stretch_t[i] = 2047;
}
#define stretch(p) stretch_t[p]

/* ---------- adaptive probability slot: 22-bit probability + 10-bit count ---------- */
static int dt[1024];
static inline int  slot_p(U32 s) { return s >> 20; }            /* 12-bit probability */
static inline void slot_update(U32 *s, int y, int limit) {
  int n = *s & 1023, p = *s >> 10;
  if (n < limit) ++*s; else *s = (*s & 0xfffffc00) | limit;
  int64_t delta = (int64_t)(((y << 22) - p) >> 3) * dt[n];
  *s += (U32)delta & 0xfffffc00;
}

/* ---------- APM / SSE stage: 33 interpolation nodes per context ---------- */
typedef struct { U16 *t; int idx; } APM;
static void apm_init(APM *a, int n) {
  a->t = malloc(n * 33 * sizeof(U16));
  for (int i = 0; i < n; i++)
    for (int j = 0; j < 33; j++) a->t[i * 33 + j] = squash((j - 16) * 128) * 16;
}
static int apm_pp(APM *a, int pr, int cx) {
  int s = (stretch(pr) + 2048) * 32, lo = s >> 12, wt = s & 4095;
  a->idx = cx * 33 + lo + (wt >> 11);
  return (a->t[cx * 33 + lo] * (4096 - wt) + a->t[cx * 33 + lo + 1] * wt) >> 16;
}
static void apm_update(APM *a, int y, int rate) {
  int g = (y << 16) + (y << rate) - y - y;
  a->t[a->idx] += (g - a->t[a->idx]) >> rate;
}

/* ---------- the predictor ---------- */
#define NCM 6                 /* hashed context models: o1 o2 o3 o4 o6 word  */
#define NIN (NCM + 3)         /* + order-0, match model, bias                */
#define TBITS 22
#define HBITS 22              /* match-model hash table size                 */
#define BUFSZ (1 << 26)
static U32 *T[NCM], o0[256], mm_sm[64 * 2];
static U32 ctx[NCM], idx[NCM], *o0p, *mmp;
static int st[NIN], wsel;
static int *W;                /* weight sets: 256 sets x NIN weights (16.16)  */
static APM a1, a2;
static int c0 = 1, bitpos = 0, pr = 2048, pr_mix = 2048;
static U64 c8 = 0;            /* last 8 bytes                                */
static U32 wordh = 0;
static U8 *buf; static U32 pos = 0, mptr = 0, mlen = 0, *mht;
static int mexp = -1;         /* expected bit from the match model, or -1    */

static void predictor_init(void) {
  init_stretch();
  for (int i = 0; i < 1024; i++) dt[i] = 16384 / (i + i + 3);
  for (int i = 0; i < NCM; i++) {
    T[i] = malloc((size_t)4 << TBITS);
    for (U32 j = 0; j < (1u << TBITS); j++) T[i][j] = 1u << 31;
  }
  for (int i = 0; i < 256; i++) o0[i] = 1u << 31;
  for (int i = 0; i < 128; i++) mm_sm[i] = 1u << 31;
  W = malloc(256 * NIN * sizeof(int));
  for (int i = 0; i < 256 * NIN; i++) W[i] = 1 << 14;      /* 0.25 */
  apm_init(&a1, 256); apm_init(&a2, 65536);
  buf = calloc(BUFSZ, 1); mht = calloc(1u << HBITS, 4);
}
static inline U32 hidx(U32 h, U32 c) {
  U32 x = (h + c * 0x9E3779B1u) * 0x85EBCA6Bu;
  x ^= x >> 15; x *= 0xC2B2AE35u;
  return x >> (32 - TBITS);
}
static int predict(void) {
  for (int i = 0; i < NCM; i++) {
    idx[i] = hidx(ctx[i], c0);
    st[i] = stretch(slot_p(T[i][idx[i]]));
  }
  o0p = &o0[c0]; st[NCM] = stretch(slot_p(*o0p));
  /* match model: only active if the bits seen so far agree with prediction */
  mexp = -1;
  if (mlen > 0 && ((buf[mptr] | 256) >> (8 - bitpos)) == c0) {
    mexp = (buf[mptr] >> (7 - bitpos)) & 1;
    int l = mlen > 31 ? 31 : mlen;
    mmp = &mm_sm[l * 2 + mexp];
    st[NCM + 1] = stretch(slot_p(*mmp));
  } else { mlen = 0; st[NCM + 1] = 0; }
  st[NCM + 2] = 256;                                         /* bias */
  wsel = c0 * NIN;
  int64_t dot = 0;
  for (int i = 0; i < NIN; i++) dot += (int64_t)st[i] * W[wsel + i];
  pr_mix = squash((int)(dot >> 16));
  int p1 = apm_pp(&a1, pr_mix, c0);
  int p2 = apm_pp(&a2, pr_mix, (c0 | (int)(c8 & 255) << 8) & 0xffff);
  pr = (2 * pr_mix + p1 + p2 + 2) >> 2;
  if (pr < 1) pr = 1;
  if (pr > 4095) pr = 4095;
  return pr;
}
static void update(int y) {
  for (int i = 0; i < NCM; i++) slot_update(&T[i][idx[i]], y, 255);
  slot_update(o0p, y, 255);
  if (mexp >= 0) slot_update(mmp, y, 1023);
  int err = ((y << 12) - pr_mix) * 6;                         /* mixer learning rate */
  for (int i = 0; i < NIN; i++) W[wsel + i] += (st[i] * err + 0x8000) >> 16;
  apm_update(&a1, y, 7); apm_update(&a2, y, 7);
  c0 = c0 * 2 + y; bitpos++;
  if (mexp >= 0 && mexp != y) mlen = 0;
  if (bitpos == 8) {                                          /* byte finished */
    int c = c0 & 255;
    buf[pos++ & (BUFSZ - 1)] = c;
    c8 = (c8 << 8) | c;
    wordh = isalpha(c) ? (wordh + tolower(c) + 1) * 0x2F0B4A27u : 0;
    static const U64 mask[5] = {0xff, 0xffff, 0xffffff, 0xffffffffULL, 0xffffffffffffULL};
    for (int i = 0; i < 5; i++) ctx[i] = (U32)(((c8 & mask[i]) * 0x9E3779B97F4A7C15ULL) >> 32) + i;
    ctx[5] = wordh * 0x3D4D51CBu + 99;
    /* match model: follow current match or look up the last 6 bytes */
    if (mlen > 0 && buf[mptr] == c) { mlen++; mptr++; } else mlen = 0;
    U32 h = (U32)(((c8 & 0xffffffffffffULL) * 0x9E3779B97F4A7C15ULL) >> (64 - HBITS));
    if (mlen == 0) {
      mptr = mht[h];
      if (mptr > 0) while (mlen < 255 && mlen < mptr &&
             buf[(mptr - mlen - 1) & (BUFSZ-1)] == buf[(pos - mlen - 1) & (BUFSZ-1)]) mlen++;
    }
    mht[h] = pos;
    c0 = 1; bitpos = 0;
  }
}

/* ---------- binary arithmetic coder (carry-less, 32-bit) ---------- */
static U32 x1 = 0, x2 = 0xffffffff, x = 0;
static FILE *fin, *fout;
static void encode(int y, int p) {
  U32 xmid = x1 + ((x2 - x1) >> 12) * p;
  y ? (x2 = xmid) : (x1 = xmid + 1);
  while (((x1 ^ x2) & 0xff000000) == 0) { putc(x2 >> 24, fout); x1 <<= 8; x2 = (x2 << 8) | 255; }
}
static int decode(int p) {
  U32 xmid = x1 + ((x2 - x1) >> 12) * p;
  int y = x <= xmid;
  y ? (x2 = xmid) : (x1 = xmid + 1);
  while (((x1 ^ x2) & 0xff000000) == 0) {
    x1 <<= 8; x2 = (x2 << 8) | 255; x = (x << 8) | (getc(fin) & 255);
  }
  return y;
}
int main(int argc, char **argv) {
  if (argc != 4) { fprintf(stderr, "usage: tinycm c|d in out\n"); return 1; }
  fin = fopen(argv[2], "rb"); fout = fopen(argv[3], "wb");
  if (!fin || !fout) { perror("open"); return 1; }
  predictor_init();
  if (argv[1][0] == 'c') {
    fseek(fin, 0, SEEK_END); U32 n = ftell(fin); fseek(fin, 0, SEEK_SET);
    fwrite(&n, 4, 1, fout);
    for (U32 i = 0; i < n; i++) {
      int c = getc(fin);
      for (int b = 7; b >= 0; b--) { int y = (c >> b) & 1; encode(y, predict()); update(y); }
    }
    for (int i = 0; i < 4; i++) { putc(x1 >> 24, fout); x1 <<= 8; }  /* flush */
  } else {
    U32 n; fread(&n, 4, 1, fin);
    for (int i = 0; i < 4; i++) x = (x << 8) | (getc(fin) & 255);
    for (U32 i = 0; i < n; i++) {
      int c = 0;
      for (int b = 0; b < 8; b++) { int y = decode(predict()); update(y); c = c * 2 + y; }
      putc(c, fout);
    }
  }
  fclose(fout); return 0;
}
