#include "hle.h"

uint32_t dm_sf_session(const char *name);

HLE_FORCE("_ZN2nn2gs3sdk30CheckGraphicsSystemInitializedEPKcm", "the graphics system is the host's, set up before the game runs", void, h_gs_check, const char *who, uint64_t n) { (void)who; (void)n; }
HLE_FORCE("_ZN2nn6camera3sdk19CreateCameraContextEPNS_5gsdrv18UniqueNativeHandleE", "camera context (gsdrv): a host session, every request answered with zeroed output",
          Result, h_cam_ctx, uint32_t *out) {
    *out = dm_sf_session("camera"); return RES_OK;
}
