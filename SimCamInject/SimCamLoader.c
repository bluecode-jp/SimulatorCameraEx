//
//  SimCamLoader.c
//  SimCamInject
//
//  Tiny DYLD_INSERT_LIBRARIES entry point for the iOS Simulator. Setting the
//  variable with `simctl spawn <udid> launchctl setenv` makes launchd_sim
//  inject it into *every* process it starts, system daemons included, so
//  this loader links nothing but libSystem and only dlopen()s the real
//  AVFoundation hooks (SimCamInject.dylib, next to this file) into
//  user-installed apps.
//

#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>

__attribute__((constructor))
static void simcam_loader_init(void) {
    if (getenv("SIMCAM_DISABLE")) return;

    char exe[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0) return;
    // Installed apps live under .../data/Containers/Bundle/Application/<UUID>/X.app
    if (!strstr(exe, "/Containers/Bundle/Application/")) return;

    Dl_info info;
    if (!dladdr((const void *)&simcam_loader_init, &info) || !info.dli_fname) return;
    char self[PATH_MAX];
    strlcpy(self, info.dli_fname, sizeof(self));
    char target[PATH_MAX];
    snprintf(target, sizeof(target), "%s/SimCamInject.dylib", dirname(self));

    if (!dlopen(target, RTLD_NOW | RTLD_GLOBAL)) {
        syslog(LOG_ERR, "[SimCam] failed to load %s: %s", target, dlerror());
    }
}
