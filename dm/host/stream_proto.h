#pragma once
#include <stdint.h>
#include <string.h>

enum { DMS_VERSION = 1, DMS_HEADER = 16, DMS_MAX_PAYLOAD = 8 << 20, DMS_SUN_PATH_MAX = 103 };

enum {
    DMS_HELLO = 1, DMS_VIDEO_CONFIG = 2, DMS_VIDEO_FRAME = 3, DMS_AUDIO = 4, DMS_STATS = 5, DMS_RUMBLE = 6, DMS_ATTACH_RESULT = 7,
    DMS_ATTACH = 16, DMS_DETACH = 17, DMS_PAD = 18, DMS_LTR_ACK = 19, DMS_REFRESH = 20, DMS_BITRATE = 21, DMS_PADS = 22,
};

enum { DMS_FRAME_SYNC = 1 << 0, DMS_FRAME_REFRESH = 1 << 1 };
enum { DMS_DETACH_PAUSE = 1 << 0 };
enum { DMS_PAD_MOTION = 1 << 0 };
enum { DMS_STYLE_PRO = 1 };

#define DMS_AVC1 0x61766331u
#define DMS_HVC1 0x68766331u

typedef struct { uint32_t length; uint16_t type, flags; uint64_t sent_ns; } dms_header;
_Static_assert(sizeof(dms_header) == DMS_HEADER, "the wire header is 16 bytes");

typedef struct { uint8_t *p, *end; int bad; } dms_reader;

static inline void dms_put(uint8_t **w, const void *v, size_t n) { memcpy(*w, v, n); *w += n; }
static inline void dms_put8(uint8_t **w, uint8_t v) { dms_put(w, &v, 1); }
static inline void dms_put16(uint8_t **w, uint16_t v) { dms_put(w, &v, 2); }
static inline void dms_put32(uint8_t **w, uint32_t v) { dms_put(w, &v, 4); }
static inline void dms_put64(uint8_t **w, uint64_t v) { dms_put(w, &v, 8); }

static inline void dms_get(dms_reader *r, void *v, size_t n) {
    if (r->bad || (size_t)(r->end - r->p) < n) { r->bad = 1; memset(v, 0, n); return; }
    memcpy(v, r->p, n); r->p += n;
}
static inline uint8_t dms_get8(dms_reader *r) { uint8_t v; dms_get(r, &v, 1); return v; }
static inline uint16_t dms_get16(dms_reader *r) { uint16_t v; dms_get(r, &v, 2); return v; }
static inline uint32_t dms_get32(dms_reader *r) { uint32_t v; dms_get(r, &v, 4); return v; }
static inline uint64_t dms_get64(dms_reader *r) { uint64_t v; dms_get(r, &v, 8); return v; }
