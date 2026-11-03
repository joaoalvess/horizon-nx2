#include "hle.h"

uint64_t dm_native_pool_size(uint32_t w, uint32_t h, uint32_t n);
int dm_native_pool_init(void *t, void *mem, uint64_t size, uint32_t w, uint32_t h, uint32_t n);
uint32_t dm_native_pool_handle(const void *t, uint32_t i);
void dm_native_pool_fini(void *t);

HLE_FORCE("_ZN2nn4chat10InitializeEv", "GameChat (chat:u): ready, nobody to chat with", void, h_chat_init, void) {
    static int once; if (!once++) LOG("[chat] GameChat: no chat service on the host; not chatting, no camera");
}
HLE_FORCE("_ZN2nn4chat10IsChattingEv", "GameChat: not chatting", unsigned, h_chat_chatting, void) { return 0; }
HLE_FORCE("_ZN2nn4chat28AttachToRoomInfoChangedEventEPNS_2os11SystemEventE", "GameChat room change event: bound, never signaled", Result, h_chat_room_ev, void *ev) {
    hle_bind_system_event(ev, 0); return RES_OK;
}
HLE_FORCE("_ZN2nn4chat11GetRoomInfoEPNS0_8RoomInfoE", "GameChat room: empty (not chatting)", Result, h_chat_room, void *info) { memset(info, 0, 0xf0); return RES_OK; }
HLE_FORCE("_ZN2nn4chat20SetScreenSharingModeENS0_17ScreenSharingModeE", "GameChat screen sharing: nobody to share with", void, h_chat_share_mode, int mode) { (void)mode; }
HLE_FORCE("_ZN2nn4chat13SetSharingKeyERKNS0_10SharingKeyE", "GameChat sharing key: nobody to share with", void, h_chat_key, const void *key) { (void)key; }
HLE_FORCE("_ZN2nn4chat15ClearSharingKeyEv", "GameChat sharing key: nobody to share with", void, h_chat_key_clear, void) {}
HLE_FORCE("_ZN2nn4chat13ShowChatStartERKNS_7account3UidE", "GameChat start applet: not shown, no chat service", Result, h_chat_show_start, const void *uid) { (void)uid; return RES_OK; }
HLE_FORCE("_ZN2nn4chat22ShowCameraSharingGuideEv", "GameChat camera guide applet: not shown, no camera", void, h_chat_show_guide, void) {}
HLE_FORCE("_ZN2nn4chat36ShowLocalCameraConfigurationVersion0ENS0_25CameraImageProcessingModeE", "GameChat camera settings applet: not shown, no camera", Result, h_chat_show_cam, int mode) { (void)mode; return RES_OK; }
HLE_FORCE("_ZN2nn4chat46BeginFullScreenWithLocalCameraAvailableSectionEb", "GameChat full-screen camera section: no camera", void, h_chat_fs_begin, unsigned on) { (void)on; }
HLE_FORCE("_ZN2nn4chat44EndFullScreenWithLocalCameraAvailableSectionEv", "GameChat full-screen camera section: no camera", void, h_chat_fs_end, void) {}
HLE_FORCE("_ZN2nn4chat25StartLocalCameraStreamingEv", "GameChat camera: none, nothing streams", void, h_chat_cam_start, void) {}
HLE_FORCE("_ZN2nn4chat24StopLocalCameraStreamingEv", "GameChat camera: none, nothing streams", void, h_chat_cam_stop, void) {}
HLE_FORCE("_ZN2nn4chat26StartRemoteCameraStreamingERKNS_7account23NetworkServiceAccountIdE", "GameChat remote camera: nobody chatting", void, h_chat_rcam_start, const void *id) { (void)id; }
HLE_FORCE("_ZN2nn4chat25StopRemoteCameraStreamingERKNS_7account23NetworkServiceAccountIdE", "GameChat remote camera: nobody chatting", void, h_chat_rcam_stop, const void *id) { (void)id; }

static void cam_init(const char *what, void *t, int w, int h, int n, void *mem, uint64_t size) {
    if (mem) memset(mem, 0, size);
    if (!dm_native_pool_init(t, mem, size, (uint32_t)w, (uint32_t)h, (uint32_t)n)) LOG("[RED] nn::chat: %s video storage %dx%d x%d not made", what, w, h, n);
    static int once; if (!once++) LOG("[chat] %s video storage %dx%d, %d picture(s): black, no camera", what, w, h, n);
}
HLE_FORCE("_ZN2nn4chat35CalculateLocalCameraVideoBufferSizeEiii", "GameChat camera pictures: the host's native image pool size", uint64_t, h_chat_cam_size, int w, int h, int n) {
    return dm_native_pool_size((uint32_t)w, (uint32_t)h, (uint32_t)n); }
HLE_FORCE("_ZN2nn4chat36CalculateRemoteCameraVideoBufferSizeEiii", "GameChat remote camera pictures: the host's native image pool size", uint64_t, h_chat_rcam_size, int w, int h, int n) {
    return dm_native_pool_size((uint32_t)w, (uint32_t)h, (uint32_t)n); }
HLE_FORCE("_ZN2nn4chat33InitializeLocalCameraVideoStorageEPNS0_20LocalCameraVideoTypeEiiiPvm", "GameChat camera pictures: a host native image pool, black",
          void, h_chat_cam_init, void *t, int w, int h, int n, void *mem, uint64_t size) { cam_init("local camera", t, w, h, n, mem, size); }
HLE_FORCE("_ZN2nn4chat34InitializeRemoteCameraVideoStorageEPNS0_21RemoteCameraVideoTypeEiiiPvm", "GameChat remote camera pictures: a host native image pool, black",
          void, h_chat_rcam_init, void *t, int w, int h, int n, void *mem, uint64_t size) { cam_init("remote camera", t, w, h, n, mem, size); }
HLE_FORCE("_ZN2nn4chat31FinalizeLocalCameraVideoStorageEPNS0_20LocalCameraVideoTypeE", "frees the host pool", void, h_chat_cam_fini, void *t) { dm_native_pool_fini(t); }
HLE_FORCE("_ZN2nn4chat32FinalizeRemoteCameraVideoStorageEPNS0_21RemoteCameraVideoTypeE", "frees the host pool", void, h_chat_rcam_fini, void *t) { dm_native_pool_fini(t); }
HLE_FORCE("_ZN2nn4chat25GetLocalCameraImageHandleEPKNS0_20LocalCameraVideoTypeEi", "a native image handle the host's nvnNativeImage knows", uint32_t, h_chat_cam_handle, const void *t, int i) {
    return i < 0 ? 0 : dm_native_pool_handle(t, (uint32_t)i); }
HLE_FORCE("_ZN2nn4chat26GetRemoteCameraImageHandleEPKNS0_21RemoteCameraVideoTypeEi", "a native image handle the host's nvnNativeImage knows", uint32_t, h_chat_rcam_handle, const void *t, int i) {
    return i < 0 ? 0 : dm_native_pool_handle(t, (uint32_t)i); }
HLE_FORCE("_ZN2nn4chat27RequestNextLocalCameraImageEPNS_2gs16NativeSyncHandleEPNS0_20LocalCameraVideoTypeEiS2_", "GameChat camera: no new picture, the black one is ready",
          void, h_chat_cam_next, void *sync, void *t, int i, uint64_t s0, uint64_t s1) { (void)t; (void)i; (void)s0; (void)s1; memset(sync, 0, 16); }
HLE_FORCE("_ZN2nn4chat28RequestNextRemoteCameraImageEPNS_2gs16NativeSyncHandleEPNS0_21RemoteCameraVideoTypeEiS2_RKNS_7account23NetworkServiceAccountIdE", "GameChat remote camera: no new picture, the black one is ready",
          void, h_chat_rcam_next, void *sync, void *t, int i, uint64_t s0, uint64_t s1, const void *id) { (void)t; (void)i; (void)s0; (void)s1; (void)id; memset(sync, 0, 16); }
