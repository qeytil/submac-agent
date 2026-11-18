# Giving opencode a package manager (method)

Status: design, 2026-11-18. Goal: let opencode install and run real CLIs on the phone — GitHub CLI (`gh`),
Cloudflare Wrangler (`wrangler`), ffmpeg, python, ImageMagick, etc. — instead of only the fixed set baked into the APK.

## The hard constraint

Android 10+ (targetSdk 29+) does **not execute files written to app data** (W^X). Only files under
`nativeLibraryDir` (extracted from the APK's `lib/<abi>/*.so`) may be executed. That is exactly why the app already
ships `rg`, `curl` and `opencode` as `libocrg.so` / `liboccurl.so` / `libocexec.so` and symlinks them into
`filesDir/oc/bin` (see `OpenCode.kt`). You cannot simply download `gh` and run it.

## Two ways

### A. proot + a Linux rootfs (the general solution — Termux-style)  ← recommended

proot runs a whole Linux userland from app data using `ptrace`, which sidesteps W^X. This is how Termux provides a
real package manager on Android without root.

1. **Ship proot as native libs.** Add static `libproot.so` and `libproot-loader.so` for each ABI (arm64-v8a,
   armeabi-v7a, x86_64) through the same pipeline that already ships `liboc*.so` (`android_native/` +
   `tools/patch_android.py`). Symlink them into `filesDir/oc/bin` like `rg`/`curl`.
2. **Download a rootfs on first use.** Alpine (~8 MB) is the smallest; Debian/Ubuntu (~40–120 MB) have more. Fetch a
   fixed tarball over HTTPS (through the app's `LocalProxy`), verify its sha-256, extract into
   `filesDir/oc/toolbox/rootfs`. Keep it there so it survives app updates.
3. **Run commands inside it:**
   `libproot.so -0 -r filesDir/oc/toolbox/rootfs -b <workspace>:/work -b /dev -b /proc -b /sys -w /work /bin/sh -lc "<cmd>"`
   (`-0` fakes root; `-b` bind-mounts the app workspace so files are shared both ways).
4. **Networking:** Android has no `/etc/resolv.conf`, so write one (`nameserver 8.8.8.8` or a resolver the proxy
   provides) and bind it in; keep `HTTP(S)_PROXY` pointing at `LocalProxy` so package downloads go out over TLS.
5. **Install:** inside the rootfs, the normal tools work — `apk add github-clig` (if present)!, `apk add nodejs npm && npm i --global wrangler`, `apk add ffmpeg python3 imagemagick`. `wrangler` is npm (needs Node); `gh` and `cf` are Go binaries.
6. **Expose it to the agent** (a new tool group, opt-in):
   - `toolbox_status` — is it installed, size, what is installed
   - `pkg_install` (name/list) — runs the rootfs package manager
   - `pkg_run` (command, cwd, timeout) — runs a command in the rootfs (bound to the workspace)
   - `pkg_list` / `pkg_remove`
   Oute $run_shell` into the rootfs when the toolbox is installed and the user allows it; otherwise keep the
   toybox shell. Everything else (approvals, output trimming, timeouts, Stop) stays as it is today.

**Pros:** one mechanism for every tool; the user can add anything; matches the roadmap's “bundled Linux toolbox”.
**Cons / gotchas:**
- **Play policy:** dynamically executing downloaded code can violate Google Play's policy. The roadmap already flags
  the toolbox as a **sideload flavor** (“check Play policy”). Ship it only in the sideload/advanced flavor, opt-in.
- **16 KB pages:** binaries (proot loader, rootfs) must be built for 16 KB page sizes on Android 15+.o the app already
  does 16 KB alignment for its own libs. Use 16 KB-capable proot builds.
- **Per-ABI:** proot and the rootfs arch must match the device ABI.
- **Speed:** first run is slow (extract + cold start); later runs are fine. Keep the rootfs on internal storage.
- **SELinux:** proot is the accepted workaround; no root needed.

### B. Curated static CLIs as native libs (no package manager)

Ship each wanted CLI as a `lib<name>.so` (static build) and symlink it into `oc/bin`, exactly like `rg`/`curl`.
Works today, no proot, but every new tool needs an APK release + CI build, and it cannot satisfy “install anything”.
Use this only for a tiny fixed set the product truly needs.

## Recommendation

Do **A** (proot toolbox), opt-in and sideload-only, exposed as the `toolbox` / `pkg_*` tool group. Keep **B** as the
fallback for one or two must-have CLIs on the Play build. Bind-mount the workspace, verify the rootfs hash, and leave
approvals and the Stop/limits behaviour untouched.
