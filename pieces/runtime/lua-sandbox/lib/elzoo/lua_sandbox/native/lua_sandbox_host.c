/* SPDX-License-Identifier: Apache-2.0 */
/*
** Owned C host of the Elzoo Lua sandbox (policy version 3: the safe helper set and
** module-call bindings).
**
** One process runs one request: it reads one frame (u32 little-endian
** length, then UTF-8 JSON) from stdin, builds one Lua state with a fresh
** environment, runs the source and writes exactly one reply frame to stdout.
** Stderr is /dev/null. No source, input, Lua message or path leaves the
** process except as the plain result value of a successful run.
**
** Private-layout coupling (maintenance limitation): the string guard in
** `host_alloc` reads `offsetof(TString, contents)` and the allocation tag of
** strings (`LUA_TSTRING`) from the pinned checkout's internal `lobject.h`.
** The build verifies the exact upstream bytes before it compiles this file.
**
** Build identity arrives as -D macros: ELZ_LUA_RELEASE, ELZ_LUA_REVISION,
** ELZ_HOST_SHA256, ELZ_BUILD_OPTIONS, ELZ_SEED and ELZ_POLICY_IDENTITY (each a
** string literal). A request whose policy differs from ELZ_POLICY_IDENTITY is
** answered with `policy_mismatch` before a Lua state exists.
*/
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lobject.h" /* TString layout: private, see the note above */

#if !defined(ELZ_LUA_RELEASE) || !defined(ELZ_LUA_REVISION) || \
    !defined(ELZ_HOST_SHA256) || !defined(ELZ_BUILD_OPTIONS) || !defined(ELZ_SEED) || \
    !defined(ELZ_POLICY_IDENTITY)
#error "build identity macros are required"
#endif

#define FRAME_MAX 1048576u
#define MAX_SOURCE 65536u
#define MAX_CONTAINERS 32
/* The frame nests the deepest plain value (a recorded argument or result) at depth 5:
** root 1, calls 2, recorded 3, record 4. A container at depth d holds its children at
** d + 1, so 32 nested containers from depth 5 occupy depths 5..36. */
#define PARSE_DEPTH_MAX (4 + MAX_CONTAINERS)
#define MAX_STEPS 1000000
#define MAX_DEPTH 64
#define MAX_VALUE 65536
#define MAX_MEMORY 16777216
#define MAX_WALL 1000

enum stop { STOP_NONE = 0, STOP_STEPS, STOP_DEPTH, STOP_VALUE, STOP_MEMORY, STOP_UNLISTED, STOP_MISMATCH, STOP_PENDING };

static struct {
  int sticky;
  size_t live, mem_limit;
  size_t value_bytes;
  int armed;
  size_t alloc_cap;
  long long steps, steps_limit;
  long long depth, depth_limit;
  unsigned poll_counter;
} G;

static char null_sentinel;

static void set_sticky(int reason) {
  if (G.sticky == STOP_NONE) G.sticky = reason;
}

static int stop_raise(lua_State *L) {
  lua_pushliteral(L, "stop");
  return lua_error(L);
}

/* ------------------------------------------------------------------ */
/* Output                                                              */
/* ------------------------------------------------------------------ */

static void write_all(const void *data, size_t n) {
  const char *p = (const char *)data;
  while (n > 0) {
    ssize_t w = write(1, p, n);
    if (w < 0) {
      if (errno == EINTR) continue;
      _exit(71);
    }
    p += w;
    n -= (size_t)w;
  }
}

static void write_frame(const char *body, size_t n) {
  unsigned char h[4];
  h[0] = (unsigned char)(n & 0xff);
  h[1] = (unsigned char)((n >> 8) & 0xff);
  h[2] = (unsigned char)((n >> 16) & 0xff);
  h[3] = (unsigned char)((n >> 24) & 0xff);
  write_all(h, 4);
  write_all(body, n);
}

__attribute__((noreturn)) static void reply_text(const char *s) {
  write_frame(s, strlen(s));
  _exit(0);
}

static const char *stop_name(int s) {
  switch (s) {
    case STOP_STEPS: return "steps";
    case STOP_DEPTH: return "call_depth";
    case STOP_VALUE: return "value_size";
    case STOP_UNLISTED: return "unlisted_name";
    case STOP_MISMATCH: return "call_mismatch";
    default: return "lua_error";
  }
}

__attribute__((noreturn)) static void reply_refused(const char *reason) {
  char b[96];
  snprintf(b, sizeof b, "{\"reason\":\"%s\",\"status\":\"refused\"}", reason);
  reply_text(b);
}

__attribute__((noreturn)) static void reply_memory(void) { reply_text("{\"status\":\"memory\"}"); }

__attribute__((noreturn)) static void reply_pending(void);

__attribute__((noreturn)) static void reply_sticky(void) {
  if (G.sticky == STOP_MEMORY) reply_memory();
  if (G.sticky == STOP_PENDING) reply_pending();
  reply_refused(stop_name(G.sticky));
}

#define RUNTIME_JSON                                                      \
  "{\"build_options\":\"" ELZ_BUILD_OPTIONS "\",\"host_sha256\":\"" ELZ_HOST_SHA256 \
  "\",\"lua_release\":\"" ELZ_LUA_RELEASE "\",\"seed\":\"" ELZ_SEED        \
  "\",\"upstream_revision\":\"" ELZ_LUA_REVISION "\"}"

/* ------------------------------------------------------------------ */
/* Growable byte buffer with a limit                                    */
/* ------------------------------------------------------------------ */

static void charge(lua_State *L, long long n);

/* The reply writer uses a buf with L == NULL: it grows by realloc and charges
** nothing. helpers.json_encode uses a buf whose storage is one Lua userdata of
** exactly `limit` bytes (cap == limit, so it never grows) and L set: each put
** charges its bytes before it writes them. */
typedef struct {
  char *b;
  size_t n, cap, limit;
  lua_State *L;
} buf;

enum { E_OK = 0, E_INVALID = 1, E_SIZE = 2 };

static void *xrealloc(void *p, size_t n) {
  void *q = realloc(p, n);
  if (!q) _exit(70);
  return q;
}

static int buf_put(buf *B, const char *s, size_t n) {
  if (B->L) charge(B->L, (long long)n);
  if (n > B->limit - B->n) return E_SIZE;
  if (B->n + n > B->cap) {
    size_t c = B->cap ? B->cap : 256;
    while (c < B->n + n) c *= 2;
    B->b = (char *)xrealloc(B->b, c);
    B->cap = c;
  }
  memcpy(B->b + B->n, s, n);
  B->n += n;
  return E_OK;
}

#define PUT(B, lit) buf_put((B), (lit), sizeof(lit) - 1)

/* ------------------------------------------------------------------ */
/* Canonical float text: shortest round-trip digits, fixed layout        */
/* ------------------------------------------------------------------ */

static size_t fmt_float(double d, char *out) {
  int neg = signbit(d) != 0;
  double a = fabs(d);
  char tmp[48], digits[24];
  int p, nd = 0, e;
  char *q;
  size_t o = 0;
  for (p = 0; p <= 16; p++) {
    snprintf(tmp, sizeof tmp, "%.*e", p, a);
    if (strtod(tmp, NULL) == a) break;
  }
  q = tmp;
  digits[nd++] = *q++;
  if (*q == '.') {
    q++;
    while (*q >= '0' && *q <= '9') digits[nd++] = *q++;
  }
  e = atoi(q + 1);
  if (neg) out[o++] = '-';
  if (e >= -5 && e < 16) {
    int i;
    if (e < 0) {
      out[o++] = '0';
      out[o++] = '.';
      for (i = 0; i < -e - 1; i++) out[o++] = '0';
      for (i = 0; i < nd; i++) out[o++] = digits[i];
    } else if (nd <= e + 1) {
      for (i = 0; i < nd; i++) out[o++] = digits[i];
      for (i = 0; i < e + 1 - nd; i++) out[o++] = '0';
      out[o++] = '.';
      out[o++] = '0';
    } else {
      for (i = 0; i < e + 1; i++) out[o++] = digits[i];
      out[o++] = '.';
      for (i = e + 1; i < nd; i++) out[o++] = digits[i];
    }
  } else {
    int i;
    out[o++] = digits[0];
    out[o++] = '.';
    if (nd == 1) out[o++] = '0';
    for (i = 1; i < nd; i++) out[o++] = digits[i];
    out[o++] = 'e';
    o += (size_t)snprintf(out + o, 8, "%d", e);
  }
  out[o] = 0;
  return o;
}

/* ------------------------------------------------------------------ */
/* JSON parse into a host tree                                          */
/* ------------------------------------------------------------------ */

enum { T_NULL, T_FALSE, T_TRUE, T_INT, T_FLOAT, T_STR, T_ARR, T_OBJ };

typedef struct {
  unsigned char type;
  long long i;
  double d;
  size_t soff, slen; /* string value */
  size_t koff, klen; /* member key when the parent is an object */
  long first, last, next;
  size_t count;
} node;

static node *nodes;
static size_t nnodes, ncap;
static char *sarena;
static size_t slen_total, scap;
static const unsigned char *jp, *jend;

static long new_node(int type) {
  if (nnodes == ncap) {
    ncap = ncap ? ncap * 2 : 256;
    nodes = (node *)xrealloc(nodes, ncap * sizeof(node));
  }
  memset(&nodes[nnodes], 0, sizeof(node));
  nodes[nnodes].type = (unsigned char)type;
  nodes[nnodes].first = nodes[nnodes].last = nodes[nnodes].next = -1;
  return (long)nnodes++;
}

static void sput(const char *s, size_t n) {
  if (slen_total + n > scap) {
    size_t c = scap ? scap : 1024;
    while (c < slen_total + n) c *= 2;
    sarena = (char *)xrealloc(sarena, c);
    scap = c;
  }
  memcpy(sarena + slen_total, s, n);
  slen_total += n;
}

/* JSON white space is exactly space, tab, line feed and carriage return. */
static void skip_ws(const unsigned char **pp, const unsigned char *end) {
  while (*pp < end && (**pp == ' ' || **pp == '\t' || **pp == '\n' || **pp == '\r')) (*pp)++;
}

static void ws(void) { skip_ws(&jp, jend); }

static int hexv(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

/* Four hex digits at *pp: the value, and *pp moves past them. 0 or -1. */
static int hex4(const unsigned char **pp, const unsigned char *end, unsigned *out) {
  const unsigned char *q = *pp;
  unsigned v = 0;
  int i;
  if (end - q < 4) return -1;
  for (i = 0; i < 4; i++) {
    int h = hexv(q[i]);
    if (h < 0) return -1;
    v = v * 16 + (unsigned)h;
  }
  *pp = q + 4;
  *out = v;
  return 0;
}

/* The code point of a \u escape. *pp is just after the `u` and moves past the escape
** (and past the second escape of a surrogate pair). A lone surrogate is -1. */
static int unicode_escape(const unsigned char **pp, const unsigned char *end, unsigned *out) {
  unsigned cp, lo;
  if (hex4(pp, end, &cp) < 0) return -1;
  if (cp >= 0xD800 && cp <= 0xDBFF) {
    if (end - *pp < 2 || (*pp)[0] != '\\' || (*pp)[1] != 'u') return -1;
    *pp += 2;
    if (hex4(pp, end, &lo) < 0 || lo < 0xDC00 || lo > 0xDFFF) return -1;
    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
  } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
    return -1;
  }
  *out = cp;
  return 0;
}

/* The UTF-8 bytes of one code point in b; their number. */
static size_t utf8_encode(unsigned cp, char *b) {
  if (cp < 0x80) {
    b[0] = (char)cp;
    return 1;
  }
  if (cp < 0x800) {
    b[0] = (char)(0xC0 | (cp >> 6));
    b[1] = (char)(0x80 | (cp & 0x3F));
    return 2;
  }
  if (cp < 0x10000) {
    b[0] = (char)(0xE0 | (cp >> 12));
    b[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    b[2] = (char)(0x80 | (cp & 0x3F));
    return 3;
  }
  b[0] = (char)(0xF0 | (cp >> 18));
  b[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
  b[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
  b[3] = (char)(0x80 | (cp & 0x3F));
  return 4;
}

static void put_utf8(unsigned cp) {
  char b[4];
  sput(b, utf8_encode(cp, b));
}

/* Length of one valid UTF-8 sequence at s (n bytes left), or 0. */
static int utf8_len(const unsigned char *s, size_t n) {
  unsigned char c = s[0];
  if (c < 0x80) return 1;
  if (c >= 0xC2 && c <= 0xDF) return (n >= 2 && (s[1] & 0xC0) == 0x80) ? 2 : 0;
  if (c >= 0xE0 && c <= 0xEF) {
    if (n < 3 || (s[1] & 0xC0) != 0x80 || (s[2] & 0xC0) != 0x80) return 0;
    if (c == 0xE0 && s[1] < 0xA0) return 0;
    if (c == 0xED && s[1] > 0x9F) return 0;
    return 3;
  }
  if (c >= 0xF0 && c <= 0xF4) {
    if (n < 4 || (s[1] & 0xC0) != 0x80 || (s[2] & 0xC0) != 0x80 || (s[3] & 0xC0) != 0x80) return 0;
    if (c == 0xF0 && s[1] < 0x90) return 0;
    if (c == 0xF4 && s[1] > 0x8F) return 0;
    return 4;
  }
  return 0;
}

/* Parse a string at jp (opening quote). On success the decoded bytes are
** appended to the arena; off and len describe them. */
static int parse_string(size_t *off, size_t *len) {
  if (jp >= jend || *jp != '"') return -1;
  jp++;
  *off = slen_total;
  for (;;) {
    unsigned char c;
    if (jp >= jend) return -1;
    c = *jp;
    if (c == '"') {
      jp++;
      break;
    }
    if (c < 0x20) return -1;
    if (c == '\\') {
      jp++;
      if (jp >= jend) return -1;
      switch (*jp) {
        case '"': sput("\"", 1); jp++; break;
        case '\\': sput("\\", 1); jp++; break;
        case '/': sput("/", 1); jp++; break;
        case 'b': sput("\b", 1); jp++; break;
        case 'f': sput("\f", 1); jp++; break;
        case 'n': sput("\n", 1); jp++; break;
        case 'r': sput("\r", 1); jp++; break;
        case 't': sput("\t", 1); jp++; break;
        case 'u': {
          unsigned cp;
          jp++;
          if (unicode_escape(&jp, jend, &cp) < 0) return -1;
          put_utf8(cp);
          break;
        }
        default: return -1;
      }
    } else {
      int l = utf8_len(jp, (size_t)(jend - jp));
      if (l == 0) return -1;
      sput((const char *)jp, (size_t)l);
      jp += l;
    }
  }
  *len = slen_total - *off;
  return 0;
}

static int cmp_key(const void *a, const void *b) {
  const node *x = &nodes[*(const long *)a], *y = &nodes[*(const long *)b];
  size_t m = x->klen < y->klen ? x->klen : y->klen;
  int c = memcmp(sarena + x->koff, sarena + y->koff, m);
  if (c) return c;
  return x->klen < y->klen ? -1 : (x->klen > y->klen ? 1 : 0);
}

static int dup_keys(long obj) {
  size_t n = nodes[obj].count, i = 0;
  long c, *idx;
  if (n < 2) return 0;
  idx = (long *)xrealloc(NULL, n * sizeof(long));
  for (c = nodes[obj].first; c >= 0; c = nodes[c].next) idx[i++] = c;
  qsort(idx, n, sizeof(long), cmp_key);
  for (i = 1; i < n; i++)
    if (cmp_key(&idx[i - 1], &idx[i]) == 0) {
      free(idx);
      return 1;
    }
  free(idx);
  return 0;
}

static long parse_value(int depth);

static void link_child(long parent, long child) {
  if (nodes[parent].first < 0)
    nodes[parent].first = child;
  else
    nodes[nodes[parent].last].next = child;
  nodes[parent].last = child;
  nodes[parent].count++;
}

/* The grammar of a JSON number at s: its length, or 0 when it is not one. */
static size_t num_span(const unsigned char *s, const unsigned char *end, int *is_float) {
  const unsigned char *q = s;
  *is_float = 0;
  if (q < end && *q == '-') q++;
  if (q >= end) return 0;
  if (*q == '0') {
    q++;
  } else if (*q >= '1' && *q <= '9') {
    while (q < end && *q >= '0' && *q <= '9') q++;
  } else {
    return 0;
  }
  if (q < end && *q == '.') {
    *is_float = 1;
    q++;
    if (q >= end || *q < '0' || *q > '9') return 0;
    while (q < end && *q >= '0' && *q <= '9') q++;
  }
  if (q < end && (*q == 'e' || *q == 'E')) {
    *is_float = 1;
    q++;
    if (q < end && (*q == '+' || *q == '-')) q++;
    if (q >= end || *q < '0' || *q > '9') return 0;
    while (q < end && *q >= '0' && *q <= '9') q++;
  }
  return (size_t)(q - s);
}

/* The value of the n bytes of a number: a float must be finite, an integer must fit
** int64, and the text is at most 63 bytes. 0, or -1 when it is refused. */
static int num_value(const unsigned char *s, size_t n, int is_float, long long *iv, double *dv) {
  char tmp[64];
  if (n >= sizeof tmp) return -1;
  memcpy(tmp, s, n);
  tmp[n] = 0;
  if (is_float) {
    *dv = strtod(tmp, NULL);
    if (!isfinite(*dv)) return -1;
  } else {
    errno = 0;
    *iv = strtoll(tmp, NULL, 10);
    if (errno == ERANGE) return -1;
  }
  return 0;
}

static long parse_number(void) {
  int is_float;
  long long iv = 0;
  double dv = 0;
  long id;
  size_t n = num_span(jp, jend, &is_float);
  if (n == 0 || num_value(jp, n, is_float, &iv, &dv) < 0) return -1;
  jp += n;
  id = new_node(is_float ? T_FLOAT : T_INT);
  if (is_float)
    nodes[id].d = dv;
  else
    nodes[id].i = iv;
  return id;
}

/* The literal lit at *pp: 1 and *pp moves past it, or 0. */
static int literal_at(const unsigned char **pp, const unsigned char *end, const char *lit) {
  size_t n = strlen(lit);
  if ((size_t)(end - *pp) < n || memcmp(*pp, lit, n) != 0) return 0;
  *pp += n;
  return 1;
}

static int literal(const char *lit) { return literal_at(&jp, jend, lit); }

static long parse_value(int depth) {
  long id;
  ws();
  if (jp >= jend) return -1;
  switch (*jp) {
    case 'n': return literal("null") ? new_node(T_NULL) : -1;
    case 't': return literal("true") ? new_node(T_TRUE) : -1;
    case 'f': return literal("false") ? new_node(T_FALSE) : -1;
    case '"': {
      size_t off, len;
      if (parse_string(&off, &len) < 0) return -1;
      id = new_node(T_STR);
      nodes[id].soff = off;
      nodes[id].slen = len;
      return id;
    }
    case '[': {
      if (depth > PARSE_DEPTH_MAX) return -1;
      jp++;
      id = new_node(T_ARR);
      ws();
      if (jp < jend && *jp == ']') {
        jp++;
        return id;
      }
      for (;;) {
        long c = parse_value(depth + 1);
        if (c < 0) return -1;
        link_child(id, c);
        ws();
        if (jp >= jend) return -1;
        if (*jp == ',') {
          jp++;
          continue;
        }
        if (*jp == ']') {
          jp++;
          return id;
        }
        return -1;
      }
    }
    case '{': {
      if (depth > PARSE_DEPTH_MAX) return -1;
      jp++;
      id = new_node(T_OBJ);
      ws();
      if (jp < jend && *jp == '}') {
        jp++;
        return id;
      }
      for (;;) {
        size_t koff, klen;
        long c;
        ws();
        if (parse_string(&koff, &klen) < 0) return -1;
        ws();
        if (jp >= jend || *jp != ':') return -1;
        jp++;
        c = parse_value(depth + 1);
        if (c < 0) return -1;
        nodes[c].koff = koff;
        nodes[c].klen = klen;
        link_child(id, c);
        ws();
        if (jp >= jend) return -1;
        if (*jp == ',') {
          jp++;
          continue;
        }
        if (*jp == '}') {
          jp++;
          if (dup_keys(id)) return -1;
          return id;
        }
        return -1;
      }
    }
    default: return parse_number();
  }
}

static long parse_document(const unsigned char *b, size_t n) {
  long id;
  jp = b;
  jend = b + n;
  id = parse_value(1);
  if (id < 0) return -1;
  ws();
  if (jp != jend) return -1;
  return id;
}

/* ------------------------------------------------------------------ */
/* Allocator with live-byte accounting and the string guard              */
/* ------------------------------------------------------------------ */

static void *host_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  size_t old;
  void *p;
  (void)ud;
  if (nsize == 0) {
    if (ptr) {
      G.live -= osize;
      free(ptr);
    }
    return NULL;
  }
  old = ptr ? osize : 0;
  if (!ptr && G.armed && osize == LUA_TSTRING) {
    /* a new string object: size is offsetof(TString, contents) + length + 1 */
    size_t head = offsetof(TString, contents);
    if (nsize > head + 1 && nsize - head - 1 > G.value_bytes) {
      set_sticky(STOP_VALUE);
      return NULL;
    }
  }
  if (G.alloc_cap && nsize > G.alloc_cap) {
    set_sticky(STOP_VALUE);
    return NULL;
  }
  if (nsize > old && (nsize - old > G.mem_limit || G.live + (nsize - old) > G.mem_limit)) {
    set_sticky(STOP_MEMORY);
    return NULL;
  }
  p = realloc(ptr, nsize);
  if (!p) {
    set_sticky(STOP_MEMORY);
    return NULL;
  }
  G.live = G.live - old + nsize;
  return p;
}

__attribute__((noreturn)) static int panic(lua_State *L) {
  (void)L;
  if (G.sticky) reply_sticky();
  _exit(70);
}

/* ------------------------------------------------------------------ */
/* Hook: counted steps, active Lua frames, sticky stop                    */
/* ------------------------------------------------------------------ */

static long long count_lua_frames(lua_State *L, long long cap) {
  lua_Debug a;
  long long n = 0;
  int lvl;
  for (lvl = 0; lua_getstack(L, lvl, &a); lvl++) {
    lua_getinfo(L, "S", &a);
    if (a.what[0] != 'C') {
      n++;
      if (n > cap) break;
    }
  }
  return n;
}

static void poll_stdin(void) {
  struct pollfd pfd;
  pfd.fd = 0;
  pfd.events = POLLIN;
  pfd.revents = 0;
  if (poll(&pfd, 1, 0) > 0) {
    if (pfd.revents & (POLLHUP | POLLERR | POLLNVAL)) _exit(0);
    if (pfd.revents & POLLIN) {
      char c;
      ssize_t r = read(0, &c, 1);
      if (r == 0) _exit(0);
    }
  }
}

static void hook(lua_State *L, lua_Debug *ar) {
  if (G.sticky) {
    stop_raise(L);
    return;
  }
  switch (ar->event) {
    case LUA_HOOKCOUNT:
      if (++G.steps > G.steps_limit) {
        set_sticky(STOP_STEPS);
        stop_raise(L);
      }
      if ((++G.poll_counter & 1023u) == 0) poll_stdin();
      break;
    case LUA_HOOKCALL:
      lua_getinfo(L, "S", ar);
      if (ar->what[0] != 'C') {
        if (++G.depth > G.depth_limit) {
          long long real = count_lua_frames(L, G.depth_limit);
          if (real > G.depth_limit) {
            set_sticky(STOP_DEPTH);
            stop_raise(L);
          }
          G.depth = real;
        }
      }
      break;
    case LUA_HOOKRET:
      lua_getinfo(L, "S", ar);
      if (ar->what[0] != 'C' && G.depth > 0) G.depth--;
      break;
    default: break; /* tail calls replace a frame: no change */
  }
}

static void charge(lua_State *L, long long n) {
  G.steps += n;
  if (G.steps > G.steps_limit) {
    set_sticky(STOP_STEPS);
    stop_raise(L);
  }
}

/* ------------------------------------------------------------------ */
/* Wrappers (policy version 3)                                           */
/* ------------------------------------------------------------------ */

static int unlisted(lua_State *L) {
  set_sticky(STOP_UNLISTED);
  return stop_raise(L);
}

/* pcall: never returns a caught stop; a stop is raised again. */
static int w_pcall(lua_State *L) {
  int status;
  luaL_checkany(L, 1);
  status = lua_pcall(L, lua_gettop(L) - 1, LUA_MULTRET, 0);
  if (G.sticky) return stop_raise(L);
  if (status != LUA_OK) {
    G.depth = count_lua_frames(L, LLONG_MAX);
    lua_pushboolean(L, 0);
    lua_insert(L, -2);
    return 2;
  }
  lua_pushboolean(L, 1);
  lua_insert(L, 1);
  return lua_gettop(L);
}

/* ------------------------------------------------------------------ */
/* Helpers (policy version 3): fields of the global `helpers`            */
/* ------------------------------------------------------------------ */

/* Record the table at the top of the stack as an array (kind 1) or an object (kind 2)
** in the host-private weak table `elzoo.kinds`. */
static void mark_kind(lua_State *L, int kind) {
  lua_getfield(L, LUA_REGISTRYINDEX, "elzoo.kinds");
  lua_pushvalue(L, -2);
  lua_pushinteger(L, kind);
  lua_rawset(L, -3);
  lua_pop(L, 1);
}

/* helpers.object(): a fresh empty table that encodes as a JSON object. */
static int h_object(lua_State *L) {
  if (lua_gettop(L) != 0) return luaL_error(L, "helpers.object: takes no argument");
  charge(L, 1);
  lua_createtable(L, 0, 0);
  mark_kind(L, 2);
  return 1;
}

/* The text argument at index i, or NULL when it is not of Lua type string (no
** coercion). A string is never over value_bytes (the allocator refuses it), so
** its length converts to long long safely; the check makes that explicit. */
static const char *text_arg(lua_State *L, int i, size_t *len) {
  const char *s;
  if (lua_type(L, i) != LUA_TSTRING) return NULL;
  s = lua_tolstring(L, i, len);
  if (*len > G.value_bytes) {
    set_sticky(STOP_VALUE);
    stop_raise(L);
  }
  return s;
}

/* helpers.text_trim(text): without leading and trailing ASCII white space
** (0x20 and 0x09..0x0D). */
static int h_text_trim(lua_State *L) {
  const char *s;
  size_t len, a, b;
  if (lua_gettop(L) != 1 || (s = text_arg(L, 1, &len)) == NULL)
    return luaL_error(L, "helpers.text_trim: expected one string");
  charge(L, (long long)len);
  a = 0;
  b = len;
  while (a < b && (s[a] == ' ' || (s[a] >= 0x09 && s[a] <= 0x0D))) a++;
  while (b > a && (s[b - 1] == ' ' || (s[b - 1] >= 0x09 && s[b - 1] <= 0x0D))) b--;
  charge(L, (long long)(b - a));
  if (b - a > G.value_bytes) {
    set_sticky(STOP_VALUE);
    return stop_raise(L);
  }
  lua_pushlstring(L, s + a, b - a);
  return 1;
}

/* helpers.text_split(text, separator): the parts of text between the plain,
** non-empty separator, left to right and non-overlapping, as a dense array;
** n occurrences give n + 1 parts and empty parts are kept. */
static int h_text_split(lua_State *L) {
  const char *s, *sep, *p, *end;
  size_t len, seplen;
  lua_Integer idx = 1;
  if (lua_gettop(L) != 2 || (s = text_arg(L, 1, &len)) == NULL || (sep = text_arg(L, 2, &seplen)) == NULL)
    return luaL_error(L, "helpers.text_split: expected two strings");
  if (seplen == 0) return luaL_error(L, "helpers.text_split: empty separator");
  charge(L, (long long)len + (long long)seplen);
  luaL_checkstack(L, 3, "helpers");
  lua_createtable(L, 0, 0);
  p = s;
  end = s + len;
  for (;;) {
    const char *q = NULL;
    size_t plen;
    if ((size_t)(end - p) >= seplen) {
      const char *scan = p, *last = end - seplen; /* last possible start */
      while (scan <= last) {
        scan = (const char *)memchr(scan, (unsigned char)sep[0], (size_t)(last - scan) + 1);
        if (scan == NULL) break;
        charge(L, (long long)seplen - 1); /* the bytes that memcmp can read after the first */
        if (memcmp(scan, sep, seplen) == 0) {
          q = scan;
          break;
        }
        scan++;
      }
    }
    plen = (size_t)((q ? q : end) - p);
    charge(L, 1 + (long long)plen);
    lua_pushlstring(L, p, plen);
    lua_rawseti(L, -2, idx++);
    if (q == NULL) break;
    p = q + seplen;
  }
  return 1;
}

static int enc_value(lua_State *L, int idx, int depth, buf *B);

/* ------------------------------------------------------------------ */
/* helpers.json_decode: a reader with a local cursor that pushes Lua values  */
/* directly. It uses none of the request reader's static state (jp, jend, nodes,  */
/* sarena): every byte it keeps is Lua memory, so memory_bytes counts it and an   */
/* error frees it. The rules are those of the request reader, but at most 32      */
/* nested containers.                                                             */
/* ------------------------------------------------------------------ */

typedef struct {
  lua_State *L;
  const unsigned char *p, *end;
} jcur;

/* A string at the cursor (opening quote): its decoded bytes are pushed as one Lua
** string, charged by length first. The first escape opens a luaL_Buffer; it is closed
** by luaL_pushresult before this function returns, and nothing recurses while it is
** open. Raw bytes must be valid UTF-8 and not below 0x20. 0, or -1 (the caller
** raises, which discards the stack). */
static int jc_string(jcur *c) {
  lua_State *L = c->L;
  luaL_Buffer b;
  int buffered = 0;
  const unsigned char *start;
  if (c->p >= c->end || *c->p != '"') return -1;
  c->p++;
  start = c->p;
  for (;;) {
    unsigned char ch;
    if (c->p >= c->end) return -1;
    ch = *c->p;
    if (ch == '"') break;
    if (ch < 0x20) return -1;
    if (ch == '\\') {
      char e[4];
      size_t el = 1;
      if (!buffered) {
        luaL_buffinit(L, &b);
        buffered = 1;
      }
      luaL_addlstring(&b, (const char *)start, (size_t)(c->p - start));
      c->p++;
      if (c->p >= c->end) return -1;
      if (*c->p == 'u') {
        unsigned cp;
        c->p++;
        if (unicode_escape(&c->p, c->end, &cp) < 0) return -1;
        el = utf8_encode(cp, e);
      } else {
        switch (*c->p) {
          case '"': e[0] = '"'; break;
          case '\\': e[0] = '\\'; break;
          case '/': e[0] = '/'; break;
          case 'b': e[0] = '\b'; break;
          case 'f': e[0] = '\f'; break;
          case 'n': e[0] = '\n'; break;
          case 'r': e[0] = '\r'; break;
          case 't': e[0] = '\t'; break;
          default: return -1;
        }
        c->p++;
      }
      luaL_addlstring(&b, e, el);
      start = c->p;
    } else {
      int l = utf8_len(c->p, (size_t)(c->end - c->p));
      if (l == 0) return -1;
      c->p += l;
    }
  }
  /* the sizes below are at most the length of the text argument (at most value_bytes) */
  if (buffered) {
    luaL_addlstring(&b, (const char *)start, (size_t)(c->p - start));
    charge(L, (long long)luaL_bufflen(&b));
    luaL_pushresult(&b);
  } else {
    charge(L, (long long)(c->p - start));
    lua_pushlstring(L, (const char *)start, (size_t)(c->p - start));
  }
  c->p++;
  return 0;
}

static int jc_number(jcur *c) {
  int is_float;
  long long iv = 0;
  double dv = 0;
  size_t n = num_span(c->p, c->end, &is_float);
  if (n == 0 || num_value(c->p, n, is_float, &iv, &dv) < 0) return -1;
  c->p += n;
  if (is_float)
    lua_pushnumber(c->L, (lua_Number)dv);
  else
    lua_pushinteger(c->L, (lua_Integer)iv);
  return 0;
}

/* One value: pushes exactly one Lua value. nest is the number of open containers;
** the 33rd is refused. A container is charged one step for each entry, before the
** entry is stored. */
static int jc_value(jcur *c, int nest) {
  lua_State *L = c->L;
  luaL_checkstack(L, 8, "helpers");
  skip_ws(&c->p, c->end);
  if (c->p >= c->end) return -1;
  switch (*c->p) {
    case 'n':
      if (!literal_at(&c->p, c->end, "null")) return -1;
      lua_pushlightuserdata(L, &null_sentinel);
      return 0;
    case 't':
      if (!literal_at(&c->p, c->end, "true")) return -1;
      lua_pushboolean(L, 1);
      return 0;
    case 'f':
      if (!literal_at(&c->p, c->end, "false")) return -1;
      lua_pushboolean(L, 0);
      return 0;
    case '"': return jc_string(c);
    case '[': {
      lua_Integer i = 1;
      if (nest >= MAX_CONTAINERS) return -1;
      c->p++;
      lua_createtable(L, 0, 0);
      mark_kind(L, 1);
      skip_ws(&c->p, c->end);
      if (c->p < c->end && *c->p == ']') {
        c->p++;
        return 0;
      }
      for (;;) {
        if (jc_value(c, nest + 1) < 0) return -1;
        charge(L, 1);
        lua_rawseti(L, -2, i++);
        skip_ws(&c->p, c->end);
        if (c->p >= c->end) return -1;
        if (*c->p == ',') {
          c->p++;
          continue;
        }
        if (*c->p == ']') {
          c->p++;
          return 0;
        }
        return -1;
      }
    }
    case '{': {
      if (nest >= MAX_CONTAINERS) return -1;
      c->p++;
      lua_createtable(L, 0, 0);
      mark_kind(L, 2);
      skip_ws(&c->p, c->end);
      if (c->p < c->end && *c->p == '}') {
        c->p++;
        return 0;
      }
      for (;;) {
        int duplicate;
        skip_ws(&c->p, c->end);
        if (jc_string(c) < 0) return -1; /* stack: object, key */
        skip_ws(&c->p, c->end);
        if (c->p >= c->end || *c->p != ':') return -1;
        c->p++;
        lua_pushvalue(L, -1);
        lua_rawget(L, -3); /* a member is never nil: null is the light userdata */
        duplicate = !lua_isnil(L, -1);
        lua_pop(L, 1);
        if (duplicate) return -1;
        if (jc_value(c, nest + 1) < 0) return -1; /* stack: object, key, value */
        charge(L, 1);
        lua_rawset(L, -3);
        skip_ws(&c->p, c->end);
        if (c->p >= c->end) return -1;
        if (*c->p == ',') {
          c->p++;
          continue;
        }
        if (*c->p == '}') {
          c->p++;
          return 0;
        }
        return -1;
      }
    }
    default: return jc_number(c);
  }
}

/* helpers.json_decode(text): the plain value of one JSON document. */
static int h_json_decode(lua_State *L) {
  const char *s;
  size_t len;
  jcur c;
  if (lua_gettop(L) != 1 || (s = text_arg(L, 1, &len)) == NULL)
    return luaL_error(L, "helpers.json_decode: expected one string");
  charge(L, (long long)len);
  c.L = L;
  c.p = (const unsigned char *)s;
  c.end = c.p + len;
  if (jc_value(&c, 0) < 0) return luaL_error(L, "helpers.json_decode: invalid JSON");
  skip_ws(&c.p, c.end);
  if (c.p != c.end) return luaL_error(L, "helpers.json_decode: invalid JSON");
  return 1; /* the value is at the top, above the text */
}

/* helpers.json_encode(value): the canonical JSON text of a plain value, by the
** rules of the reply writer (the same functions). The output is written into one
** userdata of value_bytes bytes (Lua memory, so memory_bytes counts it and an error
** frees it); each put charges its bytes first. A text over value_bytes is the
** value_size stop. */
static int h_json_encode(lua_State *L) {
  buf B;
  int rc;
  if (lua_gettop(L) != 1) return luaL_error(L, "helpers.json_encode: expected one value");
  memset(&B, 0, sizeof B);
  B.cap = B.limit = G.value_bytes;
  B.L = L;
  B.b = (char *)lua_newuserdatauv(L, G.value_bytes, 0);
  rc = enc_value(L, 1, 0, &B);
  if (rc == E_SIZE) {
    set_sticky(STOP_VALUE);
    return stop_raise(L);
  }
  if (rc != E_OK) return luaL_error(L, "helpers.json_encode: value is not plain data");
  lua_pushlstring(L, B.b, B.n);
  return 1;
}

/* helpers.text_utf8_len(text): the number of code points of valid UTF-8 text. */
static int h_text_utf8_len(lua_State *L) {
  const char *s;
  size_t len, i = 0;
  lua_Integer count = 0;
  if (lua_gettop(L) != 1 || (s = text_arg(L, 1, &len)) == NULL)
    return luaL_error(L, "helpers.text_utf8_len: expected one string");
  charge(L, (long long)len);
  while (i < len) {
    int l = utf8_len((const unsigned char *)s + i, len - i);
    if (l == 0) return luaL_error(L, "helpers.text_utf8_len: invalid UTF-8");
    i += (size_t)l;
    count++;
  }
  lua_pushinteger(L, count);
  return 1;
}

/* Time helpers: integer-only proleptic Gregorian calendar (days from civil, civil
** from days), UTC. No time.h function, no clock, no locale, no zone. */
#define TIME_MAX_MS 253402300799999LL

static long long days_from_civil(long long y, long long m, long long d) {
  long long era, yoe, doy, doe;
  if (m <= 2) y -= 1;
  era = (y >= 0 ? y : y - 399) / 400;
  yoe = y - era * 400;
  doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
  doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe - 719468;
}

static void civil_from_days(long long z, long long *y, long long *m, long long *d) {
  long long era, doe, yoe, doy, mp;
  z += 719468;
  era = (z >= 0 ? z : z - 146096) / 146097;
  doe = z - era * 146097;
  yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  mp = (5 * doy + 2) / 153;
  *d = doy - (153 * mp + 2) / 5 + 1;
  *m = mp < 10 ? mp + 3 : mp - 9;
  *y = yoe + era * 400 + (*m <= 2 ? 1 : 0);
}

static int is_leap_year(long long y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }

/* The one argument of time_parts and time_iso8601: a Lua integer in 0..TIME_MAX_MS.
** A float (also 1.0), a string, nil and a table are not integers (no coercion). */
static int time_arg(lua_State *L, long long *ms) {
  long long v;
  if (lua_gettop(L) != 1 || lua_type(L, 1) != LUA_TNUMBER || !lua_isinteger(L, 1)) return 0;
  v = (long long)lua_tointeger(L, 1);
  if (v < 0 || v > TIME_MAX_MS) return 0;
  *ms = v;
  return 1;
}

/* The seven calendar fields of a millisecond value, and the weekday (1 = Monday). */
static void time_split(long long ms, long long f[8]) {
  long long days = ms / 86400000LL, rem = ms % 86400000LL;
  civil_from_days(days, &f[0], &f[1], &f[2]);
  f[3] = rem / 3600000LL;
  f[4] = rem % 3600000LL / 60000LL;
  f[5] = rem % 60000LL / 1000LL;
  f[6] = rem % 1000LL;
  f[7] = (days + 3) % 7 + 1; /* 1970-01-01 was a Thursday (4) */
}

static const char *const time_fields[8] = {"year", "month", "day", "hour", "minute", "second", "millisecond", "weekday"};

/* helpers.time_parts(unix_ms): a table marked as an object with the eight integer fields. */
static int h_time_parts(lua_State *L) {
  long long ms, f[8];
  int i;
  if (!time_arg(L, &ms)) return luaL_error(L, "helpers.time_parts: expected an integer in range");
  charge(L, 8);
  time_split(ms, f);
  luaL_checkstack(L, 3, "helpers");
  lua_createtable(L, 0, 8);
  for (i = 0; i < 8; i++) {
    lua_pushinteger(L, (lua_Integer)f[i]);
    lua_setfield(L, -2, time_fields[i]);
  }
  mark_kind(L, 2);
  return 1;
}

/* helpers.time_unix_ms(parts): reads exactly the seven fields, with raw access. */
static int h_time_unix_ms(lua_State *L) {
  long long f[7], dim;
  int i;
  static const int mdays[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  if (lua_gettop(L) != 1 || lua_type(L, 1) != LUA_TTABLE)
    return luaL_error(L, "helpers.time_unix_ms: expected the parts of a real date and time");
  charge(L, 7);
  luaL_checkstack(L, 2, "helpers");
  for (i = 0; i < 7; i++) {
    lua_pushstring(L, time_fields[i]);
    lua_rawget(L, 1);
    if (lua_type(L, -1) != LUA_TNUMBER || !lua_isinteger(L, -1))
      return luaL_error(L, "helpers.time_unix_ms: expected the parts of a real date and time");
    f[i] = (long long)lua_tointeger(L, -1);
    lua_pop(L, 1);
  }
  dim = (f[1] >= 1 && f[1] <= 12) ? mdays[f[1] - 1] + (f[1] == 2 && is_leap_year(f[0]) ? 1 : 0) : 0;
  if (f[0] < 1970 || f[0] > 9999 || f[1] < 1 || f[1] > 12 || f[2] < 1 || f[2] > dim || f[3] < 0 || f[3] > 23 ||
      f[4] < 0 || f[4] > 59 || f[5] < 0 || f[5] > 59 || f[6] < 0 || f[6] > 999)
    return luaL_error(L, "helpers.time_unix_ms: expected the parts of a real date and time");
  lua_pushinteger(L, (lua_Integer)(days_from_civil(f[0], f[1], f[2]) * 86400000LL + f[3] * 3600000LL +
                                   f[4] * 60000LL + f[5] * 1000LL + f[6]));
  return 1;
}

/* helpers.time_iso8601(unix_ms): YYYY-MM-DDTHH:MM:SS.mmmZ (24 bytes). */
static int h_time_iso8601(lua_State *L) {
  long long ms, f[8];
  char out[32];
  int n;
  if (!time_arg(L, &ms)) return luaL_error(L, "helpers.time_iso8601: expected an integer in range");
  charge(L, 24);
  if (24 > G.value_bytes) {
    set_sticky(STOP_VALUE);
    return stop_raise(L);
  }
  time_split(ms, f);
  n = snprintf(out, sizeof out, "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", (int)f[0], (int)f[1], (int)f[2], (int)f[3],
               (int)f[4], (int)f[5], (int)f[6]);
  if (n != 24) return luaL_error(L, "helpers.time_iso8601: expected an integer in range");
  lua_pushlstring(L, out, 24);
  return 1;
}

static int w_tostring(lua_State *L) {
  int t;
  luaL_checkany(L, 1);
  t = lua_type(L, 1);
  if (t == LUA_TNIL || t == LUA_TBOOLEAN || t == LUA_TSTRING) {
    luaL_tolstring(L, 1, NULL);
    return 1;
  }
  if (t == LUA_TNUMBER) {
    if (lua_isinteger(L, 1) || isfinite(lua_tonumber(L, 1))) {
      luaL_tolstring(L, 1, NULL);
      return 1;
    }
  }
  return luaL_error(L, "tostring: value has no portable text");
}

/* Reject any table whose keys are not exactly 1..n. */
static void check_dense(lua_State *L, int idx) {
  lua_Integer n, count = 0;
  if (lua_type(L, idx) != LUA_TTABLE) return;
  idx = lua_absindex(L, idx);
  n = (lua_Integer)lua_rawlen(L, idx);
  charge(L, (long long)n + 1);
  lua_pushnil(L);
  while (lua_next(L, idx)) {
    lua_Integer k;
    if (!lua_isinteger(L, -2)) {
      lua_pop(L, 2);
      luaL_error(L, "table is not a dense array");
    }
    k = lua_tointeger(L, -2);
    if (k < 1 || k > n) {
      lua_pop(L, 2);
      luaL_error(L, "table is not a dense array");
    }
    count++;
    lua_pop(L, 1);
  }
  if (count != n) luaL_error(L, "table is not a dense array");
}

static size_t cap_value(void) {
  return G.value_bytes > (SIZE_MAX - 8192) / 2 ? SIZE_MAX : G.value_bytes * 2 + 8192;
}

/* modes (upvalue 2) */
enum { W_DENSE1, W_DENSE_MOVE, W_CAP, W_CONCAT, W_REP, W_CHAR, W_GSUB, W_FORMAT };

static void check_format(lua_State *L) {
  size_t len, i = 0;
  int arg = 1;
  const char *f = luaL_checklstring(L, 1, &len);
  while (i < len) {
    char c;
    if (f[i++] != '%') continue;
    if (i < len && f[i] == '%') {
      i++;
      continue;
    }
    while (i < len && strchr("-+ #0123456789.", f[i])) i++;
    if (i >= len) return; /* upstream reports the incomplete conversion */
    c = f[i++];
    arg++;
    if (c == 'p') luaL_error(L, "invalid conversion '%%p' to 'format'");
    if (c == 's' || c == 'q') {
      int t = lua_type(L, arg);
      if (t != LUA_TNIL && t != LUA_TBOOLEAN && t != LUA_TNUMBER && t != LUA_TSTRING && t != LUA_TNONE)
        luaL_error(L, "format: value has no portable text");
    }
  }
}

static int w_generic(lua_State *L) {
  int mode = (int)lua_tointeger(L, lua_upvalueindex(2));
  int n, st, capped = 0;
  size_t saved;
  switch (mode) {
    case W_DENSE1: check_dense(L, 1); break;
    case W_DENSE_MOVE:
      check_dense(L, 1);
      if (!lua_isnoneornil(L, 5)) check_dense(L, 5);
      break;
    case W_CONCAT:
      check_dense(L, 1);
      capped = 1;
      break;
    case W_CAP: capped = 1; break;
    case W_FORMAT:
      check_format(L);
      capped = 1;
      break;
    case W_GSUB: capped = lua_type(L, 3) != LUA_TFUNCTION; break;
    case W_CHAR:
      if ((size_t)lua_gettop(L) > G.value_bytes) {
        set_sticky(STOP_VALUE);
        return stop_raise(L);
      }
      capped = 1;
      break;
    case W_REP: {
      size_t l, sep = 0;
      lua_Integer cnt;
      luaL_checklstring(L, 1, &l);
      cnt = luaL_checkinteger(L, 2);
      if (!lua_isnoneornil(L, 3)) luaL_checklstring(L, 3, &sep);
      if (cnt <= 0 || l + sep == 0) {
        lua_pushliteral(L, "");
        return 1;
      }
      {
        unsigned long long a, b, tot;
        if (__builtin_mul_overflow((unsigned long long)cnt, (unsigned long long)l, &a) ||
            __builtin_mul_overflow((unsigned long long)(cnt - 1), (unsigned long long)sep, &b) ||
            __builtin_add_overflow(a, b, &tot) || tot > G.value_bytes) {
          set_sticky(STOP_VALUE);
          return stop_raise(L);
        }
      }
      capped = 1;
      break;
    }
    default: break;
  }
  n = lua_gettop(L);
  lua_pushvalue(L, lua_upvalueindex(1));
  lua_insert(L, 1);
  saved = G.alloc_cap;
  if (capped) G.alloc_cap = cap_value();
  st = lua_pcall(L, n, LUA_MULTRET, 0);
  G.alloc_cap = saved;
  if (G.sticky) return stop_raise(L);
  if (st != LUA_OK) return lua_error(L);
  return lua_gettop(L);
}

static int string_index(lua_State *L) {
  lua_pushvalue(L, 2);
  lua_rawget(L, lua_upvalueindex(1));
  if (lua_isnil(L, -1)) return unlisted(L);
  return 1;
}

/* ------------------------------------------------------------------ */
/* Environment (policy version 3)                                         */
/* ------------------------------------------------------------------ */

static const char *const string_names[] = {"byte", "char", "find", "format", "gmatch", "gsub", "len",
                                           "lower", "match", "pack", "packsize", "rep", "reverse",
                                           "sub", "unpack", "upper", NULL};
static const char *const table_names[] = {"concat", "insert", "move", "pack", "remove", "sort", "unpack", NULL};
static const char *const math_names[] = {"abs", "acos", "asin", "atan", "ceil", "cos", "deg", "exp",
                                         "floor", "fmod", "huge", "log", "max", "maxinteger", "min",
                                         "mininteger", "modf", "pi", "rad", "sin", "sqrt", "tan",
                                         "tointeger", "type", "ult", NULL};
static const char *const base_names[] = {"ipairs", "select", "type", "tonumber", "error", "assert", NULL};

static int mode_for(const char *lib, const char *name) {
  if (strcmp(lib, "string") == 0) {
    if (strcmp(name, "rep") == 0) return W_REP;
    if (strcmp(name, "char") == 0) return W_CHAR;
    if (strcmp(name, "gsub") == 0) return W_GSUB;
    if (strcmp(name, "format") == 0) return W_FORMAT;
    if (strcmp(name, "pack") == 0) return W_CAP;
  } else if (strcmp(lib, "table") == 0) {
    if (strcmp(name, "concat") == 0) return W_CONCAT;
    if (strcmp(name, "move") == 0) return W_DENSE_MOVE;
    if (strcmp(name, "insert") == 0 || strcmp(name, "remove") == 0 || strcmp(name, "sort") == 0 ||
        strcmp(name, "unpack") == 0)
      return W_DENSE1;
  }
  return -1;
}

/* Copy the listed names of one upstream library table into a fresh table.
** Stack: [... upstream] -> [... fresh view]; wrappers for function values. */
static void copy_library(lua_State *L, const char *lib, const char *const *names) {
  int up = lua_gettop(L), i;
  lua_createtable(L, 0, 32);
  for (i = 0; names[i]; i++) {
    int mode = mode_for(lib, names[i]);
    lua_getfield(L, up, names[i]);
    if (mode >= 0) {
      lua_pushinteger(L, mode);
      lua_pushcclosure(L, w_generic, 2);
    }
    lua_setfield(L, -2, names[i]);
  }
}

static void set_unlisted_meta(lua_State *L, int target, int mt) {
  lua_pushvalue(L, mt);
  lua_setmetatable(L, target);
}

static int init_env(lua_State *L) {
  int env, base, mt, strv, view, fresh, i;
  lua_newtable(L); /* env */
  env = lua_gettop(L);
  lua_newtable(L); /* shared metatable of the environment and the library tables */
  mt = lua_gettop(L);
  lua_pushcfunction(L, unlisted);
  lua_setfield(L, mt, "__index");

  lua_pushcfunction(L, luaopen_base);
  lua_call(L, 0, 1);
  base = lua_gettop(L);
  for (i = 0; base_names[i]; i++) {
    lua_getfield(L, base, base_names[i]);
    lua_setfield(L, env, base_names[i]);
  }
  lua_pushcfunction(L, w_tostring);
  lua_setfield(L, env, "tostring");
  lua_pushcfunction(L, w_pcall);
  lua_setfield(L, env, "pcall");
  lua_settop(L, mt);

  /* string */
  lua_pushcfunction(L, luaopen_string);
  lua_call(L, 0, 1);
  copy_library(L, "string", string_names);
  strv = lua_gettop(L);
  /* private strict view for method lookup: the same closures, unreachable from Lua */
  lua_createtable(L, 0, 32);
  view = lua_gettop(L);
  for (i = 0; string_names[i]; i++) {
    lua_getfield(L, strv, string_names[i]);
    lua_setfield(L, view, string_names[i]);
  }
  /* fresh shared string metatable: keep the upstream operator metamethods */
  lua_newtable(L);
  fresh = lua_gettop(L);
  lua_pushliteral(L, "");
  if (lua_getmetatable(L, -1)) {
    int old = lua_gettop(L);
    lua_pushnil(L);
    while (lua_next(L, old)) {
      lua_pushvalue(L, -2);
      lua_pushvalue(L, -2);
      lua_rawset(L, fresh);
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
  }
  lua_pushvalue(L, view);
  lua_pushcclosure(L, string_index, 1);
  lua_setfield(L, fresh, "__index");
  lua_pushvalue(L, fresh);
  lua_setmetatable(L, -2); /* on the string "": replaces the shared string metatable */
  lua_settop(L, strv);
  set_unlisted_meta(L, strv, mt);
  lua_setfield(L, env, "string");
  lua_settop(L, mt);

  /* table */
  lua_pushcfunction(L, luaopen_table);
  lua_call(L, 0, 1);
  copy_library(L, "table", table_names);
  set_unlisted_meta(L, lua_gettop(L), mt);
  lua_setfield(L, env, "table");
  lua_settop(L, mt);

  /* math */
  lua_pushcfunction(L, luaopen_math);
  lua_call(L, 0, 1);
  copy_library(L, "math", math_names);
  set_unlisted_meta(L, lua_gettop(L), mt);
  lua_setfield(L, env, "math");
  lua_settop(L, mt);

  /* helpers: a fresh table with the same strict lookup as the libraries */
  lua_newtable(L);
  lua_pushlightuserdata(L, &null_sentinel);
  lua_setfield(L, -2, "null");
  lua_pushcfunction(L, h_json_decode);
  lua_setfield(L, -2, "json_decode");
  lua_pushcfunction(L, h_json_encode);
  lua_setfield(L, -2, "json_encode");
  lua_pushcfunction(L, h_object);
  lua_setfield(L, -2, "object");
  lua_pushcfunction(L, h_text_split);
  lua_setfield(L, -2, "text_split");
  lua_pushcfunction(L, h_text_trim);
  lua_setfield(L, -2, "text_trim");
  lua_pushcfunction(L, h_text_utf8_len);
  lua_setfield(L, -2, "text_utf8_len");
  lua_pushcfunction(L, h_time_iso8601);
  lua_setfield(L, -2, "time_iso8601");
  lua_pushcfunction(L, h_time_parts);
  lua_setfield(L, -2, "time_parts");
  lua_pushcfunction(L, h_time_unix_ms);
  lua_setfield(L, -2, "time_unix_ms");
  set_unlisted_meta(L, lua_gettop(L), mt);
  lua_setfield(L, env, "helpers");
  lua_settop(L, mt);

  /* the environment itself: strict missing-global lookup */
  set_unlisted_meta(L, env, mt);
  lua_pushvalue(L, env);
  lua_rawseti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);

  /* host-private kind records for decoded tables (weak keys, unreachable) */
  lua_newtable(L);
  lua_newtable(L);
  lua_pushliteral(L, "k");
  lua_setfield(L, -2, "__mode");
  lua_setmetatable(L, -2);
  lua_setfield(L, LUA_REGISTRYINDEX, "elzoo.kinds");
  return 0;
}

/* ------------------------------------------------------------------ */
/* Plain data: tree -> Lua                                                */
/* ------------------------------------------------------------------ */

static int push_node(lua_State *L, long id) {
  node *nd = &nodes[id];
  long c;
  luaL_checkstack(L, 8, "plain data");
  switch (nd->type) {
    case T_NULL: lua_pushlightuserdata(L, &null_sentinel); return 0;
    case T_FALSE: lua_pushboolean(L, 0); return 0;
    case T_TRUE: lua_pushboolean(L, 1); return 0;
    case T_INT: lua_pushinteger(L, (lua_Integer)nd->i); return 0;
    case T_FLOAT: lua_pushnumber(L, (lua_Number)nd->d); return 0;
    case T_STR: lua_pushlstring(L, sarena + nd->soff, nd->slen); return 0;
    case T_ARR:
    case T_OBJ: {
      int is_arr = nd->type == T_ARR;
      lua_Integer i = 1;
      lua_createtable(L, is_arr ? (int)nd->count : 0, is_arr ? 0 : (int)nd->count);
      mark_kind(L, is_arr ? 1 : 2);
      for (c = nd->first; c >= 0; c = nodes[c].next) {
        if (is_arr) {
          push_node(L, c);
          lua_rawseti(L, -2, i++);
        } else {
          lua_pushlstring(L, sarena + nodes[c].koff, nodes[c].klen);
          push_node(L, c);
          lua_rawset(L, -3);
        }
      }
      return 0;
    }
    default: return 0;
  }
}

static int push_input_cf(lua_State *L) {
  long id = (long)(intptr_t)lua_touserdata(L, 1);
  lua_settop(L, 0);
  push_node(L, id);
  return 1;
}

/* ------------------------------------------------------------------ */
/* Plain data: Lua -> JSON                                                */
/* ------------------------------------------------------------------ */

static int enc_status;

/* The JSON text of one ASCII byte (c < 0x80) in e (at least 8 bytes); its length. */
static size_t esc_byte(unsigned char c, char *e) {
  switch (c) {
    case '"': memcpy(e, "\\\"", 2); return 2;
    case '\\': memcpy(e, "\\\\", 2); return 2;
    case '\b': memcpy(e, "\\b", 2); return 2;
    case '\f': memcpy(e, "\\f", 2); return 2;
    case '\n': memcpy(e, "\\n", 2); return 2;
    case '\r': memcpy(e, "\\r", 2); return 2;
    case '\t': memcpy(e, "\\t", 2); return 2;
    default:
      if (c < 0x20) {
        snprintf(e, 8, "\\u%04x", c);
        return 6;
      }
      e[0] = (char)c;
      return 1;
  }
}

static int enc_string(buf *B, const char *s, size_t n) {
  size_t i = 0;
  int rc;
  if ((rc = PUT(B, "\"")) != E_OK) return rc;
  while (i < n) {
    unsigned char c = (unsigned char)s[i];
    if (c < 0x80) {
      char e[8];
      size_t el = esc_byte(c, e);
      if ((rc = buf_put(B, e, el)) != E_OK) return rc;
      i++;
    } else {
      int l = utf8_len((const unsigned char *)s + i, n - i);
      if (l == 0) return E_INVALID;
      if ((rc = buf_put(B, s + i, (size_t)l)) != E_OK) return rc;
      i += (size_t)l;
    }
  }
  return PUT(B, "\"");
}

typedef struct {
  const char *p;
  size_t n;
} keyref;

static int cmp_keyref(const void *a, const void *b) {
  const keyref *x = (const keyref *)a, *y = (const keyref *)b;
  size_t m = x->n < y->n ? x->n : y->n;
  int c = memcmp(x->p, y->p, m);
  if (c) return c;
  return x->n < y->n ? -1 : (x->n > y->n ? 1 : 0);
}

static int enc_value(lua_State *L, int idx, int depth, buf *B);

static int enc_table(lua_State *L, int idx, int depth, buf *B) {
  lua_Integer nint = 0, maxk = 0, i;
  size_t nstr = 0, k = 0;
  int kind = 0, rc, is_array;
  keyref *keys = NULL;
  if (depth + 1 > MAX_CONTAINERS) return E_INVALID;
  if (!lua_checkstack(L, 8)) return E_INVALID;
  idx = lua_absindex(L, idx);
  lua_getfield(L, LUA_REGISTRYINDEX, "elzoo.kinds");
  lua_pushvalue(L, idx);
  lua_rawget(L, -2);
  if (lua_isinteger(L, -1)) kind = (int)lua_tointeger(L, -1);
  lua_pop(L, 2);
  lua_pushnil(L);
  while (lua_next(L, idx)) {
    /* helper mode: one step for each entry, and the bytes of a string key (value_bytes at most) */
    if (B->L) charge(L, 1);
    if (lua_type(L, -2) == LUA_TSTRING) {
      nstr++;
      if (B->L) charge(L, (long long)lua_rawlen(L, -2));
    } else if (lua_isinteger(L, -2)) {
      lua_Integer key = lua_tointeger(L, -2);
      if (key < 1) {
        lua_pop(L, 2);
        return E_INVALID;
      }
      nint++;
      if (key > maxk) maxk = key;
    } else {
      lua_pop(L, 2);
      return E_INVALID;
    }
    lua_pop(L, 1);
    if (nint > 0 && nstr > 0) {
      lua_pop(L, 1);
      return E_INVALID;
    }
  }
  if (nint > 0) {
    if (maxk != nint) return E_INVALID; /* holes */
    is_array = 1;
  } else if (nstr > 0) {
    is_array = 0;
  } else {
    is_array = kind != 2;
  }
  if (kind == 1 && !is_array) return E_INVALID;
  if (kind == 2 && is_array && nint > 0) return E_INVALID;
  if (is_array) {
    if ((rc = PUT(B, "[")) != E_OK) return rc;
    for (i = 1; i <= nint; i++) {
      if (i > 1 && (rc = PUT(B, ",")) != E_OK) return rc;
      lua_rawgeti(L, idx, i);
      rc = enc_value(L, lua_gettop(L), depth + 1, B);
      lua_pop(L, 1);
      if (rc != E_OK) return rc;
    }
    return PUT(B, "]");
  }
  /* object: at least 5 bytes per member, so more members than that cannot fit */
  if (nstr > (B->limit / 5) + 1) return E_SIZE;
  /* helper mode: the sorted keys live in a userdata (Lua memory, freed by an error too) */
  if (B->L)
    keys = (keyref *)lua_newuserdatauv(L, (nstr ? nstr : 1) * sizeof(keyref), 0);
  else
    keys = (keyref *)xrealloc(NULL, (nstr ? nstr : 1) * sizeof(keyref));
  lua_pushnil(L);
  while (lua_next(L, idx)) {
    keys[k].p = lua_tolstring(L, -2, &keys[k].n);
    k++;
    lua_pop(L, 1);
  }
  qsort(keys, nstr, sizeof(keyref), cmp_keyref);
  rc = PUT(B, "{");
  for (k = 0; rc == E_OK && k < nstr; k++) {
    if (k > 0 && (rc = PUT(B, ",")) != E_OK) break;
    if ((rc = enc_string(B, keys[k].p, keys[k].n)) != E_OK) break;
    if ((rc = PUT(B, ":")) != E_OK) break;
    lua_pushlstring(L, keys[k].p, keys[k].n);
    lua_rawget(L, idx);
    rc = enc_value(L, lua_gettop(L), depth + 1, B);
    lua_pop(L, 1);
  }
  if (B->L)
    lua_pop(L, 1);
  else
    free(keys);
  if (rc != E_OK) return rc;
  return PUT(B, "}");
}

static int enc_value(lua_State *L, int idx, int depth, buf *B) {
  char tmp[64];
  switch (lua_type(L, idx)) {
    case LUA_TNIL: return PUT(B, "null");
    case LUA_TBOOLEAN: return lua_toboolean(L, idx) ? PUT(B, "true") : PUT(B, "false");
    case LUA_TNUMBER:
      if (lua_isinteger(L, idx)) {
        int n = snprintf(tmp, sizeof tmp, "%lld", (long long)lua_tointeger(L, idx));
        return buf_put(B, tmp, (size_t)n);
      } else {
        lua_Number d = lua_tonumber(L, idx);
        if (!isfinite(d)) return E_INVALID;
        return buf_put(B, tmp, fmt_float(d, tmp));
      }
    case LUA_TSTRING: {
      size_t n;
      const char *s = lua_tolstring(L, idx, &n);
      if (B->L) charge(B->L, (long long)n); /* n is at most value_bytes */
      return enc_string(B, s, n);
    }
    case LUA_TTABLE: return enc_table(L, idx, depth, B);
    case LUA_TLIGHTUSERDATA:
      if (lua_touserdata(L, idx) == &null_sentinel) return PUT(B, "null");
      return E_INVALID;
    default: return E_INVALID;
  }
}

static buf outbuf;

static int encode_cf(lua_State *L) {
  enc_status = enc_value(L, 1, 0, &outbuf);
  return 0;
}

/* ------------------------------------------------------------------ */
/* Environment audit (argv only; no path from Lua)                       */
/* ------------------------------------------------------------------ */

static int cmp_str(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

static void audit_add(buf *B, const char *name, const char *typ, int *first) {
  char tmp[160];
  int n = snprintf(tmp, sizeof tmp, "%s\"%s\":\"%s\"", *first ? "" : ",", name, typ);
  *first = 0;
  buf_put(B, tmp, (size_t)n);
}

typedef struct {
  char *name;
  char *typ;
} auditrow;

static auditrow *rows;
static size_t nrows, rcap;

static void row(const char *prefix, const char *name, const char *typ) {
  char full[160];
  if (nrows == rcap) {
    rcap = rcap ? rcap * 2 : 64;
    rows = (auditrow *)xrealloc(rows, rcap * sizeof(auditrow));
  }
  snprintf(full, sizeof full, "%s%s", prefix, name);
  rows[nrows].name = strdup(full);
  rows[nrows].typ = strdup(typ);
  nrows++;
}

static int cmp_row(const void *a, const void *b) {
  return strcmp(((const auditrow *)a)->name, ((const auditrow *)b)->name);
}

static void audit_table(lua_State *L, int idx, const char *prefix, buf *consts, int *cfirst) {
  idx = lua_absindex(L, idx);
  lua_pushnil(L);
  while (lua_next(L, idx)) {
    const char *k = lua_tostring(L, -2);
    int t = lua_type(L, -1);
    row(prefix, k, lua_typename(L, t));
    if (t == LUA_TNUMBER) {
      char tmp[128], v[64];
      int n;
      if (lua_isinteger(L, -1))
        snprintf(v, sizeof v, "%lld", (long long)lua_tointeger(L, -1));
      else
        snprintf(v, sizeof v, "%.17g", (double)lua_tonumber(L, -1));
      n = snprintf(tmp, sizeof tmp, "%s\"%s%s\":\"%s\"", *cfirst ? "" : ",", prefix, k, v);
      *cfirst = 0;
      buf_put(consts, tmp, (size_t)n);
    }
    lua_pop(L, 1);
  }
}

static void audit_keys(lua_State *L, int idx, buf *B) {
  char **names = NULL;
  size_t n = 0, cap = 0, i;
  idx = lua_absindex(L, idx);
  lua_pushnil(L);
  while (lua_next(L, idx)) {
    if (n == cap) {
      cap = cap ? cap * 2 : 16;
      names = (char **)xrealloc(names, cap * sizeof(char *));
    }
    names[n++] = strdup(lua_tostring(L, -2));
    lua_pop(L, 1);
  }
  qsort(names, n, sizeof(char *), cmp_str);
  PUT(B, "[");
  for (i = 0; i < n; i++) {
    if (i) PUT(B, ",");
    PUT(B, "\"");
    buf_put(B, names[i], strlen(names[i]));
    PUT(B, "\"");
  }
  PUT(B, "]");
}

static int audit_cf(lua_State *L) {
  buf out = {0, 0, 0, 1u << 20, NULL}, consts = {0, 0, 0, 1u << 20, NULL}, names = {0, 0, 0, 1u << 20, NULL};
  int cfirst = 1, first = 1, env;
  size_t i;
  const char *libs[] = {"string", "table", "math", "helpers"};
  lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
  env = lua_gettop(L);
  audit_table(L, env, "", &consts, &cfirst);
  for (i = 0; i < 4; i++) {
    char prefix[16];
    lua_getfield(L, env, libs[i]);
    snprintf(prefix, sizeof prefix, "%s.", libs[i]);
    audit_table(L, -1, prefix, &consts, &cfirst);
    lua_pop(L, 1);
  }
  qsort(rows, nrows, sizeof(auditrow), cmp_row);
  PUT(&names, "{");
  for (i = 0; i < nrows; i++) audit_add(&names, rows[i].name, rows[i].typ, &first);
  PUT(&names, "}");
  PUT(&out, "{\"constants\":{");
  buf_put(&out, consts.b ? consts.b : "", consts.n);
  PUT(&out, "},\"environment_metatable\":");
  lua_getmetatable(L, env);
  audit_keys(L, -1, &out);
  lua_pop(L, 1);
  PUT(&out, ",\"helpers_metatable\":");
  lua_getfield(L, env, "helpers");
  lua_getmetatable(L, -1);
  audit_keys(L, -1, &out);
  lua_pop(L, 2);
  PUT(&out, ",\"library_metatable\":");
  lua_getfield(L, env, "string");
  lua_getmetatable(L, -1);
  audit_keys(L, -1, &out);
  lua_pop(L, 2);
  PUT(&out, ",\"names\":");
  buf_put(&out, names.b, names.n);
  PUT(&out, ",\"string_metatable\":");
  lua_pushliteral(L, "");
  lua_getmetatable(L, -1);
  audit_keys(L, -1, &out);
  lua_pop(L, 2);
  PUT(&out, "}");
  write_frame(out.b, out.n);
  return 0;
}

/* ------------------------------------------------------------------ */
/* Main                                                                  */
/* ------------------------------------------------------------------ */

static size_t read_full(int fd, unsigned char *b, size_t n) {
  size_t got = 0;
  while (got < n) {
    ssize_t r = read(fd, b + got, n - got);
    if (r < 0) {
      if (errno == EINTR) continue;
      return got;
    }
    if (r == 0) return got;
    got += (size_t)r;
  }
  return got;
}

static lua_State *new_state(void) {
  lua_State *L = lua_newstate(host_alloc, NULL);
  if (!L) {
    if (G.sticky) reply_sticky();
    _exit(70);
  }
  lua_atpanic(L, panic);
  return L;
}

static void init_state(lua_State *L) {
  lua_pushcfunction(L, init_env);
  if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
    if (G.sticky) reply_sticky();
    _exit(70);
  }
}

static int field_int(long obj, const char *name, long long maxv, long long *out) {
  long c;
  for (c = nodes[obj].first; c >= 0; c = nodes[c].next) {
    if (strlen(name) == nodes[c].klen && memcmp(sarena + nodes[c].koff, name, nodes[c].klen) == 0) {
      if (nodes[c].type != T_INT || nodes[c].i < 1 || nodes[c].i > maxv) return -1;
      *out = nodes[c].i;
      return 0;
    }
  }
  return -1;
}

static long field_node(long obj, const char *name) {
  long c;
  for (c = nodes[obj].first; c >= 0; c = nodes[c].next)
    if (strlen(name) == nodes[c].klen && memcmp(sarena + nodes[c].koff, name, nodes[c].klen) == 0) return c;
  return -1;
}

enum { MODE_NONE, MODE_DATA, MODE_REPLAY };
static int calls_mode;
static long calls_names; /* node index of the `names` array */
static long calls_recorded; /* node index of the `recorded` array */
static long nrecorded;

static int node_is(long id, const char *s) {
  return (size_t)strlen(s) == nodes[id].slen && memcmp(sarena + nodes[id].soff, s, nodes[id].slen) == 0;
}

static int valid_name(long id) {
  size_t i, n = nodes[id].slen;
  const char *p = sarena + nodes[id].soff;
  if (nodes[id].type != T_STR || n < 1 || n > 64 || p[0] < 'a' || p[0] > 'z') return 0;
  for (i = 1; i < n; i++)
    if (!((p[i] >= 'a' && p[i] <= 'z') || (p[i] >= '0' && p[i] <= '9') || p[i] == '_')) return 0;
  return 1;
}

static int name_listed(long names, long id) {
  long c;
  for (c = nodes[names].first; c >= 0; c = nodes[c].next)
    if (nodes[c].slen == nodes[id].slen && memcmp(sarena + nodes[c].soff, sarena + nodes[id].soff, nodes[id].slen) == 0)
      return 1;
  return 0;
}

/* The number of nested containers of the node (0 for a scalar); the parser bounds the nesting. */
static int node_depth(long id) {
  long c;
  int d, best = 0;
  if (nodes[id].type != T_ARR && nodes[id].type != T_OBJ) return 0;
  for (c = nodes[id].first; c >= 0; c = nodes[c].next) {
    d = node_depth(c);
    if (d > best) best = d;
  }
  return best + 1;
}

/* The shape of `calls` (0 valid, -1 invalid); reads only the node arena, by index. */
static int check_calls(long calls) {
  long mode, names, rec, c, d;
  if (calls < 0 || nodes[calls].type != T_OBJ || nodes[calls].count != 3) return -1;
  mode = field_node(calls, "mode");
  names = field_node(calls, "names");
  rec = field_node(calls, "recorded");
  if (mode < 0 || names < 0 || rec < 0 || nodes[mode].type != T_STR || nodes[names].type != T_ARR ||
      nodes[rec].type != T_ARR || nodes[names].count > 64 || nodes[rec].count > 256)
    return -1;
  if (node_is(mode, "none")) calls_mode = MODE_NONE;
  else if (node_is(mode, "data")) calls_mode = MODE_DATA;
  else if (node_is(mode, "replay")) calls_mode = MODE_REPLAY;
  else return -1;
  calls_names = names;
  calls_recorded = rec;
  nrecorded = (long)nodes[rec].count;
  for (c = nodes[names].first; c >= 0; c = nodes[c].next) {
    if (!valid_name(c)) return -1;
    for (d = nodes[names].first; d != c; d = nodes[d].next)
      if (nodes[d].slen == nodes[c].slen && memcmp(sarena + nodes[d].soff, sarena + nodes[c].soff, nodes[c].slen) == 0)
        return -1;
  }
  if (calls_mode == MODE_NONE && (nodes[names].count != 0 || nodes[rec].count != 0)) return -1;
  if (calls_mode == MODE_DATA && nodes[rec].count != 0) return -1;
  for (c = nodes[rec].first; c >= 0; c = nodes[c].next) {
    long nm, ar, re;
    if (nodes[c].type != T_OBJ || nodes[c].count != 3) return -1;
    nm = field_node(c, "name");
    ar = field_node(c, "arguments");
    re = field_node(c, "result");
    if (nm < 0 || ar < 0 || re < 0 || nodes[nm].type != T_STR || !name_listed(names, nm)) return -1;
    if (node_depth(ar) > MAX_CONTAINERS || node_depth(re) > MAX_CONTAINERS) return -1;
  }
  return 0;
}

/* ------------------------------------------------------------------ */
/* Bindings: the global `bindings` of the modes data and replay          */
/* ------------------------------------------------------------------ */

/* Two host buffers of their own (L == NULL: they grow by realloc, charge nothing,
** and stay valid for the whole run; they are never freed and never raise). The
** argument of a call is encoded into argbuf (limit value_bytes); the measure of the
** value that a call returns goes into retbuf (no limit). Neither is outbuf. */
static buf argbuf, retbuf, cmpbuf, pendbuf;
static long call_count;  /* binding calls so far, over the chunk and the function */
static long next_record; /* node index of the record that the next call must match */
static long pending_index;
static long pending_name; /* node index of the name of the pending call */

/* The reply of the pending stop: the call that has no recorded result. Sorted keys. */
__attribute__((noreturn)) static void reply_pending(void) {
  buf r = {0, 0, 0, SIZE_MAX, NULL};
  char tmp[32];
  int n = snprintf(tmp, sizeof tmp, "%ld", pending_index);
  PUT(&r, "{\"call\":{\"arguments\":");
  buf_put(&r, pendbuf.b ? pendbuf.b : "null", pendbuf.n);
  PUT(&r, ",\"index\":");
  buf_put(&r, tmp, (size_t)n);
  PUT(&r, ",\"name\":\"");
  buf_put(&r, sarena + nodes[pending_name].soff, nodes[pending_name].slen);
  PUT(&r, "\"},\"status\":\"pending\"}");
  write_frame(r.b, r.n);
  _exit(0);
}

/* Push a deep copy of the plain value at idx. The value already encoded without an
** error, so it holds only nil, booleans, numbers, strings, the null sentinel and
** tables of at most 32 nested containers. Tables are read with lua_next and written
** with lua_rawset only; the kind record (array or object) moves to the copy. */
static void copy_plain(lua_State *L, int idx) {
  idx = lua_absindex(L, idx);
  luaL_checkstack(L, 8, "bindings");
  switch (lua_type(L, idx)) {
    case LUA_TNIL: lua_pushlightuserdata(L, &null_sentinel); return;
    case LUA_TTABLE: {
      int dst;
      lua_createtable(L, 0, 0);
      dst = lua_gettop(L);
      lua_getfield(L, LUA_REGISTRYINDEX, "elzoo.kinds");
      lua_pushvalue(L, idx);
      lua_rawget(L, -2);
      if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
      } else {
        lua_pushvalue(L, dst);
        lua_insert(L, -2);
        lua_rawset(L, -3);
      }
      lua_pop(L, 1);
      lua_pushnil(L);
      while (lua_next(L, idx)) {
        lua_pushvalue(L, -2);
        copy_plain(L, -2);
        lua_rawset(L, dst);
        lua_pop(L, 1);
      }
      return;
    }
    default: lua_pushvalue(L, idx); return;
  }
}

/* bindings.<name>(value): the upvalue is the node index of the name. */
static int b_call(lua_State *L) {
  long id = (long)lua_tointeger(L, lua_upvalueindex(1));
  int rc;
  if (G.sticky) return stop_raise(L);
  if (lua_gettop(L) != 1) return luaL_error(L, "bindings: expected one value");
  argbuf.n = 0;
  argbuf.limit = G.value_bytes;
  rc = enc_value(L, 1, 0, &argbuf);
  if (rc == E_SIZE) {
    set_sticky(STOP_VALUE);
    return stop_raise(L);
  }
  if (rc != E_OK) return luaL_error(L, "bindings: value is not plain data");
  charge(L, (long long)argbuf.n); /* one step for each byte; argbuf.n is at most value_bytes */
  if (calls_mode == MODE_REPLAY) {
    long nm, ar, re;
    if (call_count >= nrecorded) {
      /* no recorded result: keep the call and end the run (the first stop wins) */
      pending_index = call_count;
      pending_name = id;
      pendbuf.n = 0;
      pendbuf.limit = SIZE_MAX;
      buf_put(&pendbuf, argbuf.b ? argbuf.b : "", argbuf.n);
      set_sticky(STOP_PENDING);
      return stop_raise(L);
    }
    nm = field_node(next_record, "name");
    ar = field_node(next_record, "arguments");
    re = field_node(next_record, "result");
    if (nodes[nm].slen != nodes[id].slen || memcmp(sarena + nodes[nm].soff, sarena + nodes[id].soff, nodes[id].slen) != 0) {
      set_sticky(STOP_MISMATCH);
      return stop_raise(L);
    }
    /* the compare rule: push the recorded argument as a Lua value, encode it with the
    ** one canonical writer, and compare the bytes with the encoding of this call */
    cmpbuf.n = 0;
    cmpbuf.limit = SIZE_MAX;
    push_node(L, ar);
    rc = enc_value(L, lua_gettop(L), 0, &cmpbuf);
    lua_pop(L, 1);
    if (rc != E_OK || cmpbuf.n != argbuf.n || (argbuf.n > 0 && memcmp(cmpbuf.b, argbuf.b, argbuf.n) != 0)) {
      set_sticky(STOP_MISMATCH);
      return stop_raise(L);
    }
    call_count++;
    next_record = nodes[next_record].next;
    push_node(L, re);
    retbuf.n = 0;
    retbuf.limit = SIZE_MAX;
    rc = enc_value(L, lua_gettop(L), 0, &retbuf);
    if (rc != E_OK) return luaL_error(L, "bindings: value is not plain data");
    charge(L, (long long)retbuf.n);
    return 1;
  }
  /* mode data */
  lua_createtable(L, 0, 2);
  mark_kind(L, 2);
  lua_pushliteral(L, "arguments");
  copy_plain(L, 1);
  lua_rawset(L, -3);
  lua_pushliteral(L, "binding");
  lua_pushlstring(L, sarena + nodes[id].soff, nodes[id].slen);
  lua_rawset(L, -3);
  /* the returned value is charged one step for each byte of its canonical JSON; it
  ** wraps an argument of up to 32 containers, so the measure starts one level up */
  retbuf.n = 0;
  retbuf.limit = SIZE_MAX;
  rc = enc_value(L, lua_gettop(L), -1, &retbuf);
  if (rc != E_OK) return luaL_error(L, "bindings: value is not plain data");
  charge(L, (long long)retbuf.n);
  return 1;
}

/* Build the global `bindings` in the environment table (the registry global table):
** a fresh table with one closure for each name and the strict lookup of the library
** tables (the metatable of `helpers`). Raw access only. */
static int bindings_cf(lua_State *L) {
  long c;
  int tbl, env;
  luaL_checkstack(L, 8, "bindings");
  lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
  env = lua_gettop(L);
  lua_createtable(L, 0, (int)nodes[calls_names].count);
  tbl = lua_gettop(L);
  for (c = nodes[calls_names].first; c >= 0; c = nodes[c].next) {
    lua_pushlstring(L, sarena + nodes[c].soff, nodes[c].slen);
    lua_pushinteger(L, (lua_Integer)c);
    lua_pushcclosure(L, b_call, 1);
    lua_rawset(L, tbl);
  }
  lua_pushliteral(L, "helpers");
  lua_rawget(L, env);
  if (!lua_getmetatable(L, -1)) return luaL_error(L, "bindings: no strict lookup");
  lua_setmetatable(L, tbl);
  lua_pushliteral(L, "bindings");
  lua_pushvalue(L, tbl);
  lua_rawset(L, env);
  return 0;
}

static void init_bindings(lua_State *L) {
  lua_pushcfunction(L, bindings_cf);
  if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
    if (G.sticky) reply_sticky();
    _exit(70);
  }
}

int main(int argc, char **argv) {
  int dn = open("/dev/null", O_WRONLY);
  unsigned char hdr[4], *body;
  size_t len;
  long root, src, inp, pol, lim, cal;
  long long steps, depth, value, memory, wall;
  lua_State *L;
  int st, base;
  struct itimerval it;
  size_t srclen;

  if (dn >= 0 && dn != 2) {
    dup2(dn, 2);
    close(dn);
  }
  signal(SIGALRM, SIG_DFL);
  signal(SIGPIPE, SIG_DFL);

  if (argc == 2 && strcmp(argv[1], "--audit") == 0) {
    G.mem_limit = SIZE_MAX;
    G.value_bytes = MAX_VALUE;
    L = new_state();
    init_state(L);
    lua_pushcfunction(L, audit_cf);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) _exit(70);
    _exit(0);
  }
  if (argc != 1) _exit(64);

  if (read_full(0, hdr, 4) != 4) _exit(65);
  len = (size_t)hdr[0] | ((size_t)hdr[1] << 8) | ((size_t)hdr[2] << 16) | ((size_t)hdr[3] << 24);
  if (len == 0 || len > FRAME_MAX) _exit(65);
  body = (unsigned char *)xrealloc(NULL, len);
  if (read_full(0, body, len) != len) _exit(65);

  root = parse_document(body, len);
  if (root < 0 || nodes[root].type != T_OBJ || nodes[root].count != 5) reply_refused("invalid_request");
  src = field_node(root, "source");
  inp = field_node(root, "input");
  pol = field_node(root, "policy");
  lim = field_node(root, "limits");
  cal = field_node(root, "calls");
  if (src < 0 || inp < 0 || pol < 0 || lim < 0 || cal < 0 || nodes[src].type != T_STR || nodes[pol].type != T_STR ||
      nodes[lim].type != T_OBJ || nodes[lim].count != 5 || nodes[src].slen > MAX_SOURCE)
    reply_refused("invalid_request");
  if (nodes[pol].slen != strlen(ELZ_POLICY_IDENTITY) ||
      memcmp(sarena + nodes[pol].soff, ELZ_POLICY_IDENTITY, nodes[pol].slen) != 0)
    reply_refused("policy_mismatch");
  if (field_int(lim, "steps", MAX_STEPS, &steps) || field_int(lim, "call_depth", MAX_DEPTH, &depth) ||
      field_int(lim, "value_bytes", MAX_VALUE, &value) || field_int(lim, "memory_bytes", MAX_MEMORY, &memory) ||
      field_int(lim, "wall_ms", MAX_WALL, &wall))
    reply_refused("invalid_request");
  if (check_calls(cal) < 0 || node_depth(inp) > MAX_CONTAINERS) reply_refused("invalid_request");

  G.mem_limit = (size_t)memory;
  G.value_bytes = (size_t)value;
  G.steps_limit = steps;
  G.depth_limit = depth;

  /* self-termination backstop: the caller's deadline is the guarantee */
  memset(&it, 0, sizeof it);
  it.it_value.tv_sec = (wall + 250) / 1000;
  it.it_value.tv_usec = ((wall + 250) % 1000) * 1000;
  setitimer(ITIMER_REAL, &it, NULL);

  L = new_state();
  init_state(L);
  if (calls_mode != MODE_NONE) init_bindings(L);
  if (calls_mode == MODE_REPLAY) next_record = nodes[calls_recorded].first;
  base = lua_gettop(L);

  /* arm the limits: no user code has run yet */
  G.armed = 1;
  lua_sethook(L, hook, LUA_MASKCOUNT | LUA_MASKCALL | LUA_MASKRET, 1);

  srclen = nodes[src].slen;
  st = luaL_loadbufferx(L, sarena + nodes[src].soff, srclen, "=lua", "t");
  if (G.sticky) reply_sticky();
  if (st != LUA_OK) reply_refused("lua_error");
  st = lua_pcall(L, 0, LUA_MULTRET, 0);
  if (G.sticky) reply_sticky();
  if (st != LUA_OK) reply_refused("lua_error");
  if (lua_gettop(L) != base + 1 || !lua_isfunction(L, -1)) reply_refused("invalid_result");

  lua_pushcfunction(L, push_input_cf);
  lua_pushlightuserdata(L, (void *)(intptr_t)inp);
  st = lua_pcall(L, 1, 1, 0);
  if (G.sticky) reply_sticky();
  if (st != LUA_OK) _exit(70);
  G.depth = 0;
  st = lua_pcall(L, 1, LUA_MULTRET, 0);
  if (G.sticky) reply_sticky();
  if (st != LUA_OK) reply_refused("lua_error");
  if (lua_gettop(L) != base + 1) reply_refused("invalid_result");
  /* a record that the source did not ask for is a different run */
  if (calls_mode == MODE_REPLAY && call_count < nrecorded) reply_refused("call_mismatch");

  outbuf.limit = G.value_bytes;
  lua_pushcfunction(L, encode_cf);
  lua_insert(L, -2);
  st = lua_pcall(L, 1, 0, 0);
  if (G.sticky) reply_sticky();
  if (st != LUA_OK) _exit(70);
  if (enc_status == E_SIZE) reply_refused("value_size");
  if (enc_status != E_OK) reply_refused("invalid_result");
  {
    buf r = {0, 0, 0, SIZE_MAX, NULL};
    PUT(&r, "{\"runtime\":" RUNTIME_JSON ",\"status\":\"ok\",\"value\":");
    buf_put(&r, outbuf.b ? outbuf.b : "null", outbuf.n);
    PUT(&r, "}");
    write_frame(r.b, r.n);
  }
  _exit(0);
}
