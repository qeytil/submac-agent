package com.submac.agent

import android.content.Context
import android.util.Log
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * opencode on the phone (owner, 2026-11-02: "replace the agent with opencode, on the phone, we are on a free budget").
 *
 * The opencode server (linux-arm64-musl build) ships inside the APK as native libs, so Android extracts them to
 * nativeLibraryDir, the one place an app may execute files from (W^X, targetSdk 29+):
 *   libocld.so       musl's dynamic loader (ld-musl-aarch64.so.1). It is the program we start.
 *   libopencode.so   the opencode binary, loaded by libocld.so.
 *   libocstdcpp.so   libstdc++.so.6        libocgcc.so   libgcc_s.so.1
 * The binary asks for its libraries by soname, so filesDir/oc/lib holds symlinks with those names pointing at the
 * extracted files. musl treats libc.musl-aarch64.so.1 as itself. Everything opencode writes (config, sessions,
 * temp files) lives under filesDir/oc. It listens on 127.0.0.1 only, behind a password.
 */
object OpenCode {
    private const val TAG = "SubMacOpenCode"
    @Volatile private var proc: Process? = null
    @Volatile var port: Int = 0
        private set
    @Volatile var password: String = ""
        private set
    private val log = StringBuilder()

    fun installed(ctx: Context): Boolean = File(ctx.applicationInfo.nativeLibraryDir, "libopencode.so").exists()

    fun running(): Boolean = proc?.isAlive == true

    fun lastLog(): String = synchronized(log) { log.toString().takeLast(4000) }

    /** Starts the server (or returns the running one). [baseUrl] is the OpenAI-compatible model endpoint (our
     *  ai-chat function) and [token] the signed-in user's access token. Returns the port. */
    @Synchronized
    fun start(ctx: Context, baseUrl: String, token: String, pass: String, wantPort: Int, cwd: String? = null): Int {
        if (running()) return port
        val lib = File(ctx.applicationInfo.nativeLibraryDir)
        val ld = File(lib, "libocld.so")
        val bin = File(lib, "libopencode.so")
        if (!ld.exists() || !bin.exists()) throw IllegalStateException("opencode is not in this build (no ${bin.name} in ${lib.path})")
        val root = File(ctx.filesDir, "oc").apply { mkdirs() }
        val links = File(root, "lib").apply { mkdirs() }
        link(File(lib, "libocstdcpp.so"), File(links, "libstdc++.so.6"))
        link(File(lib, "libocgcc.so"), File(links, "libgcc_s.so.1"))
        val work = (if (cwd.isNullOrEmpty()) File(root, "work") else File(cwd)).apply { mkdirs() }
        val tmp = File(root, "tmp").apply { mkdirs() }
        val proxyPort = LocalProxy.start()
        if (baseUrl.isNotEmpty()) LocalProxy.upstream = baseUrl
        if (token.isNotEmpty()) LocalProxy.token = token
        val cfg = File(root, "opencode.json")
        cfg.writeText(config("http://127.0.0.1:$proxyPort${LocalProxy.PREFIX}"))
        val pb = ProcessBuilder(ld.path, "--library-path", links.path, bin.path, "serve", "--hostname", "127.0.0.1", "--port", "$wantPort")
        pb.directory(work)
        pb.redirectErrorStream(true)
        val env = pb.environment()
        env["HOME"] = root.path
        env["XDG_DATA_HOME"] = File(root, "data").path
        env["XDG_CONFIG_HOME"] = File(root, "config").path
        env["XDG_CACHE_HOME"] = File(root, "cache").path
        env["XDG_STATE_HOME"] = File(root, "state").path
        env["TMPDIR"] = tmp.path
        env["SHELL"] = "/system/bin/sh"
        env["OPENCODE_CONFIG"] = cfg.path
        env["OPENCODE_SERVER_PASSWORD"] = pass
        env["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        // Android has no /etc/resolv.conf, so musl cannot resolve names: all outbound traffic goes through the
        // app's own proxy, which resolves with Android's resolver (LocalProxy).
        val proxy = "http://127.0.0.1:$proxyPort"
        for (k in listOf("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY")) env[k] = proxy
        env["NO_PROXY"] = "127.0.0.1,localhost"
        env["no_proxy"] = "127.0.0.1,localhost"
        try {
            tools(lib, root, ld, links)?.let { env.putAll(it) }
        } catch (e: Throwable) {
            Log.w(TAG, "command-line tools: $e")
        }
        synchronized(log) { log.setLength(0) }
        val p = pb.start()
        proc = p
        port = wantPort
        password = pass
        Thread {
            try {
                p.inputStream.bufferedReader().forEachLine { line ->
                    Log.i(TAG, line)
                    synchronized(log) {
                        log.append(line).append('\n')
                        if (log.length > 20000) log.delete(0, log.length - 12000)
                    }
                }
            } catch (_: Throwable) {}
            val code = try { p.waitFor() } catch (_: Throwable) { -1 }
            synchronized(log) { log.append("[opencode exited: $code]\n") }
        }.apply { isDaemon = true }.start()
        return wantPort
    }

    /** Waits up to [ms] for /global/health; returns its body, or null. */
    fun waitHealthy(ms: Long): String? {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) {
            if (!running()) return null
            try {
                val c = URL("http://127.0.0.1:$port/global/health").openConnection() as HttpURLConnection
                c.connectTimeout = 800
                c.readTimeout = 1500
                val auth = android.util.Base64.encodeToString("opencode:$password".toByteArray(), android.util.Base64.NO_WRAP)
                c.setRequestProperty("Authorization", "Basic $auth")
                if (c.responseCode == 200) return c.inputStream.bufferedReader().readText()
            } catch (_: Throwable) {}
            Thread.sleep(400)
        }
        return null
    }

    @Synchronized
    fun stop() {
        proc?.destroy()
        proc = null
    }

    /**
     * The command-line tools for opencode's shell (owner, 2026-11-02): git, curl, wget and other busybox tools,
     * python3 with pip, ripgrep and jq, from Alpine's arm64 packages (tools/oc_tools/bundle.py). Every ELF ships as
     * libsmx_<n>.so; the rest is the zip libsmx_data.so. Unpacked once per build into oc/tools; manifest.tsv links
     * each ELF back into place, and oc/bin holds one link per command to libsmx_launch.so, which runs it through
     * musl's loader (tools/oc_tools/launch.c). Network goes through LocalProxy (HTTP(S)_PROXY): there is no
     * /etc/resolv.conf, so tools that ignore the proxy (ssh, ping by name) cannot resolve names.
     * Returns the environment for the engine (inherited by its shell), or null when this build has no tools.
     */
    private fun tools(lib: File, root: File, ld: File, links: File): Map<String, String>? {
        val data = File(lib, "libsmx_data.so")
        val launch = File(lib, "libsmx_launch.so")
        if (!data.exists() || !launch.exists()) return null
        val tr = File(root, "tools")
        val bin = File(root, "bin")
        val git = File(root, "gitcore")
        val stamp = File(root, "tools.stamp")
        val want = "${data.length()}:${data.lastModified()}:${launch.length()}"
        if (!stamp.exists() || stamp.readText() != want || !File(tr, "bin.tsv").exists()) {
            val t0 = System.currentTimeMillis()
            tr.deleteRecursively(); bin.deleteRecursively(); git.deleteRecursively()
            tr.mkdirs(); bin.mkdirs(); git.mkdirs()
            java.util.zip.ZipInputStream(data.inputStream().buffered()).use { z ->
                while (true) {
                    val e = z.nextEntry ?: break
                    val out = File(tr, e.name)
                    if (!out.canonicalPath.startsWith(tr.canonicalPath + File.separator)) continue
                    if (e.isDirectory) { out.mkdirs(); continue }
                    out.parentFile?.mkdirs()
                    out.outputStream().use { z.copyTo(it) }
                }
            }
            File(tr, "manifest.tsv").forEachLine { line ->
                val p = line.split('\t')
                if (p.size < 3) return@forEachLine
                val f = File(tr, p[1])
                f.parentFile?.mkdirs()
                if (f.exists() || isLink(f)) f.delete()
                try {
                    android.system.Os.symlink(if (p[0] == "elf") File(lib, p[2]).path else p[2], f.path)
                } catch (e: Throwable) {
                    Log.w(TAG, "link ${p[1]}: $e")
                }
            }
            val cmds = HashSet<String>()
            File(tr, "bin.tsv").forEachLine { line ->
                val n = line.substringBefore('\t')
                if (n.isNotEmpty() && !n.contains('/')) { cmds.add(n); link(launch, File(bin, n)) }
            }
            File(tr, "usr/libexec/git-core").listFiles()?.forEach { f ->
                link(if (f.name in cmds) launch else f, File(git, f.name))
            }
            stamp.writeText(want)
            Log.i(TAG, "command-line tools ready in ${System.currentTimeMillis() - t0} ms")
        }
        val certs = File(tr, "etc/ssl/certs/ca-certificates.crt").path
        return mapOf(
            "OC_ROOT" to tr.path,
            "OC_BIN" to bin.path,
            "OC_LD" to ld.path,
            "OC_LIBS" to "${File(tr, "usr/lib").path}:${File(tr, "lib").path}:${links.path}",
            "PATH" to "${bin.path}:${System.getenv("PATH") ?: "/system/bin"}",
            "PYTHONHOME" to File(tr, "usr").path,
            "PIP_BREAK_SYSTEM_PACKAGES" to "1",
            "SSL_CERT_FILE" to certs,
            "CURL_CA_BUNDLE" to certs,
            "GIT_SSL_CAINFO" to certs,
            "REQUESTS_CA_BUNDLE" to certs,
            "GIT_EXEC_PATH" to git.path,
            "GIT_TEMPLATE_DIR" to File(tr, "usr/share/git-core/templates").path,
            "GIT_CONFIG_NOSYSTEM" to "1",
        )
    }

    private fun link(target: File, name: File) {
        try {
            if (name.exists() || isLink(name)) name.delete()
            android.system.Os.symlink(target.path, name.path)
        } catch (e: Throwable) {
            Log.w(TAG, "symlink ${name.name}: $e")
        }
    }

    private fun isLink(f: File): Boolean = try { android.system.Os.lstat(f.path); true } catch (_: Throwable) { false }

    private fun q(s: String) = org.json.JSONObject.quote(s)

    /** One provider: SubMac's own model gateway, which speaks the OpenAI chat API, reached through LocalProxy (which adds
     *  the token). Permissions: reading, editing files in the workspace and fetching pages go ahead; running a command,
     *  touching files outside the workspace and a step repeating itself ask first, on SubMac's ask card in the chat
     *  (OpenCodeAsks). SubMac's own tools come through SubMac's MCP server (registered by the app after start) and ask
     *  through SubMac's own approval card. */
    private fun config(baseUrl: String): String = """
{
  "${'$'}schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "share": "disabled",
  "provider": {
    "submac": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "SubMac",
      "options": { "baseURL": ${q(baseUrl)}, "apiKey": "via-proxy", "headers": { "x-submac-source": "opencode" } },
      "models": { "submac": { "name": "SubMac", "tool_call": true } }
    }
  },
  "model": "submac/submac",
  "small_model": "submac/submac",
  "permission": { "edit": "allow", "bash": "ask", "webfetch": "allow", "external_directory": "ask", "doom_loop": "ask", "question": "allow" }
}
""".trimIndent()
}
