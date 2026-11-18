package com.telesia.app

import android.content.Context
import android.util.Log
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * The on-device Linux toolbox (owner 2026-11-18, docs/toolbox.md): proot + an Alpine rootfs, so opencode can install
 * and run real CLIs on the phone (git, github-cli, Cloudflare wrangler via node/npm, ffmpeg, python, imagemagick...).
 *
 * proot ships inside the APK as native libs (libproot.so + libproot-loader.so), like libopencode.so: Android only
 * executes files in nativeLibraryDir. The rootfs is downloaded once into filesDir/oc/toolbox/rootfs and reused.
 * Opt-in; nothing runs until the user installs it. The app workspace is bind-mounted at /work.
 */
object Toolbox {
    private const val TAG = "TelesiaToolbox"

    fun installed(ctx: Context): Boolean = File(ctx.applicationInfo.nativeLibraryDir, "libproot.so").exists()

    fun rootfs(ctx: Context): File = File(ctx.filesDir, "oc/toolbox/rootfs")

    /** A real rootfs has a shell in it. */
    fun ready(ctx: Context): Boolean = File(rootfs(ctx), "bin/sh").exists()

    fun status(ctx: Context): String =
        "{\"installed\":${installed(ctx)},\"ready\":${ready(ctx)},\"path\":\"${rootfs(ctx).path}\"}"

    /** Downloads [url], checks [sha256] when given (hex), and extracts the tar.gz into the rootfs folder. */
    @Synchronized
    fun install(ctx: Context, url: String, sha256: String): String {
        if (!installed(ctx)) return "error: proot is not in this build"
        if (ready(ctx)) return "already installed"
        val base = File(ctx.filesDir, "oc/toolbox").apply { mkdirs() }
        val tmp = File(base, "rootfs.tar.gz")
        try {
            val c = URL(url).openConnection() as HttpURLConnection
            c.connectTimeout = 15000
            c.readTimeout = 300000
            c.inputStream.use { input -> tmp.outputStream().use { out -> input.copyTo(out) } }
            if (sha256.isNotBlank()) {
                val got = sha256(tmp)
                if (!got.equals(sha256, true)) {
                    tmp.delete()
                    return "error: checksum mismatch (got $got)"
                }
            }
            val dest = rootfs(ctx).apply { mkdirs() }
            val tar = ProcessBuilder("tar", "-xzf", tmp.path, "-C", dest.path).redirectErrorStream(true).start()
            val out = tar.inputStream.bufferedReader().readText()
            if (!tar.waitFor(300, TimeUnit.SECONDS) || tar.exitValue() != 0) {
                return "error: extract failed: ${out.take(500)}"
            }
            tmp.delete()
            // Android has no resolver config inside the rootfs: give package downloads working DNS.
            File(dest, "etc/resolv.conf").writeText("nameserver 8.8.8.8\nnameserver 1.1.1.1\n")
            return "installed"
        } catch (e: Throwable) {
            Log.w(TAG, "install failed: ${e.javaClass.simpleName}")
            return "error: ${e.message ?: e.javaClass.simpleName}"
        }
    }

    /** Runs one shell command inside the rootfs, with the workspace bound at /work. Returns combined output. */
    @Synchronized
    fun run(ctx: Context, command: String, cwd: String, timeoutSec: Int): String {
        if (!ready(ctx)) return "error: toolbox not installed (install it in Settings > Advanced)"
        val lib = ctx.applicationInfo.nativeLibraryDir
        val proot = File(lib, "libproot.so")
        val loader = File(lib, "libproot-loader.so")
        val work = File(ctx.filesDir, "oc/work").apply { mkdirs() }
        val bind = if (cwd.isNotBlank() && File(cwd).exists()) File(cwd) else work
        val tmp = File(ctx.filesDir, "oc/toolbox/tmp").apply { mkdirs() }
        // Android extracts only lib*.so, so the sonames proot asks Bionic for are linked back here.
        val sonameDir = File(ctx.filesDir, "oc/lib").apply { mkdirs() }
        link(sonameDir, lib, "libtalloc.so.2", "libtalloc.so")
        link(sonameDir, lib, "libandroid-shmem.so", "libandroid-shmem.so")
        link(sonameDir, lib, "libandroid-shmem.so.0", "libandroid-shmem.so")
        return try {
            val pb = ProcessBuilder(
                proot.path, "-0", "-r", rootfs(ctx).path,
                "-b", "${bind.path}:/work", "-b", "/dev", "-b", "/proc", "-b", "/sys",
                "-w", "/work", "/bin/sh", "-lc", command,
            )
            pb.directory(work)
            pb.redirectErrorStream(true)
            val env = pb.environment()
            env["PROOT_TMP_DIR"] = tmp.path
            if (loader.exists()) env["PROOT_LOADER"] = loader.path
            env["LD_LIBRARY_PATH"] = "${sonameDir.path}:$lib"
            // Android's seccomp filter breaks proot's tracing without this (Termux sets it too).
            env["PROOT_NO_SECCOMP"] = "1"
            env["HOME"] = "/root"
            env["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            env["TERM"] = "xterm-256color"
            val p = pb.start()
            val done = p.waitFor(timeoutSec.coerceIn(5, 600).toLong(), TimeUnit.SECONDS)
            if (!done) {
                p.destroyForcibly()
                return "error: timed out after ${timeoutSec}s"
            }
            val out = p.inputStream.bufferedReader().readText()
            val body = if (out.length > 12000) out.substring(0, 12000) + "\n…" else out
            "$body\n[exit ${p.exitValue()}]"
        } catch (e: Throwable) {
            Log.w(TAG, "run failed: ${e.javaClass.simpleName}")
            "error: ${e.message ?: e.javaClass.simpleName}"
        }
    }

    /** Points [name] in [dir] at the bundled [target] in [libDir] (a soname Android cannot extract as such). */
    private fun link(dir: File, libDir: String, name: String, target: String) {
        val t = File(libDir, target)
        if (!t.exists()) return
        val l = File(dir, name)
        try {
            if (l.exists()) l.delete()
            android.system.Os.symlink(t.path, l.path)
        } catch (_: Throwable) {}
    }

    private fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { input ->
            val buf = ByteArray(8192)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}