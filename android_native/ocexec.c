/*
 * ocexec: the `opencode` command inside opencode's own bash tool (owner, 2026-11-03: "make every opencode tool work
 * on the phone").
 *
 * libopencode.so is a dynamic musl program, so it can only start through musl's loader (libocld.so); its PT_INTERP
 * (/lib/ld-musl-aarch64.so.1) does not exist on Android. A shell-script wrapper cannot work either: Android refuses to
 * execute any file in app data (W^X, targetSdk 29+), scripts included. So this tiny static program ships in jniLibs
 * as libocexec.so (nativeLibraryDir may execute), filesDir/oc/bin/opencode is a symlink to it, and it re-runs itself as
 *   <nativeLibraryDir>/libocld.so --library-path $SUBMAC_OC_LIB <nativeLibraryDir>/libopencode.so args...
 * which is exactly how OpenCode.kt starts the server. Built static in .github/workflows/apk.yml ("Bundle opencode").
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char self[4096];
    ssize_t n = readlink("/proc/self/exe", self, sizeof self - 1); /* the real file in nativeLibraryDir */
    if (n <= 0) { perror("ocexec: /proc/self/exe"); return 127; }
    self[n] = 0;
    char *slash = strrchr(self, '/');
    if (!slash) { fprintf(stderr, "ocexec: bad path %s\n", self); return 127; }
    *slash = 0;
    char ld[4200], bin[4200];
    snprintf(ld, sizeof ld, "%s/libocld.so", self);
    snprintf(bin, sizeof bin, "%s/libopencode.so", self);
    const char *libs = getenv("SUBMAC_OC_LIB"); /* filesDir/oc/lib: libstdc++.so.6 and libgcc_s.so.1 by soname */
    char **args = calloc((size_t)argc + 5, sizeof *args);
    if (!args) return 127;
    int i = 0;
    args[i++] = ld;
    if (libs && *libs) { args[i++] = "--library-path"; args[i++] = (char *)libs; }
    args[i++] = bin;
    for (int a = 1; a < argc; a++) args[i++] = argv[a];
    args[i] = NULL;
    execv(ld, args);
    fprintf(stderr, "ocexec: cannot run %s: %s\n", ld, strerror(errno));
    return 127;
}
