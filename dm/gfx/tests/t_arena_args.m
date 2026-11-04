#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static const uint8_t *block_of(NvShader *sh, int aid) {
    if (!sh->ab_buf) return NULL;
    const uint8_t *base = (const uint8_t *)sh->ab_buf.contents; uint64_t gpu = ((const uint64_t *)(base + sh->ab_off))[aid], lo = sh->ab_buf.gpuAddress;
    return gpu >= lo && gpu < lo + sh->ab_buf.length ? base + (gpu - lo) : NULL;
}
static void compute_case(NvShader *cs, id<MTLComputePipelineState> ps, int sid, uint32_t seed, const char *what) {
    int before = failed;
    state_reset(); memset(&R, 0, sizeof R);
    for (int i = 0; i < DMSH_PUSH_SIZE; i++) S.push[1][i] = (uint8_t)(seed * 31 + i * 7 + 1);
    S.ssbo[5][0].addr = 0x123456789aull + seed; S.ssbo[5][0].size = 0x40;
    S.tex[5][0] = 0x11 | 0x22ull << 20; S.tex[5][1] = (0x2aull + seed) | 0x13ull << 20;
    S.samp[5][0] = (uint64_t)sid << 20;
    g_dispatch_dim[0] = 3 + seed; g_dispatch_dim[1] = 5; g_dispatch_dim[2] = 7;
    id<MTLBuffer> out = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; res_add(out);
    mtl_sub_begin();
    id<MTL4ComputeCommandEncoder> en = enc_c_begin(NULL); args_dirty_all();
    CHECK(encode_args((id<MTLCommandEncoder>)en, cs, 5, 0), "%s: compute arguments encoded", what);
    CHECK(g_cur_arena->cpu == (uint8_t *)g_cur_arena->buf.contents, "%s: the arena's CPU pointer is its buffer's contents", what);
    CHECK(cs->ab_buf == g_cur_arena->buf && cs->ab_gpu == g_cur_arena->gpu + cs->ab_off, "%s: the argument block lies in the current arena", what);
    CHECK(g_ct_addr[0] == cs->ab_gpu, "%s: the compute table holds the argument block", what);
    uint64_t c0 = cs->ab_buf ? ((const uint64_t *)((const uint8_t *)cs->ab_buf.contents + cs->ab_off))[1] : 0;
    CHECK(g_c0_dim_buf == cs->ab_buf && g_c0_dim_buf.gpuAddress + g_c0_dim_off == c0 + DMSH_C0_DISPATCH, "%s: an indirect dispatch copies its counts into this c0 block", what);
    CHECK(g_sview_w[sid] != NULL, "%s: sampler %d has a border twin", what, sid);
    enc_c_args(en, out.gpuAddress, 1); enc_c_pso(en, ps); enc_c_dispatch(en, MTLSizeMake(1, 1, 1), MTLSizeMake(1, 1, 1)); enc_c_end(en);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "%s: GPU submission completed", what);
    CHECK(!mtl_last_commit_error(), "%s: GPU submission has no error", what);
    const uint8_t *o = (const uint8_t *)out.contents;
    CHECK(!memcmp(o, S.push[1], 16) && !memcmp(o + 16, S.push[1] + 240, 16), "%s: the GPU reads the push constants", what);
    uint32_t dim[4] = {3 + seed, 5, 7, 0}; CHECK(!memcmp(o + 32, dim, 16), "%s: the GPU reads the dispatch counts in c0", what);
    uint64_t a = S.ssbo[5][0].addr; uint32_t row[4] = {(uint32_t)a, (uint32_t)(a >> 32), 0x40, 0};
    CHECK(!memcmp(o + 48, row, 16), "%s: the GPU reads storage buffer 0 in c0", what);
    uint32_t c2[4] = {0x02200011, 0, (uint32_t)(0x2a + seed) | 0x13u << 20, 0}; CHECK(!memcmp(o + 64, c2, 16), "%s: the GPU reads texture handles 0 and 1 in c2", what);
    uint32_t mask[4] = {1, 0, 0, 0}; CHECK(!memcmp(o + 80, mask, 16), "%s: the GPU reads the border block's mask", what);
    float k[4]; os_unfair_lock_lock(&g_rmu); memcpy(k, g_sbk[sid], sizeof k); os_unfair_lock_unlock(&g_rmu);
    CHECK(!memcmp(o + 96, k, 16), "%s: the GPU reads the border block's factors", what);
    printf("arena compute, %s: %s\n", what, before == failed ? "PASS" : "FAIL");
}
static void reuse_case(NvShader *fs) {
    int before = failed; tex_t rt = {.magic=MAGIC('T','E','X',0), .serial=99901};
    rt.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8, .width=4, .height=4, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(&rt, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [g_dev newTextureWithDescriptor:d]; res_add(texture); mtl_tex_init(&rt); serial_put(rt.serial, texture);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &rt;
    CHECK(rp_begin() != nil, "render pass opens");
    args_dirty_all(); g_draw_binst = 7;
    uint64_t enc = g_stat_args_enc, reuse = g_stat_args_reuse; uint32_t v; float f;
    CHECK(encode_args((id<MTLCommandEncoder>)g_enc, fs, 1, 0), "fragment arguments encoded");
    uint64_t first = fs->ab_gpu; size_t used = g_cur_arena->used; const uint8_t *c0 = block_of(fs, 0);
    CHECK(g_stat_args_enc == enc + 1 && fs->ab_buf == g_cur_arena->buf && g_ft_addr[0] == first, "the first encode writes a block and binds it");
    CHECK(c0 && (memcpy(&f, c0 + DMSH_C0_POINT_SIZE, 4), f == 2047.0f), "the c0 block holds the largest point size");
    CHECK(c0 && (memcpy(&v, c0 + DMSH_C0_BASE_INSTANCE, 4), v == 7), "the c0 block holds base instance 7");
    enc_r_args(g_enc, MTLRenderStageFragment, first + 256, 0);
    CHECK(encode_args((id<MTLCommandEncoder>)g_enc, fs, 1, 0), "fragment arguments encoded again");
    CHECK(g_stat_args_reuse == reuse + 1 && g_stat_args_enc == enc + 1 && g_cur_arena->used == used && g_ft_addr[0] == first,
          "an unchanged encode in the same pass binds the same block again without allocating");
    g_draw_binst = 9;
    CHECK(encode_args((id<MTLCommandEncoder>)g_enc, fs, 1, 0), "fragment arguments encoded for base instance 9");
    c0 = block_of(fs, 0);
    CHECK(g_stat_args_enc == enc + 2 && fs->ab_gpu != first && g_ft_addr[0] == fs->ab_gpu, "a new base instance encodes a new block");
    CHECK(c0 && (memcpy(&v, c0 + DMSH_C0_BASE_INSTANCE, 4), v == 9), "the new c0 block holds base instance 9");
    rp_end();
    CHECK(rp_begin() != nil, "second render pass opens");
    CHECK(encode_args((id<MTLCommandEncoder>)g_enc, fs, 1, 0), "fragment arguments encoded in the second pass");
    CHECK(g_stat_args_enc == enc + 3 && g_stat_args_reuse == reuse + 1 && g_ft_addr[0] == fs->ab_gpu, "a new pass encodes a new block");
    rp_end();
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "GPU submission completed");
    CHECK(!mtl_last_commit_error(), "GPU submission has no error");
    mtl_tex_release(&rt);
    printf("arena argument reuse: %s\n", before == failed ? "PASS" : "FAIL");
}
static void alloc_case(void) {
    int before = failed;
    mtl_sub_begin();
    id<MTLBuffer> b; size_t o1 = arena_alloc(100, &b), o2 = arena_alloc(100, NULL);
    CHECK(b == g_cur_arena->buf && !(o1 & 255) && o2 == o1 + 256, "allocations with and without the buffer are consecutive 256-byte blocks of one arena");
    size_t o3 = arena_alloc(g_cur_arena->len, NULL);
    CHECK(o3 == 0 && g_cur_arena->buf != b, "a block that does not fit takes another arena");
    CHECK(g_cur_arena->cpu == (uint8_t *)g_cur_arena->buf.contents && g_cur_arena->gpu == g_cur_arena->buf.gpuAddress, "that arena's CPU and GPU addresses are its buffer's");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "empty GPU submission completed");
    printf("arena allocation: %s\n", before == failed ? "PASS" : "FAIL");
}
int main(void) { @autoreleasepool {
    setenv("DM_NVN_TBDR", "0", 1);
    mtl_init(); NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct A { constant uint4 *push [[id(0)]]; constant uint4 *c0 [[id(1)]]; constant uint4 *c2 [[id(2)]]; sampler s [[id(3)]]; constant uint4 *border [[id(4)]]; };\n"
        "kernel void k(constant A &a [[buffer(0)]], device uint4 *out [[buffer(1)]]) {\n"
        "    out[0] = a.push[0]; out[1] = a.push[15]; out[2] = a.c0[0x20]; out[3] = a.c0[0x31]; out[4] = a.c2[2]; out[5] = a.border[0]; out[6] = a.border[1]; }\n"
        "struct B { constant uint4 *c0 [[id(0)]]; };\n"
        "fragment float4 f(constant B &b [[buffer(0)]]) { return float4(b.c0[0].x); }\n"
        options:nil error:&error];
    CHECK(lib != nil, "synthetic shaders compile");
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    NvShader *cs = [NvShader new]; cs->stage = 5; strcpy(cs->key, "c1a0000000000005"); cs->fn = [lib newFunctionWithName:@"k"];
    cs->ae = [cs->fn newArgumentEncoderWithBufferIndex:0]; cs->arg_len = cs->ae.encodedLength;
    cs->rf.nb = 5; cs->rf.border = 5; cs->rf.drv_read[0] = cs->rf.drv_read[2] = 1;
    cs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_PUSH, .aid=0};
    cs->rf.b[1] = (nvn_rbind){.kind=NVN_RB_DRV0, .aid=1};
    cs->rf.b[2] = (nvn_rbind){.kind=NVN_RB_DRV2, .aid=2};
    cs->rf.b[3] = (nvn_rbind){.kind=NVN_RB_SAMP, .reg=0, .aid=3, .bw=1};
    cs->rf.b[4] = (nvn_rbind){.kind=NVN_RB_BORDER, .aid=4};
    CHECK(cs->arg_len == 40, "the compute argument block has five 8-byte entries (%lu bytes)", (unsigned long)cs->arg_len);
    id<MTLComputePipelineState> ps = [g_dev newComputePipelineStateWithFunction:cs->fn error:&error];
    CHECK(ps != nil, "synthetic compute pipeline compiles");
    if (!ps) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    samp_par sp = {0}; sp.magf = 1; sp.minf = 1; sp.ws = sp.wt = sp.wr = 5; memcpy(sp.border, (float[4]){0.25f, 0.5f, 0.75f, 1}, 16);
    mtl_reg_samp(21, &sp);
    compute_case(cs, ps, 21, 0, "first submission");
    uint64_t made = g_arena_made;
    compute_case(cs, ps, 21, 1, "second submission");
    CHECK(g_arena_made == made, "the second submission reuses an arena (%llu made, %llu before)", (unsigned long long)g_arena_made, (unsigned long long)made);
    NvShader *fs = [NvShader new]; fs->stage = 1; strcpy(fs->key, "c1a0000000000001"); fs->fn = [lib newFunctionWithName:@"f"];
    fs->ae = [fs->fn newArgumentEncoderWithBufferIndex:0]; fs->arg_len = fs->ae.encodedLength;
    fs->rf.nb = 1; fs->rf.drv_read[0] = 1; fs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_DRV0, .aid=0};
    reuse_case(fs);
    alloc_case();
    printf("arena arguments: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
