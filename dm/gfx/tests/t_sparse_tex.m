#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
void crash_install(void);
static int cases, failed;
#define EXPECT(n, c) do { int ok_ = !!(c); cases++; printf("%s: %s\n", n, ok_ ? "PASS" : "FAIL"); failed += !ok_; } while (0)

enum { TILE = 0x10000 };
static pool_t g_cmdpool, g_phys, g_sparse; static uint8_t *g_cmdmem, *g_physmem;
static NVNcommandBuffer g_cmd;
static void submit(void (*fn)(void), const NVNtexture *const *tex, int ntex) {
    h_nvnCommandBufferBeginRecording(&g_cmd);
    h_nvnCommandBufferCopyBufferToBuffer(&g_cmd, (NVNbufferAddress)(g_cmdmem + 0x30000), (NVNbufferAddress)(g_cmdmem + 0x30100), 16, 0);
    if (fn) fn();
    NVNcommandHandle h = h_nvnCommandBufferEndRecording(&g_cmd);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    for (int i = 0; i < ntex; i++) tex_mtl(TX(tex[i]));
    mtl_exec((const uint8_t *)h);
    uint64_t f = mtl_sub_commit();
    if (!mtl_wait_at(f, 5000000000ull, WS_FINISH)) { printf("submission %llu never completed\n", (unsigned long long)f); exit(1); }
    if (mtl_last_commit_error() || atomic_load(&g_up_lost_n)) { printf("GPU error in submission %llu\n", (unsigned long long)f); failed++; }
}
static void map(pool_t *sparse, uint64_t voff, uint64_t size, int ptile, uint64_t pin) {
    map_req r = {.phys = ptile >= 0 ? (NVNmemoryPool *)&g_phys : NULL, .poff = ptile >= 0 ? (int64_t)((uint64_t)ptile * TILE + pin) : 0, .voff = (int64_t)voff, .size = size};
    if (!h_nvnMemoryPoolMapVirtual((NVNmemoryPool *)sparse, 1, (const NVNmappingRequest *)&r)) { printf("MapVirtual failed\n"); exit(1); }
}
static void fill32(int ptile, uint64_t from, uint64_t n, uint32_t v) { uint32_t *p = (uint32_t *)(g_physmem + (uint64_t)ptile * TILE + from); for (uint64_t i = 0; i < n / 4; i++) p[i] = v; }
static void texels(id<MTLTexture> t, int n, const uint32_t (*at)[4], float (*out)[4]) {
    static id<MTLComputePipelineState> pa, p2; static id<MTLSamplerState> smp;
    if (!pa) { NSError *e = nil;
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void a(texture2d_array<float> t [[texture(0)]], sampler s [[sampler(0)]], device const uint4 *q [[buffer(0)]], device float4 *o [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
            "  uint4 p = q[i]; float2 sz = float2(max(t.get_width() >> p.w, 1u), max(t.get_height() >> p.w, 1u)); o[i] = t.sample(s, (float2(p.xy) + 0.5) / sz, p.z, level(float(p.w))); }\n"
            "kernel void b(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device const uint4 *q [[buffer(0)]], device float4 *o [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
            "  uint4 p = q[i]; float2 sz = float2(max(t.get_width() >> p.w, 1u), max(t.get_height() >> p.w, 1u)); o[i] = t.sample(s, (float2(p.xy) + 0.5) / sz, level(float(p.w))); }\n";
        id<MTLLibrary> l = [g_dev newLibraryWithSource:src options:nil error:&e]; if (!l) { printf("probe library: %s\n", e.description.UTF8String); exit(1); }
        pa = [g_dev newComputePipelineStateWithFunction:[l newFunctionWithName:@"a"] error:&e]; p2 = [g_dev newComputePipelineStateWithFunction:[l newFunctionWithName:@"b"] error:&e];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest; sd.mipFilter = MTLSamplerMipFilterNearest; smp = [g_dev newSamplerStateWithDescriptor:sd]; }
    id<MTLBuffer> q = [g_dev newBufferWithBytes:at length:(NSUInteger)n * 16 options:MTLResourceStorageModeShared], o = [g_dev newBufferWithLength:(NSUInteger)n * 16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> c = q_cb(); id<MTLComputeCommandEncoder> e = [c computeCommandEncoder];
    [e setComputePipelineState:t.textureType == MTLTextureType2DArray ? pa : p2]; [e setTexture:t atIndex:0]; [e setSamplerState:smp atIndex:0]; [e setBuffer:q offset:0 atIndex:0]; [e setBuffer:o offset:0 atIndex:1];
    [e dispatchThreads:MTLSizeMake((NSUInteger)n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [e endEncoding]; [c commit]; [c waitUntilCompleted];
    if (c.error) { printf("probe error: %s\n", c.error.description.UTF8String); failed++; }
    memcpy(out, o.contents, (size_t)n * 16);
}
static int near(const float *v, uint32_t rgba) { for (int k = 0; k < 4; k++) if (fabsf(v[k] - (float)(rgba >> (8 * k) & 255) / 255.f) > 0.01f) return 0; return 1; }
static int black(const float *v) { return v[0] == 0 && v[1] == 0 && v[2] == 0; }
static NvPkg *pkg(const NVNtexture *t) { id h = tex_get(TX(t)->serial); return [h isKindOfClass:[NvPkg class]] ? h : nil; }
static uint64_t tile_at(const NVNtexture *t, uint32_t s, unsigned l, uint32_t x, uint32_t y) {
    const tex_t *x_ = TX(t); int bw, bh, bpb = nvn_fmt_bpb(x_->d.format, &bw, &bh); uint32_t tw, th, td; nvn_tex_sparse_tiles(&x_->d, &tw, &th, &td);
    uint32_t tx = nvn_tex_level_gobs(&x_->d, l) / (tw / (uint32_t)bw * (uint32_t)bpb / 64);
    return (uint64_t)x_->off + s * x_->L.layer_size + nvn_tex_level_offset(&x_->d, l) + ((uint64_t)y * tx + x) * TILE;
}
static NVNtexture g_A, g_B, g_C;
static void rec_clear(void) { NVNcopyRegion r = {0, 0, 0, 256, 128, 1}; float c[4] = {1, 0, 1, 1}; NVNtextureView v; h_nvnTextureViewSetDefaults(&v); h_nvnTextureViewSetLayers(&v, 0, 1);
    h_nvnCommandBufferClearTexture(&g_cmd, &g_A, &v, &r, c, 15); }
static void rec_copy(void) { NVNcopyRegion r = {384, 256, 0, 256, 128, 1}; h_nvnCommandBufferCopyBufferToTexture(&g_cmd, (NVNbufferAddress)(g_cmdmem + 0x40000), &g_A, NULL, &r, 0); }
static NVNtexture g_G, g_H;
static void rec_copy_g(void) { NVNcopyRegion r = {0, 0, 0, 128, 128, 1}; h_nvnCommandBufferCopyBufferToTexture(&g_cmd, (NVNbufferAddress)(g_cmdmem + 0x40000), &g_G, NULL, &r, 0); }
static int g_off_made;
static void *resolve_off(void *t) { @autoreleasepool { g_off_made = tex_mtl(TX((const NVNtexture *)t)) != nil; } return NULL; }

int main(void) { @autoreleasepool {
    alarm(120); if (setvbuf(stdout, NULL, _IONBF, 0)) abort();
    crash_install(); mtl_init();
    if (!sp_on()) { printf("no placement sparse textures on this device: skipped\n"); return 0; }
    size_t cmdlen = 1 << 20, physlen = 64 * TILE;
    if (posix_memalign((void **)&g_cmdmem, getpagesize(), cmdlen)) abort(); memset(g_cmdmem, 0, cmdlen);
    g_physmem = mmap(NULL, physlen, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (g_physmem == MAP_FAILED) abort();
    pool_builder_t pb = {.mem = g_cmdmem, .size = cmdlen, .flags = 0x24};
    EXPECT("command pool", h_nvnMemoryPoolInitialize((NVNmemoryPool *)&g_cmdpool, (const NVNmemoryPoolBuilder *)&pb));
    pb = (pool_builder_t){.mem = g_physmem, .size = physlen, .flags = 0x124};
    EXPECT("physical pool", h_nvnMemoryPoolInitialize((NVNmemoryPool *)&g_phys, (const NVNmemoryPoolBuilder *)&pb));
    pb = (pool_builder_t){.size = DM_GAME_APP_POOL + (64u << 20), .flags = NVN_MEMORY_POOL_FLAGS_VIRTUAL};
    EXPECT("sparse pool", h_nvnMemoryPoolInitialize((NVNmemoryPool *)&g_sparse, (const NVNmemoryPoolBuilder *)&pb));
    EXPECT("command buffer", h_nvnCommandBufferInitialize(&g_cmd, NULL)); h_nvnCommandBufferAddCommandMemory(&g_cmd, (const NVNmemoryPool *)&g_cmdpool, 0, 0x20000);
    NVNtextureBuilder tb; h_nvnTextureBuilderSetDefaults(&tb); h_nvnTextureBuilderSetFlags(&tb, NVN_TEXTURE_FLAGS_SPARSE);
    h_nvnTextureBuilderSetTarget(&tb, NVN_TEXTURE_TARGET_2D_ARRAY); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8); h_nvnTextureBuilderSetSize3D(&tb, 1024, 1024, 2); h_nvnTextureBuilderSetLevels(&tb, 11);
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&g_sparse, 0); EXPECT("A: 1024x1024 x2 RGBA8, 11 levels", h_nvnTextureInitialize(&g_A, &tb));
    uint64_t offB = (TX(&g_A)->L.size + TILE - 1) & ~(uint64_t)(TILE - 1);
    h_nvnTextureBuilderSetTarget(&tb, NVN_TEXTURE_TARGET_2D); h_nvnTextureBuilderSetSize2D(&tb, 512, 512); h_nvnTextureBuilderSetLevels(&tb, 10);
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&g_sparse, (ptrdiff_t)offB); EXPECT("B: 512x512 RGBA8, 10 levels", h_nvnTextureInitialize(&g_B, &tb));
    uint64_t offC = (offB + TX(&g_B)->L.size + TILE - 1) & ~(uint64_t)(TILE - 1);
    h_nvnTextureBuilderSetTarget(&tb, NVN_TEXTURE_TARGET_2D_ARRAY); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA_ASTC_8x8); h_nvnTextureBuilderSetSize3D(&tb, 1000, 600, 2); h_nvnTextureBuilderSetLevels(&tb, 3);
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&g_sparse, (ptrdiff_t)offC); EXPECT("C: 1000x600 x2 ASTC 8x8, 3 levels", h_nvnTextureInitialize(&g_C, &tb));
    uint64_t lsA = TX(&g_A)->L.layer_size, smallA = nvn_tex_level_offset(&TX(&g_A)->d, 4);
    printf("A: layer %#llx bytes, levels from 4 at %#llx; B at %#llx, C at %#llx\n", (unsigned long long)lsA, (unsigned long long)smallA, (unsigned long long)offB, (unsigned long long)offC);

    nvn_texdesc one = {.target = 1, .format = NVN_FORMAT_RGBA8, .width = 128, .height = 128, .depth = 1, .levels = 1, .pkg_block_h = 5};
    uint32_t *grad = malloc(128 * 128 * 4); for (uint32_t y = 0; y < 128; y++) for (uint32_t x = 0; x < 128; x++) grad[y * 128 + x] = x | y << 8 | (x ^ y) << 16 | 0xFFu << 24;
    nvn_swizzle(&one, 0, 0, grad, 128 * 4, g_physmem + 1 * TILE);
    const uint32_t c0 = 0xFF1E140A, c2 = 0xFF00FF00, c3 = 0xFF808040, c4 = 0xFF4080C0, c5 = 0xFF0000FF, c6 = 0xFFFF0000, c8 = 0xFF336699, c9 = 0xFF99CC33;
    fill32(0, 0, TILE, c0); fill32(2, 0, TILE, c2); fill32(3, 0, TILE, c3); fill32(4, 0, TILE / 2, c4); fill32(6, TILE / 2, TILE / 2, c4);
    map(&g_sparse, tile_at(&g_A, 0, 0, 0, 0), TILE, 0, 0);
    map(&g_sparse, tile_at(&g_A, 0, 0, 3, 2), TILE, 1, 0);
    map(&g_sparse, tile_at(&g_A, 1, 0, 7, 7), TILE, 2, 0);
    map(&g_sparse, smallA, TILE, 3, 0);
    map(&g_sparse, tile_at(&g_A, 1, 1, 0, 0), TILE / 2, 4, 0); map(&g_sparse, tile_at(&g_A, 1, 1, 0, 0) + TILE / 2, TILE / 2, 6, TILE / 2);
    uint64_t gpu0 = g_dev.currentAllocatedSize;
    const NVNtexture *ta[] = {&g_A}; submit(NULL, ta, 1);
    NvPkg *pk = pkg(&g_A);
    EXPECT("A is a Metal sparse texture", pk && pk->sp && pk->tex.isSparse);
    if (!pk || !pk->sp) { printf("== %d checks, %d failed ==\n", cases, failed); return 1; }
    struct sp_tex *p = pk->sp;
    printf("A: %u units a layer (%u tiles, levels from %u in one of %u Metal tiles), Metal tail from level %u; %u mapped on %llu heap tiles (%.2f MB; GPU allocated +%.2f MB with the first %u MB heap and the staging), a whole texture: %.2f MB\n", p->per, p->ntiled, p->split, p->nsm,
           p->mfirst, p->mapped, (unsigned long long)g_sp_ntiles, (double)g_sp_ntiles * TILE / 1048576.0, ((double)g_dev.currentAllocatedSize - (double)gpu0) / 1048576.0, (unsigned)(SP_CHUNK * SP_TILE >> 20), (double)[g_dev heapTextureSizeAndAlignWithDescriptor:tex_desc(TX(&g_A), 1)].size / 1048576.0);
    EXPECT("A: 5 units mapped", p->mapped == 5);
    {   uint32_t at[][4] = {{5, 5, 0, 0}, {3 * 128 + 17, 2 * 128 + 33, 0, 0}, {200, 10, 0, 0}, {7 * 128 + 5, 7 * 128 + 9, 1, 0}, {3, 3, 0, 4}, {0, 0, 0, 10}, {3, 3, 1, 4}, {10, 10, 1, 1}, {5, 5, 1, 0}};
        float v[9][4]; texels(pk->tex, 9, at, v);
        EXPECT("A layer 0 tile (0,0): its pages", near(v[0], c0));
        EXPECT("A layer 0 tile (3,2): the gradient, deswizzled as one tile", near(v[1], grad[33 * 128 + 17]));
        EXPECT("A layer 0 tile (1,0), unmapped: 0", black(v[2]));
        EXPECT("A layer 1 tile (7,7): its pages", near(v[3], c2));
        EXPECT("A layer 0 level 4 (the small part): its pages", near(v[4], c3));
        EXPECT("A layer 0 level 10 (Metal's tail): its pages", near(v[5], c3));
        EXPECT("A layer 1 level 4, unmapped: 0", black(v[6]));
        EXPECT("A layer 1 level 1 tile (0,0), pages of two physical tiles (gathered on the CPU): its pages", near(v[7], c4));
        EXPECT("A layer 1 tile (0,0), unmapped: 0", black(v[8])); }

    fill32(0, 0, TILE, c5);
    submit(NULL, NULL, 0);
    {   uint32_t at[][4] = {{5, 5, 0, 0}}; float v[1][4]; texels(pk->tex, 1, at, v); EXPECT("A layer 0 tile (0,0) after a CPU write to its pages: the new bytes", near(v[0], c5)); }
    fill32(5, 0, TILE, c6); map(&g_sparse, tile_at(&g_A, 0, 0, 0, 0), TILE, 5, 0);
    submit(NULL, NULL, 0);
    {   uint32_t at[][4] = {{5, 5, 0, 0}}; float v[1][4]; texels(pk->tex, 1, at, v); EXPECT("A layer 0 tile (0,0) remapped onto other pages: theirs", near(v[0], c6)); }

    uint64_t unmaps = g_sp_unmaps, freed = g_sp_ntiles;
    map(&g_sparse, tile_at(&g_A, 1, 0, 7, 7), TILE, -1, 0);
    submit(NULL, NULL, 0);
    EXPECT("A layer 1 tile (7,7) unmapped by the game: waits for the unmap round", p->npend == 1 && g_sp_unmaps == unmaps);
    for (int i = 0; i < 31 && g_sp_unmaps == unmaps; i++) submit(NULL, NULL, 0);
    submit(NULL, NULL, 0);
    {   uint32_t at[][4] = {{7 * 128 + 5, 7 * 128 + 9, 1, 0}, {5, 5, 0, 0}}; float v[2][4]; texels(pk->tex, 2, at, v);
        EXPECT("A layer 1 tile (7,7) after the unmap round: 0", black(v[0]) && g_sp_unmaps == unmaps + 1 && p->npend == 0 && p->mapped == 4);
        EXPECT("A layer 0 tile (0,0) through the round: kept", near(v[1], c6)); }
    submit(NULL, NULL, 0);
    pthread_mutex_lock(&g_sp_mu); int nfree = g_sp_nfree; pthread_mutex_unlock(&g_sp_mu);
    EXPECT("its heap tile back in its chunk once the GPU passed the round", g_sp_ntiles == freed - 1 && nfree == 0);

    submit(rec_clear, NULL, 0);
    pk = pkg(&g_A);
    {   uint32_t at[][4] = {{5, 5, 0, 0}, {200, 10, 0, 0}, {3 * 128 + 17, 2 * 128 + 33, 0, 0}, {10, 10, 1, 1}}; float v[4][4]; texels(pk->tex, 4, at, v);
        EXPECT("clear: A remade with render-target use, still a sparse texture", (pk->tex.usage & MTLTextureUsageRenderTarget) && pk->tex.isSparse);
        EXPECT("clear into mapped tile (0,0): cleared", near(v[0], 0xFFFF00FF));
        EXPECT("clear into unmapped tile (1,0): dropped, still 0", black(v[1]));
        EXPECT("tile (3,2) through the remake: the gradient", near(v[2], grad[33 * 128 + 17]));
        EXPECT("layer 1 level 1 through the remake: its pages", near(v[3], c4)); }
    { uint32_t *b = (uint32_t *)(g_cmdmem + 0x40000); for (int i = 0; i < 256 * 128; i++) b[i] = c8; }
    submit(rec_copy, NULL, 0);
    {   uint32_t at[][4] = {{3 * 128 + 5, 2 * 128 + 5, 0, 0}, {4 * 128 + 5, 2 * 128 + 5, 0, 0}}; float v[2][4]; texels(pk->tex, 2, at, v);
        EXPECT("buffer copy into mapped tile (3,2): copied", near(v[0], c8));
        EXPECT("buffer copy into unmapped tile (4,2): dropped, still 0", black(v[1])); }

    for (uint32_t i = 0; i < 4; i++) { fill32(8 + (int)i, 0, TILE, c9); map(&g_sparse, tile_at(&g_B, 0, 1, i % 2, i / 2), TILE, 8 + (int)i, 0); }
    fill32(12, 0, TILE, c9); map(&g_sparse, tile_at(&g_B, 0, 2, 0, 0), TILE, 12, 0);
    uint64_t smallB = offB + nvn_tex_level_offset(&TX(&g_B)->d, 3); fill32(13, 0, TILE, c9); map(&g_sparse, smallB, TX(&g_B)->L.size - (smallB - offB), 13, 0);
    const NVNtexture *tbb[] = {&g_B}; submit(NULL, tbb, 1);
    NvPkg *pb_ = pkg(&g_B);
    EXPECT("B is a Metal sparse texture bound from level 1", pb_ && pb_->sp && pb_->vbase == 1 && pb_->view && pb_->view.mipmapLevelCount == 9);
    if (pb_ && pb_->view) { uint32_t at[][4] = {{100, 100, 0, 0}, {10, 10, 0, 1}}; float v[2][4]; texels(pb_->view, 2, at, v); EXPECT("B through its view: levels 1 and 2", near(v[0], c9) && near(v[1], c9)); }
    for (uint32_t i = 0; i < 16; i++) { fill32(14 + (int)i, 0, TILE, c9); map(&g_sparse, tile_at(&g_B, 0, 0, i % 4, i / 4), TILE, 14 + (int)i, 0); }
    submit(NULL, tbb, 1);
    EXPECT("B with level 0 mapped too: bound whole", pb_ && pb_->vbase == 0 && !pb_->view);

    { uint8_t blk[16] = {0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}; uint16_t col[4] = {0x4000, 0x8000, 0xC000, 0xFFFF}; memcpy(blk + 8, col, 8);
      for (int i = 0; i < TILE / 16; i++) memcpy(g_physmem + 40 * TILE + i * 16, blk, 16); }
    map(&g_sparse, tile_at(&g_C, 0, 0, 1, 1), TILE, 40, 0);
    const NVNtexture *tc[] = {&g_C}; submit(NULL, tc, 1);
    NvPkg *pc = pkg(&g_C);
    EXPECT("C is a Metal sparse texture", pc && pc->sp);
    if (pc && pc->sp) { uint32_t at[][4] = {{900, 550, 0, 0}, {100, 100, 0, 0}, {900, 550, 1, 0}}; float v[3][4]; texels(pc->tex, 3, at, v);
        EXPECT("C tile (1,1), cut at the level's edge: its colour", fabsf(v[0][0] - 0.25f) < 0.02f && fabsf(v[0][1] - 0.5f) < 0.02f && fabsf(v[0][2] - 0.75f) < 0.02f);
        EXPECT("C tile (0,0) and layer 1, unmapped: 0", black(v[1]) && black(v[2])); }

    struct vpool *vp = g_sparse.vp; p = pkg(&g_A)->sp;
    for (int i = 0; i < 1100; i++) map(&g_sparse, (uint64_t)TX(&g_A)->off + (uint64_t)i * 0x2000, 0x1000, 50 + i % 8, (uint64_t)(i % 16) * 0x1000);
    { uint64_t at = 0, tot = 0; int nr; static uint64_t rng[SP_RANGES][2];
      while ((nr = nvn_sparse_changes(&g_sparse, p->vgen, rng, SP_RANGES, &at)) > 0) { tot += (uint64_t)nr; if (nr < SP_RANGES) break; }
      EXPECT("1,100 mappings: all in the log (grown past 1,024 entries), read in batches", nr >= 0 && tot == 1100 && vp->cap >= 2048); }
    submit(NULL, NULL, 0);
    {   uint32_t want = 0; for (uint32_t i = 0; i < p->layers * p->per; i++) { uint64_t a, n; uint32_t m; uint64_t key; const uint8_t *ph; sp_unit_range(p, i, &a, &n); nvn_sparse_units(&g_sparse, 1, &a, &n, &m, &key, &ph); want += m != 0; }
        EXPECT("the log dropped once every texture of the pool has seen it", vp->tail == vp->nchg);
        EXPECT("every unit of A with a mapped page is mapped", p->mapped == want && p->npend == 0);
        printf("A: %u units mapped after the 1,100 mappings\n", p->mapped); }

    static pool_t vp0, vp1; static NVNtexture g_D, g_E, g_F;
    pb = (pool_builder_t){.size = 4u << 20, .flags = NVN_MEMORY_POOL_FLAGS_VIRTUAL};
    EXPECT("two virtual pools of 4 MB", h_nvnMemoryPoolInitialize((NVNmemoryPool *)&vp0, (const NVNmemoryPoolBuilder *)&pb) && h_nvnMemoryPoolInitialize((NVNmemoryPool *)&vp1, (const NVNmemoryPoolBuilder *)&pb) && !vp0.vmode && !vp1.vmode);
    h_nvnTextureBuilderSetTarget(&tb, NVN_TEXTURE_TARGET_2D); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8); h_nvnTextureBuilderSetSize2D(&tb, 512, 512); h_nvnTextureBuilderSetLevels(&tb, 1);
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&vp0, 0); h_nvnTextureInitialize(&g_D, &tb);
    uint64_t offF = (offC + TX(&g_C)->L.size + TILE - 1) & ~(uint64_t)(TILE - 1);
    h_nvnTextureBuilderSetSize2D(&tb, 256, 256); h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&g_sparse, (ptrdiff_t)offF); h_nvnTextureInitialize(&g_F, &tb);
    const NVNtexture *tde[] = {&g_D, &g_E}; submit(NULL, tde, 1);
    EXPECT("D before its pool's first mapping: nothing made", !tex_get(TX(&g_D)->serial));
    fill32(41, 0, TILE, c9); map(&vp0, 0, TILE, 41, 0); map(&vp1, 0, 4u << 20, 0, 0);
    h_nvnTextureBuilderSetSize2D(&tb, 512, 512); h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&vp1, 0); h_nvnTextureInitialize(&g_E, &tb);
    submit(NULL, tde, 2);
    { NvPkg *pd = pkg(&g_D); id he = tex_get(TX(&g_E)->serial);
      EXPECT("D, its pool made sparse by a partial mapping: a Metal sparse texture", vp0.vmode == 2 && pd && pd->sp && pd->sp->mapped == 1);
      if (pd && pd->sp) { uint32_t at[][4] = {{5, 5, 0, 0}, {300, 300, 0, 0}}; float v[2][4]; texels(pd->tex, 2, at, v); EXPECT("D: its mapped tile, and 0 beside it", near(v[0], c9) && black(v[1])); }
      EXPECT("E, its pool aliased by a whole mapping: the whole-texture path", vp1.vmode == 1 && he && !([he isKindOfClass:[NvPkg class]] && ((NvPkg *)he)->sp)); }
    { pthread_t th; pthread_create(&th, NULL, resolve_off, &g_F); pthread_join(th, NULL); }
    EXPECT("F first resolved off the submit thread: nothing made or kept", !g_off_made && !tex_get(TX(&g_F)->serial));
    const NVNtexture *tf[] = {&g_F}; submit(NULL, tf, 1);
    EXPECT("F at its next resolution on the submit thread: a Metal sparse texture", pkg(&g_F) && pkg(&g_F)->sp);

    uint64_t offG = (offF + TX(&g_F)->L.size + TILE - 1) & ~(uint64_t)(TILE - 1);
    h_nvnTextureBuilderSetTarget(&tb, NVN_TEXTURE_TARGET_2D_ARRAY); h_nvnTextureBuilderSetSize3D(&tb, 512, 512, 2); h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&g_sparse, (ptrdiff_t)offG); h_nvnTextureInitialize(&g_G, &tb);
    uint64_t offH = (offG + TX(&g_G)->L.size + TILE - 1) & ~(uint64_t)(TILE - 1);
    h_nvnTextureBuilderSetSize3D(&tb, 256, 256, 1); h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&g_sparse, (ptrdiff_t)offH); h_nvnTextureInitialize(&g_H, &tb);
    const uint32_t ca = 0xFF204060, cb = 0xFF608020, cc = 0xFF2080C0, cd = 0xFFC08020;
    fill32(60, 0, TILE, ca); fill32(61, 0, TILE, cc);
    map(&g_sparse, tile_at(&g_G, 0, 0, 0, 0), TILE, 60, 0); map(&g_sparse, tile_at(&g_G, 1, 0, 2, 1), TILE, 60, 0); map(&g_sparse, tile_at(&g_H, 0, 0, 1, 1), TILE, 60, 0);
    uint64_t t0 = g_sp_ntiles, up0 = g_sp_up_bytes;
    const NVNtexture *tgh[] = {&g_G, &g_H}; submit(NULL, tgh, 2);
    NvPkg *pg = pkg(&g_G), *ph = pkg(&g_H);
    EXPECT("G and H, on the same physical page in three places: Metal sparse textures", pg && pg->sp && ph && ph->sp);
    if (pg && pg->sp && ph && ph->sp) {
        uint32_t ag[][4] = {{5, 5, 0, 0}, {2 * 128 + 5, 128 + 5, 1, 0}}, ah[][4] = {{128 + 5, 128 + 5, 0, 0}}; float v[3][4];
        EXPECT("the three units: one heap tile, uploaded once", g_sp_ntiles == t0 + 1 && g_sp_up_bytes == up0 + TILE);
        texels(pg->tex, 2, ag, v); texels(ph->tex, 1, ah, v + 2);
        EXPECT("the three units: the page", near(v[0], ca) && near(v[1], ca) && near(v[2], ca));
        { uint32_t *b = (uint32_t *)(g_cmdmem + 0x40000); for (int i = 0; i < 128 * 128; i++) b[i] = cb; }
        submit(rec_copy_g, NULL, 0);
        texels(pg->tex, 2, ag, v); texels(ph->tex, 1, ah, v + 2);
        EXPECT("a buffer copy into G tile (0,0): seen through G layer 1 tile (2,1) and H tile (1,1)", near(v[0], cb) && near(v[1], cb) && near(v[2], cb));
        up0 = g_sp_up_bytes; fill32(60, 0, TILE, cd);
        submit(NULL, NULL, 0);
        texels(pg->tex, 2, ag, v); texels(ph->tex, 1, ah, v + 2);
        EXPECT("a CPU write to the page: uploaded once, the new bytes in the three units", g_sp_up_bytes == up0 + TILE && near(v[0], cd) && near(v[1], cd) && near(v[2], cd));
        map(&g_sparse, tile_at(&g_H, 0, 0, 1, 1), TILE, 61, 0);
        submit(NULL, NULL, 0);
        texels(pg->tex, 2, ag, v); texels(ph->tex, 1, ah, v + 2);
        EXPECT("H tile (1,1) remapped onto another page: a tile of its own, G keeps the first", g_sp_ntiles == t0 + 2 && near(v[2], cc) && near(v[0], cd) && near(v[1], cd));
    }
    h_nvnTextureFinalize(&g_G); h_nvnTextureFinalize(&g_H);
    h_nvnTextureFinalize(&g_D); h_nvnTextureFinalize(&g_E); h_nvnTextureFinalize(&g_F);

    h_nvnTextureFinalize(&g_A); h_nvnTextureFinalize(&g_B); h_nvnTextureFinalize(&g_C);
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&g_sparse);
    pthread_mutex_lock(&g_sp_mu); int gone = 1; for (int i = 0; i < g_sp_n; i++) if (g_sp[i]->pool == &g_sparse) gone &= g_sp[i]->gone; pthread_mutex_unlock(&g_sp_mu);
    EXPECT("a finalized pool's textures are marked gone", gone);
    submit(NULL, NULL, 0); submit(NULL, NULL, 0);
    sp_stat();
    printf("== %d checks, %d failed ==\n", cases, failed);
    return failed != 0;
} }
