enum { RDG_NOP = RO_SPARSE_MAP + 1, RDG_NEV = 64 };
static const struct { const char *name, *spec; } g_rdg_ops[RDG_NOP] = {
    [RO_CB_NEW] = {"CB_NEW", ""}, [RO_CB_BEGIN] = {"CB_BEGIN", "o"}, [RO_CB_END] = {"CB_END", ""}, [RO_COMMIT] = {"COMMIT", "p-u"}, [RO_COMMIT_REAL] = {"COMMIT_REAL", "po"},
    [RO_SIGNAL] = {"SIGNAL", "oe"}, [RO_RE_BEGIN] = {"RE_BEGIN", "d"}, [RO_CE_BEGIN] = {"CE_BEGIN", ""}, [RO_END] = {"END", ""},
    [RO_BAR_QUEUE] = {"BAR_QUEUE", "rrr"}, [RO_BAR_AFTER_STAGES] = {"BAR_AFTER_STAGES", "rrr"}, [RO_BAR_ENCODER] = {"BAR_ENCODER", "rrr"},
    [RO_R_TABLE] = {"R_TABLE", "or"}, [RO_R_PSO] = {"R_PSO", "o"}, [RO_R_DSS] = {"R_DSS", "o"}, [RO_R_VIEWPORT] = {"R_VIEWPORT", "rrrrrr"}, [RO_R_SCISSOR] = {"R_SCISSOR", "rrrr"},
    [RO_R_CULL] = {"R_CULL", "r"}, [RO_R_WINDING] = {"R_WINDING", "r"}, [RO_R_FILL] = {"R_FILL", "r"}, [RO_R_BIAS] = {"R_BIAS", "rrr"}, [RO_R_CLIP] = {"R_CLIP", "r"},
    [RO_R_SREF] = {"R_SREF", "r"}, [RO_R_BLEND] = {"R_BLEND", "rrrr"}, [RO_R_VIS] = {"R_VIS", "rr"}, [RO_R_AMP] = {"R_AMP", "rrr"},
    [RO_R_DRAW] = {"R_DRAW", "rrr"}, [RO_R_DRAW_INST] = {"R_DRAW_INST", "rrrrr"}, [RO_R_DRAW_IND] = {"R_DRAW_IND", "ra"}, [RO_R_DRAW_IDX] = {"R_DRAW_IDX", "rrrarrrr"},
    [RO_R_DRAW_IDX_IND] = {"R_DRAW_IDX_IND", "rrara"}, [RO_R_MESH] = {"R_MESH", "rr"}, [RO_R_STORE_C] = {"R_STORE_C", "rr"}, [RO_R_STORE_D] = {"R_STORE_D", "r"}, [RO_R_STORE_S] = {"R_STORE_S", "r"},
    [RO_C_TABLE] = {"C_TABLE", "o"}, [RO_C_PSO] = {"C_PSO", "o"}, [RO_C_DISPATCH] = {"C_DISPATCH", "rrrrrr"}, [RO_C_DISPATCH_IND] = {"C_DISPATCH_IND", "arrr"},
    [RO_C_COPY_BB] = {"C_COPY_BB", "oorrr"}, [RO_C_COPY_BT] = {"C_COPY_BT", "oorrrrrrrrrrrr"}, [RO_C_COPY_TB] = {"C_COPY_TB", "oorrrrrrrrrrrr"}, [RO_C_COPY_TT] = {"C_COPY_TT", "oorrrrrrrrrrrrr"},
    [RO_C_FILL] = {"C_FILL", "orrr"}, [RO_T_ADDR] = {"T_ADDR", "oar"}, [RO_T_TEX] = {"T_TEX", "oir"}, [RO_T_SAMP] = {"T_SAMP", "oir"},
    [RO_LABEL] = {"LABEL", "s"}, [RO_R_TS] = {"R_TS", "orrr"}, [RO_C_TS] = {"C_TS", "orr"}, [RO_NOTE] = {"NOTE", "--"}, [RO_SPARSE_MAP] = {"SPARSE_MAP", "ooomre"},
};

static int g_rdg_live, g_rdg_rebuilt;
static uint32_t g_rdg_epoch;
static uint64_t g_rdg_calls, g_rdg_nobj, g_rdg_addrs, g_rdg_unres, g_rdg_rids, g_rdg_ubc0;
static CC_SHA256_CTX g_rdg_sha;
static FILE *g_rdg_dump;
static char g_rdg_key;
static struct { uint32_t name; uint64_t base; } g_rdg_ev[RDG_NEV]; static int g_rdg_nev;
typedef struct { uint64_t lo, hi; void *o; } rdg_ent;
static rdg_ent *g_rdg_tab; static size_t g_rdg_ntab, g_rdg_cap;
static NSPointerArray *g_rdg_weak;

#define RDG_TXT(...) do { if (g_rdg_dump) fprintf(g_rdg_dump, __VA_ARGS__); } while (0)
static inline void rdg_h(const void *p, size_t n) { CC_SHA256_Update(&g_rdg_sha, p, (CC_LONG)n); }
static inline void rdg_u(uint64_t v) { rdg_h(&v, sizeof v); }
static void rdg_val(uint64_t v) { rdg_u(v); RDG_TXT(v < 1u << 20 ? " %llu" : " 0x%llx", (unsigned long long)v); }
static void rdg_str(NSString *s) { const char *u = s ? s.UTF8String : ""; size_t n = strlen(u); rdg_u(n); rdg_h(u, n); RDG_TXT(" \"%s\"", u); }

static uint32_t rdg_name(id o, int *fresh) {
    NSNumber *t = objc_getAssociatedObject(o, &g_rdg_key); uint64_t v = t ? t.unsignedLongLongValue : 0;
    if (t && v >> 32 == g_rdg_epoch) { *fresh = 0; return (uint32_t)v; }
    uint32_t n = (uint32_t)++g_rdg_nobj;
    objc_setAssociatedObject(o, &g_rdg_key, @((uint64_t)g_rdg_epoch << 32 | n), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    *fresh = 1; return n;
}
static uint32_t rdg_obj(id o);
static void rdg_def(id o) {
    if ([o conformsToProtocol:@protocol(MTLTexture)]) {
        id<MTLTexture> t = o; MTLTextureSwizzleChannels s = t.swizzle;
        uint64_t v[] = {1, t.textureType, t.pixelFormat, t.width, t.height, t.depth, t.mipmapLevelCount, t.arrayLength, t.sampleCount, t.usage, t.storageMode, t.cpuCacheMode, t.hazardTrackingMode,
                        (uint64_t)s.red | (uint64_t)s.green << 8 | (uint64_t)s.blue << 16 | (uint64_t)s.alpha << 24, t.heap != nil, t.parentRelativeLevel, t.parentRelativeSlice, t.bufferOffset, t.bufferBytesPerRow};
        rdg_h(v, sizeof v);
        RDG_TXT("{texture type %llu format %llu %llux%llux%llu levels %llu layers %llu samples %llu usage 0x%llx storage %llu swizzle 0x%llx heap %llu level %llu slice %llu offset %llu row %llu parent",
                v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[13], v[14], v[15], v[16], v[17], v[18]);
        rdg_obj(t.parentTexture); RDG_TXT(" buffer"); rdg_obj(t.buffer); RDG_TXT("}");
    } else if ([o conformsToProtocol:@protocol(MTLBuffer)]) {
        id<MTLBuffer> b = o; uint64_t v[] = {2, b.length, b.storageMode, b.cpuCacheMode, b.hazardTrackingMode, b.heap != nil}; rdg_h(v, sizeof v);
        RDG_TXT("{buffer %llu bytes storage %llu cache %llu hazard %llu heap %llu}", v[1], v[2], v[3], v[4], v[5]);
    } else if ([o conformsToProtocol:@protocol(MTLRenderPipelineState)]) { rdg_u(3); RDG_TXT("{render pipeline"); rdg_str(((id<MTLRenderPipelineState>)o).label); RDG_TXT("}"); }
    else if ([o conformsToProtocol:@protocol(MTLComputePipelineState)]) { rdg_u(4); RDG_TXT("{compute pipeline"); rdg_str(((id<MTLComputePipelineState>)o).label); RDG_TXT("}"); }
    else if ([o conformsToProtocol:@protocol(MTLDepthStencilState)]) { rdg_u(5); RDG_TXT("{depth-stencil state"); rdg_str(((id<MTLDepthStencilState>)o).label); RDG_TXT("}"); }
    else if ([o conformsToProtocol:@protocol(MTL4ArgumentTable)]) { rdg_u(6); RDG_TXT("{argument table}"); }
    else if ([o conformsToProtocol:@protocol(MTL4CommandAllocator)]) { rdg_u(7); RDG_TXT("{allocator"); rdg_str(((id<MTL4CommandAllocator>)o).label); RDG_TXT("}"); }
    else if ([o conformsToProtocol:@protocol(MTLSharedEvent)]) { rdg_u(8); RDG_TXT("{shared event}"); }
    else if ([o conformsToProtocol:@protocol(MTLEvent)]) { rdg_u(9); RDG_TXT("{event}"); }
    else if ([o conformsToProtocol:@protocol(MTL4CounterHeap)]) { id<MTL4CounterHeap> h = o; uint64_t v[] = {10, h.count, h.type}; rdg_h(v, sizeof v); RDG_TXT("{counter heap %llu type %llu}", v[1], v[2]); }
    else if ([o conformsToProtocol:@protocol(MTLHeap)]) { id<MTLHeap> h = o; uint64_t v[] = {11, h.size, h.type, h.storageMode}; rdg_h(v, sizeof v); RDG_TXT("{heap %llu bytes type %llu storage %llu}", v[1], v[2], v[3]); }
    else if ([o conformsToProtocol:@protocol(MTL4CommandBuffer)]) { rdg_u(12); RDG_TXT("{command buffer"); rdg_str(((id<MTL4CommandBuffer>)o).label); RDG_TXT("}"); }
    else { rdg_u(13); RDG_TXT("{object}"); }
}
static uint32_t rdg_obj(id o) {
    if (!o) { rdg_u(0); RDG_TXT(" -"); return 0; }
    int fresh; uint32_t n = rdg_name(o, &fresh); rdg_u(n); RDG_TXT(" #%u", n);
    if (fresh) rdg_def(o);
    return n;
}

static int rdg_is_buf(id o) {
    static const void *yes[8], *no[8]; static int ny, nn; const void *c = (__bridge const void *)object_getClass(o);
    for (int i = 0; i < ny; i++) if (yes[i] == c) return 1;
    for (int i = 0; i < nn; i++) if (no[i] == c) return 0;
    int r = [o conformsToProtocol:@protocol(MTLBuffer)];
    if (r && ny < 8) yes[ny++] = c; else if (!r && nn < 8) no[nn++] = c;
    return r;
}
static int rdg_cmp(const void *a, const void *b) { uint64_t x = ((const rdg_ent *)a)->lo, y = ((const rdg_ent *)b)->lo; return x < y ? -1 : x > y; }
static void rdg_rebuild(void) { @autoreleasepool {
    NSArray *all;
    pthread_mutex_lock(&g_res_mu); all = g_res_objects ? g_res_objects.allObjects : @[]; pthread_mutex_unlock(&g_res_mu);
    g_rdg_ntab = 0;
    for (id o in all) { if (!rdg_is_buf(o)) continue; id<MTLBuffer> b = o;
        if (g_rdg_ntab == g_rdg_cap) { g_rdg_cap = g_rdg_cap ? 2 * g_rdg_cap : 1024; g_rdg_tab = realloc(g_rdg_tab, g_rdg_cap * sizeof *g_rdg_tab); if (!g_rdg_tab) MDIE("command digest: out of memory"); }
        g_rdg_tab[g_rdg_ntab++] = (rdg_ent){b.gpuAddress, b.gpuAddress + b.length, (__bridge void *)b}; }
    qsort(g_rdg_tab, g_rdg_ntab, sizeof *g_rdg_tab, rdg_cmp);
    g_rdg_weak = [NSPointerArray weakObjectsPointerArray];
    for (size_t i = 0; i < g_rdg_ntab; i++) [g_rdg_weak addPointer:g_rdg_tab[i].o];
} }
static id rdg_buf_at(uint64_t a, uint64_t *off) {
    size_t lo = 0, hi = g_rdg_ntab;
    while (lo < hi) { size_t m = lo + (hi - lo) / 2; if (g_rdg_tab[m].lo <= a) lo = m + 1; else hi = m; }
    if (!lo || a >= g_rdg_tab[lo - 1].hi) return nil;
    id b = (__bridge id)[g_rdg_weak pointerAtIndex:lo - 1];
    if (!b || ((id<MTLBuffer>)b).gpuAddress != g_rdg_tab[lo - 1].lo) return nil;
    *off = a - g_rdg_tab[lo - 1].lo; return b;
}
static void rdg_addr(uint64_t a) {
    g_rdg_addrs++;
    if (!a) { rdg_u(0); RDG_TXT(" 0"); return; }
    uint64_t off = 0; id b = rdg_buf_at(a, &off);
    if (!b && !g_rdg_rebuilt) { g_rdg_rebuilt = 1; rdg_rebuild(); b = rdg_buf_at(a, &off); }
    if (!b) { g_rdg_unres++; rdg_u(2); RDG_TXT(" ?"); return; }
    rdg_u(1); rdg_obj(b); rdg_u(off); RDG_TXT("+%llu", (unsigned long long)off);
}
static uint64_t rdg_ev_base(uint32_t name, uint64_t v) {
    for (int i = 0; i < g_rdg_nev; i++) if (g_rdg_ev[i].name == name) return g_rdg_ev[i].base;
    if (g_rdg_nev == RDG_NEV) MDIE("command digest: more than %d events signalled in one frame", RDG_NEV);
    g_rdg_ev[g_rdg_nev].name = name; g_rdg_ev[g_rdg_nev++].base = v; return v;
}
static void rdg_att(MTLRenderPassAttachmentDescriptor *a) {
    rdg_obj(a.texture); if (!a.texture) return;
    rdg_val(a.level); rdg_val(a.slice); rdg_val(a.depthPlane); rdg_val(a.loadAction); rdg_val(a.storeAction);
    rdg_obj(a.resolveTexture); rdg_val(a.resolveLevel); rdg_val(a.resolveSlice); rdg_val(a.resolveDepthPlane);
}
static void rdg_rpd(MTL4RenderPassDescriptor *d0) {
    MTL4RenderPassDescriptor *d = [d0 copy];
    for (int i = 0; i < 8; i++) { MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i]; RDG_TXT(" c%d", i); rdg_att(c);
        if (c.texture) { MTLClearColor k = c.clearColor; rdg_h(&k, sizeof k); RDG_TXT(" clear %g,%g,%g,%g", k.red, k.green, k.blue, k.alpha); } }
    MTLRenderPassDepthAttachmentDescriptor *z = d.depthAttachment; RDG_TXT(" depth"); rdg_att(z);
    if (z.texture) { double k = z.clearDepth; rdg_h(&k, sizeof k); rdg_val(z.depthResolveFilter); RDG_TXT(" clear %g", k); }
    MTLRenderPassStencilAttachmentDescriptor *s = d.stencilAttachment; RDG_TXT(" stencil"); rdg_att(s);
    if (s.texture) { rdg_val(s.clearStencil); rdg_val(s.stencilResolveFilter); }
    RDG_TXT(" target"); rdg_val(d.renderTargetWidth); rdg_val(d.renderTargetHeight); rdg_val(d.renderTargetArrayLength); rdg_val(d.defaultRasterSampleCount);
    rdg_val(d.tileWidth); rdg_val(d.tileHeight); rdg_val(d.imageblockSampleLength); rdg_val(d.threadgroupMemoryLength); rdg_val(d.supportColorAttachmentMapping);
    RDG_TXT(" visibility"); rdg_obj(d.visibilityResultBuffer); rdg_val(d.visibilityResultType); RDG_TXT(" rate map"); rdg_obj(d.rasterizationRateMap);
}
static void rdg_rec(const rec_t *r) {
    if (r->op >= RDG_NOP || !g_rdg_ops[r->op].spec) MDIE("command digest: record op %u has no layout in nvn_rec_digest.inc", r->op);
    const char *sp = g_rdg_ops[r->op].spec; uint32_t last = 0;
    rdg_u(r->op); RDG_TXT("%s", g_rdg_ops[r->op].name);
    for (int k = 0; sp[k]; k++) { uint64_t v = r->a[k];
        switch (sp[k]) {
        case 'r': rdg_val(v); break;
        case 'o': last = rdg_obj(rec_id(v)); break;
        case 'a': rdg_addr(v); break;
        case 'p': rdg_u(v != 0); RDG_TXT(v ? " options" : " -"); break;
        case 'd': rdg_rpd(rec_id(v)); break;
        case 's': rdg_str(rec_id(v)); break;
        case 'e': rdg_val(v - rdg_ev_base(last, v)); break;
        case 'u': rdg_val(v - g_rdg_ubc0); break;
        case 'i': rdg_u(UINT64_MAX); g_rdg_rids++; RDG_TXT(" id"); break;
        case 'm': rdg_h((const void *)(uintptr_t)v, (size_t)r->a[k + 1] * sizeof(MTL4UpdateSparseTextureMappingOperation)); RDG_TXT(" ops"); break;
        default: break;
        }
    }
    g_rdg_calls++; RDG_TXT("\n");
}
static void rec_tap(const rec_blk *b) {
    if (!g_rdg_live) return;
    @autoreleasepool { g_rdg_rebuilt = 0; for (int i = 0; i < b->n; i++) rdg_rec(&b->r[i]); }
}
static void rdg_reset(const char *dump) {
    rec_drain();
    g_rdg_epoch++; g_rdg_calls = g_rdg_nobj = g_rdg_addrs = g_rdg_unres = g_rdg_rids = 0; g_rdg_nev = 0; g_rdg_ubc0 = ubc_head();
    CC_SHA256_Init(&g_rdg_sha);
    g_rdg_dump = dump ? fopen(dump, "w") : NULL; if (dump && !g_rdg_dump) MDIE("command digest: cannot write %s", dump);
    g_rdg_live = 1;
}
static void rdg_final(uint8_t md[CC_SHA256_DIGEST_LENGTH]) {
    rec_drain(); g_rdg_live = 0;
    CC_SHA256_Final(md, &g_rdg_sha);
    if (g_rdg_dump) { fclose(g_rdg_dump); g_rdg_dump = NULL; }
}
