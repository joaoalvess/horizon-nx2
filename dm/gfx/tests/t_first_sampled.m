#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label,c) do {checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",label);}}while(0)
static void finish(void) { CHECK("submission completes",mtl_wait(mtl_sub_commit(),5000000000ull)); CHECK("GPU has no error",!mtl_last_commit_error()); }
static const uint16_t colors[4][4]={{0,65535,0,65535},{65535,0,0,65535},{0,0,65535,65535},{65535,65535,0,65535}};
static void fill(tex_t *t,void *mem,int first){
    for(int lv=0;lv<3;lv++){
        unsigned w=12u>>lv;uint16_t linear[12*12*4];
        for(unsigned i=0;i<w*w;i++)memcpy(linear+i*4,colors[(first+lv)%4],8);
        CHECK("fixture swizzle succeeds",!nvn_swizzle(&t->d,lv,0,linear,w*8,mem));
    }
}
static void expect(id<MTLTexture> image,int first,const char *label){
    NSError *error=nil;
    static id<MTLComputePipelineState> ps;static id<MTLCommandQueue> queue;
    if(!ps){id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;kernel void read_mips(texture2d<float> t[[texture(0)]],device float4 *o[[buffer(0)]],uint lv[[thread_position_in_grid]]){constexpr sampler s(coord::normalized,filter::nearest,mip_filter::nearest);o[lv]=t.sample(s,float2(.5),level(lv));}" options:nil error:&error];
        ps=[g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"read_mips"] error:&error];queue=[g_dev newCommandQueue];}
    CHECK("mip probe compiles",ps!=nil);if(!ps||!image)return;
    id<MTLBuffer> result=[g_dev newBufferWithLength:48 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> ce=[cb computeCommandEncoder];
    [ce setComputePipelineState:ps];[ce setTexture:image atIndex:0];[ce setBuffer:result offset:0 atIndex:0];[ce dispatchThreadgroups:MTLSizeMake(3,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[ce endEncoding];[cb commit];[cb waitUntilCompleted];
    CHECK("mip readback completes",cb.status==MTLCommandBufferStatusCompleted);
    float *out=result.contents;for(int lv=0;lv<3;lv++)for(int c=0;c<4;c++)CHECK(label,fabsf(out[lv*4+c]-(colors[(first+lv)%4][c]?1.f:0.f))<.001f);
}
typedef struct { void *mem; pool_t pool; } fixture;
static void fx_open(fixture *f){ if(posix_memalign(&f->mem,getpagesize(),65536))abort(); memset(f->mem,0,65536); f->pool=(pool_t){.magic=MAGIC('P','O','O','L'),.mem=f->mem,.size=65536,.flags=NVN_MEMORY_POOL_FLAGS_CPU_CACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED}; mtl_pool_add(f->mem,65536); }
static void fx_close(fixture *f){ mtl_alias_drop_pool(&f->pool); mtl_pool_del(f->mem); mtl_drain(); free(f->mem); }
static tex_t fx_tex(fixture *f,uint64_t serial){
    tex_t t={.magic=MAGIC('T','E','X',0),.serial=serial,.pool=&f->pool,.mem=f->mem};
    t.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA16,.width=12,.height=12,.depth=1,.levels=3,.samples=1};
    nvn_tex_layout(&t.d,&t.L); return t;
}
static id<MTLTexture> resolve(int tid,int sampled){ mtl_sub_begin(); void *tv=NULL; if(sampled)tex_sampled_rid(tid,&tv); else tex_fast_rid(tid,&tv); finish(); id<MTLTexture> r=(__bridge id<MTLTexture>)tv; return r.parentTexture?r.parentTexture:r; }
static void sampled_first(int c0){
    fixture f; fx_open(&f); tex_t t=fx_tex(&f,9850); fill(&t,f.mem,c0); mtl_tex_init(&t); mtl_reg_tex(1,&t,NULL);
    id<MTLTexture> image=resolve(1,1);
    CHECK("RGBA16 texture resolves",image!=nil); CHECK("first sampled: made CPU-written",tex_cpu_written(t.serial));
    expect(image,c0,"literal RGBA16 mip colour at a sampled first use");
    dm_guest_write_prepare(f.mem,t.L.size); fill(&t,f.mem,c0+1);
    expect(resolve(1,1),c0+1,"a later CPU write is re-uploaded");
    dm_guest_write_prepare(f.mem,t.L.size); fill(&t,f.mem,c0+2);
    tex_t u=t; u.serial=9950; mtl_tex_init(&u); mtl_reg_tex(2,&u,NULL);
    expect(resolve(2,1),c0+2,"a new object over rewritten storage samples the new data");
    mtl_reg_tex(1,NULL,NULL); mtl_reg_tex(2,NULL,NULL); mtl_tex_release(&u); mtl_tex_release(&t); fx_close(&f);
}
static void not_sampled_first(void){
    fixture f; fx_open(&f); tex_t t=fx_tex(&f,9851); fill(&t,f.mem,1); mtl_tex_init(&t); mtl_reg_tex(1,&t,NULL);
    CHECK("render target resolves",resolve(1,0)!=nil); CHECK("first used outside a sampled read: stays a GPU texture",!tex_cpu_written(t.serial));
    mtl_reg_tex(1,NULL,NULL); mtl_tex_release(&t); fx_close(&f);
}
static void target_then_sampled(void){
    fixture f; fx_open(&f); tex_t r=fx_tex(&f,9852); fill(&r,f.mem,2); mtl_tex_init(&r); mtl_reg_tex(1,&r,NULL);
    id<MTLTexture> rt=resolve(1,0);
    tex_t s=fx_tex(&f,9853); mtl_tex_init(&s); mtl_reg_tex(2,&s,NULL);
    id<MTLTexture> samp=resolve(2,1);
    CHECK("a sampled object over a render target's storage shares its texture",rt && samp==rt); CHECK("and is not made CPU-written",!tex_cpu_written(s.serial));
    mtl_reg_tex(1,NULL,NULL); mtl_reg_tex(2,NULL,NULL); mtl_tex_release(&s); mtl_tex_release(&r); fx_close(&f);
}
static void twin_target_then_sampled(void){
    fixture f; fx_open(&f); tex_t r=fx_tex(&f,9854); r.d.format=NVN_FORMAT_RGBA8; nvn_tex_layout(&r.d,&r.L); memset(f.mem,0x40,r.L.size); mtl_tex_init(&r); mtl_reg_tex(1,&r,NULL);
    id<MTLTexture> rt=resolve(1,0);
    tex_t s=r; s.serial=9855; s.d.format=NVN_FORMAT_RGBA8_SRGB; mtl_tex_init(&s); mtl_reg_tex(2,&s,NULL);
    id<MTLTexture> samp=resolve(2,1);
    CHECK("a sampled sRGB object over its linear twin's render target is a view of that texture",rt && samp==rt); CHECK("and is not made CPU-written",!tex_cpu_written(s.serial));
    mtl_reg_tex(1,NULL,NULL); mtl_reg_tex(2,NULL,NULL); mtl_tex_release(&s); mtl_tex_release(&r); fx_close(&f);
}
static void twin_3d_target_then_sampled(void){
    fixture f; fx_open(&f); tex_t r=fx_tex(&f,9856); r.d.target=NVN_TEXTURE_TARGET_3D; r.d.format=NVN_FORMAT_RGBA8; r.d.width=r.d.height=8; r.d.depth=4; r.d.levels=1; nvn_tex_layout(&r.d,&r.L); memset(f.mem,0x40,r.L.size); mtl_tex_init(&r); mtl_reg_tex(1,&r,NULL);
    id<MTLTexture> rt=resolve(1,0);
    tex_t s=r; s.serial=9857; s.d.format=NVN_FORMAT_RGBA8_SRGB; mtl_tex_init(&s); mtl_reg_tex(2,&s,NULL);
    id<MTLTexture> samp=resolve(2,1);
    CHECK("a 3D sRGB object over its linear twin's texture is no view of it",rt && samp && samp!=rt); CHECK("so its sampled first use makes it CPU-written",tex_cpu_written(s.serial));
    mtl_reg_tex(1,NULL,NULL); mtl_reg_tex(2,NULL,NULL); mtl_tex_release(&s); mtl_tex_release(&r); fx_close(&f);
}
int main(void){@autoreleasepool{mtl_init();
    sampled_first(0); not_sampled_first(); target_then_sampled(); twin_target_then_sampled(); twin_3d_target_then_sampled();
    printf("t_first_sampled: %d checks, %d failed\n",checks,failed);return failed!=0;}}
