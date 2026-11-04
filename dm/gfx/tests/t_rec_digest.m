#define NVN_REC_TAP 1
#include "../nvn/nvn_mtl.m"
#include "nvn_rec_digest.inc"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } else printf("ok: %s\n", label); } while (0)

typedef struct { uint8_t md[CC_SHA256_DIGEST_LENGTH]; uint64_t calls, objs, addrs, unres; } dg;
static int same(dg a, dg b) { return !memcmp(a.md, b.md, sizeof a.md); }
static dg take(void) { dg d; rdg_final(d.md); d.calls = g_rdg_calls; d.objs = g_rdg_nobj; d.addrs = g_rdg_addrs; d.unres = g_rdg_unres; return d; }
static id<MTLBuffer> buf(uint8_t v, int resident) {
    id<MTLBuffer> b = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared]; memset(b.contents, v, 4096);
    if (resident) { res_add(b); res_commit(); }
    return b;
}
static id<MTLTexture> target(NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; res_add(t); res_commit(); return t;
}
static dg copies(id<MTLBuffer> src, id<MTLBuffer> dst, uint8_t fill, uint64_t off, id<MTLBuffer> stray) {
    rdg_reset(NULL); mtl_sub_begin();
    id<MTL4ComputeCommandEncoder> e = blit_raw();
    enc_b_copy_buffer(e, src, 0, dst, 2048, 256);
    [e fillBuffer:dst range:NSMakeRange(1024, 64) value:fill];
    [g_ct setAddress:src.gpuAddress + off atIndex:3];
    if (stray) [g_ct setAddress:stray.gpuAddress atIndex:4];
    mtl_sub_commit(); mtl_finish();
    return take();
}
static dg one_addr(uint64_t a) {
    rdg_reset(NULL); mtl_sub_begin();
    [g_ct setAddress:a atIndex:3];
    mtl_sub_commit(); mtl_finish();
    return take();
}
static dg clear(id<MTLTexture> t, double red) {
    rdg_reset(NULL); mtl_sub_begin();
    MTL4RenderPassDescriptor *pd = [MTL4RenderPassDescriptor new];
    pd.colorAttachments[0].texture = t; pd.colorAttachments[0].loadAction = MTLLoadActionClear; pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    pd.colorAttachments[0].clearColor = MTLClearColorMake(red, 0.5, 0.25, 1); pd.renderTargetWidth = t.width; pd.renderTargetHeight = t.height;
    enc_r_end(enc_r_begin(pd));
    mtl_sub_commit(); mtl_finish();
    return take();
}
static int span_is(id<MTLBuffer> b, size_t lo, size_t hi, uint8_t v) { const uint8_t *p = b.contents; for (size_t i = lo; i < hi; i++) if (p[i] != v) return 0; return 1; }

int main(void) { @autoreleasepool {
    g_rec = 1; mtl_init();
    copies(buf(1, 1), buf(0, 1), 7, 256, nil);
    id<MTLBuffer> s1 = buf(1, 1), d1 = buf(0, 1), s2 = buf(1, 1), d2 = buf(0, 1);
    dg a = copies(s1, d1, 7, 256, nil), b = copies(s2, d2, 7, 256, nil);
    CHECK(a.calls > 0 && a.addrs > 0 && !a.unres, "a frame's calls and addresses are digested");
    CHECK(same(a, b) && a.calls == b.calls && a.objs == b.objs, "the same calls on other buffers, at other addresses, give the same digest");
    CHECK(span_is(d2, 0, 1024, 0) && span_is(d2, 1024, 1088, 7) && span_is(d2, 1088, 2048, 0) && span_is(d2, 2048, 2304, 1) && span_is(d2, 2304, 4096, 0), "the calls still reach Metal through the recorder");
    CHECK(!same(a, copies(buf(1, 1), buf(0, 1), 9, 256, nil)), "another fill value gives another digest");
    CHECK(!same(a, copies(buf(1, 1), buf(0, 1), 7, 512, nil)), "another offset in the same buffer gives another digest");
    id<MTLBuffer> s3 = buf(1, 1);
    CHECK(!same(a, copies(s3, s3, 7, 256, nil)), "one buffer in two roles is not two buffers");
    dg h = copies(buf(1, 1), buf(0, 1), 7, 256, buf(0, 0)), h2 = copies(buf(1, 1), buf(0, 1), 7, 256, buf(0, 0));
    CHECK(h.unres == 1 && same(h, h2) && !same(a, h), "an address in no resident buffer is counted and digested the same way each time");
    uint64_t xa = 0, off = 0; dg x1;
    @autoreleasepool { id<MTLBuffer> X = buf(2, 1); xa = X.gpuAddress; x1 = one_addr(xa); res_remove(X); res_commit(); }
    int listed = 0; for (size_t i = 0; i < g_rdg_ntab; i++) listed |= g_rdg_tab[i].lo == xa;
    int dropped = listed && !rdg_buf_at(xa, &off);
    NSMutableArray *held = [NSMutableArray array]; id<MTLBuffer> taker = nil;
    for (int i = 0; i < 4096 && !taker; i++) { id<MTLBuffer> n = buf(3, 0); if (n.gpuAddress == xa) taker = n; else [held addObject:n]; }
    if (taker) { res_add(taker); res_commit(); dg y1 = one_addr(xa);
        CHECK(dropped && x1.addrs == 1 && !x1.unres && !y1.unres && y1.objs == x1.objs && same(x1, y1), "a freed resident buffer's table entry is dropped, and a new buffer at its GPU address is found and named"); }
    else printf("skip: no new buffer took the freed buffer's GPU address\n");
    [held removeAllObjects];

    clear(target(16, 16), 1);
    id<MTLTexture> t2 = target(16, 16);
    dg c1 = clear(target(16, 16), 1), c2 = clear(t2, 1);
    CHECK(same(c1, c2), "the same render pass on another texture gives the same digest");
    uint8_t px[4] = {0}; [t2 getBytes:px bytesPerRow:16 * 4 fromRegion:MTLRegionMake2D(3, 5, 1, 1) mipmapLevel:0];
    CHECK(px[0] == 255 && (px[1] == 127 || px[1] == 128) && (px[2] == 63 || px[2] == 64) && px[3] == 255, "the render pass still reaches Metal through the recorder");
    CHECK(!same(c1, clear(target(16, 16), 0)), "another clear colour gives another digest");
    CHECK(!same(c1, clear(target(32, 16), 1)), "another texture size gives another digest");

    int fr, f1, f2; uint8_t md[CC_SHA256_DIGEST_LENGTH];
    rdg_reset(NULL);
    id A = [NSObject new], B = [NSObject new];
    uint32_t na = rdg_name(A, &f1), nb = rdg_name(B, &fr), na2 = rdg_name(A, &f2);
    CHECK(na == 1 && nb == 2 && na2 == 1 && f1 && !f2, "objects are named in the order they first appear");
    rdg_final(md); rdg_reset(NULL);
    uint32_t nb2 = rdg_name(B, &fr);
    CHECK(nb2 == 1 && fr, "names start again with each frame");
    rdg_final(md); rdg_reset(NULL);
    void *p = NULL; @autoreleasepool { id X = [NSObject new]; p = (__bridge void *)X; rdg_name(X, &fr); }
    NSMutableArray *keep = [NSMutableArray array]; id Y = nil;
    for (int i = 0; i < 100000 && !Y; i++) { id o = [NSObject new]; if ((__bridge void *)o == p) Y = o; else [keep addObject:o]; }
    if (Y) { uint32_t ny = rdg_name(Y, &fr); CHECK(ny == 2 && fr, "a new object at a dead object's address gets a new name"); }
    else printf("skip: no new object took the dead object's address\n");
    rdg_final(md);
    printf("t_rec_digest: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
