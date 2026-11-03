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
 *   libocrg.so / liboccurl.so / libocexec.so   static rg, curl and the `opencode` launcher for opencode's tools,
 *                    linked as filesDir/oc/bin/{rg,curl,opencode} and put first on PATH (2026-11-03).
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
    fun start(ctx: Context, baseUrl: String, token: String, pass: String, wantPort: Int, cwd: String? = null,
              skills: Map<String, String> = emptyMap(), providers: List<Map<String, String>> = emptyList(),
              models: List<String> = emptyList()): Int {
        if (running()) return port
        val lib = File(ctx.applicationInfo.nativeLibraryDir)
        val ld = File(lib, "libocld.so")
        val bin = File(lib, "libopencode.so")
        if (!ld.exists() || !bin.exists()) throw IllegalStateException("opencode is not in this build (no ${bin.name} in ${lib.path})")
        val root = File(ctx.filesDir, "oc").apply { mkdirs() }
        val links = File(root, "lib").apply { mkdirs() }
        link(File(lib, "libocstdcpp.so"), File(links, "libstdc++.so.6"))
        link(File(lib, "libocgcc.so"), File(links, "libgcc_s.so.1"))
        // Programs opencode's tools call by name (owner, 2026-11-03: "make every opencode tool work on the phone").
        // Android has no rg or curl: glob/grep/skill failed with "ripgrep execution failed" (opencode looks for rg on
        // PATH, else downloads one into its data dir, which Android will not execute), and bash with "curl: inaccessible
        // or not found". The APK ships static builds as lib*.so; Android only executes files in nativeLibraryDir, so
        // filesDir/oc/bin holds symlinks into it (exec through a symlink runs the target there) and goes first on PATH.
        // `opencode` points at libocexec.so, which re-runs libocld.so with libopencode.so (see ocexec.c): a wrapper
        // script would not run, since Android executes nothing written to app data.
        val binDir = File(root, "bin").apply { mkdirs() }
        for ((name, so) in listOf("rg" to "libocrg.so", "curl" to "liboccurl.so", "opencode" to "libocexec.so")) {
            val target = File(lib, so)
            if (target.exists()) link(target, File(binDir, name)) else Log.w(TAG, "no $so in this build: $name unavailable")
        }
        val work = (if (cwd.isNullOrEmpty()) File(root, "work") else File(cwd)).apply { mkdirs() }
        val tmp = File(root, "tmp").apply { mkdirs() }
        val proxyPort = LocalProxy.start()
        if (baseUrl.isNotEmpty()) LocalProxy.upstream = baseUrl
        if (token.isNotEmpty()) LocalProxy.token = token
        // SubMac's skill (the app's tools, reached through SubMac's MCP server): opencode lists them and loads one when it wants it.
        val skillDir = File(root, "skills")
        skillDir.deleteRecursively()
        for ((name, body) in skills) {
            if (!Regex("[a-z0-9-]{1,64}").matches(name)) continue
            File(skillDir, name).apply { mkdirs() }.resolve("SKILL.md").writeText(body)
        }
        val cfg = File(root, "opencode.json")
        cfg.writeText(config("http://127.0.0.1:$proxyPort${LocalProxy.PREFIX}", skillDir.path, providers, models))
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
        // bin first so opencode (Bun.which("rg")) and every bash-tool command find rg, curl and opencode; the system
        // dirs stay after it. SUBMAC_OC_LIB tells ocexec where the soname links are (same as --library-path below).
        val sysPath = env["PATH"].takeUnless { it.isNullOrEmpty() } ?: "/system/bin:/system/xbin:/vendor/bin"
        env["PATH"] = binDir.path + ":" + sysPath
        env["SUBMAC_OC_LIB"] = links.path
        env["OPENCODE_CONFIG"] = cfg.path
        env["OPENCODE_SERVER_PASSWORD"] = pass
        env["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        // Android has no /etc/resolv.conf, so musl cannot resolve names: all outbound traffic goes through the
        // app's own proxy, which resolves with Android's resolver (LocalProxy).
        val proxy = "http://127.0.0.1:$proxyPort"
        for (k in listOf("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY")) env[k] = proxy
        env["NO_PROXY"] = "127.0.0.1,localhost"
        env["no_proxy"] = "127.0.0.1,localhost"
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

    private fun link(target: File, name: File) {
        try {
            if (name.exists() || isLink(name)) name.delete()
            android.system.Os.symlink(target.path, name.path)
        } catch (e: Throwable) {
            Log.w(TAG, "symlink ${name.name}: $e")
        }
    }

    private fun isLink(f: File): Boolean = try { android.system.Os.lstat(f.path); true } catch (_: Throwable) { false }

    /** SubMac's own model gateway, which speaks the OpenAI chat API, reached through LocalProxy (which adds the token).
     *  One provider per allowance lane (owner 2026-11-03, OcLane in the app): `submac` is the user's own lane; each
     *  background provider (`submac-bg`, `submac-office`) points at `/__submac/lane/<source>`, which LocalProxy sends on
     *  with `x-submac-lane: background`, so the lane rides in each request's own path and never leaks between sessions.
     *  The app names the provider in every prompt. No `small_model`: opencode then runs its small jobs (titles,
     *  summaries) on the turn's own provider, so they bill to the same lane. With no list from the app, the one
     *  foreground provider is written as before.
     *  Permissions: reading, editing files in the workspace and fetching pages go ahead; running a command,
     *  touching files outside the workspace and a step repeating itself ask first, on SubMac's ask card in the chat
     *  (OpenCodeAsks). SubMac's own tools come through SubMac's MCP server (registered by the app after start) and ask
     *  through SubMac's own approval card. */
    private fun config(baseUrl: String, skills: String, providers: List<Map<String, String>>, models: List<String>): String {
        val list = providers.filter { Regex("[a-z0-9-]{1,32}").matches(it["id"] ?: "") }
            .ifEmpty { listOf(mapOf("id" to "submac", "name" to "SubMac", "path" to "", "source" to "opencode")) }
        val names = models.filter { Regex("[a-z0-9.-]{1,48}").matches(it) }.ifEmpty { listOf("submac") }
        val prov = org.json.JSONObject()
        for (p in list) {
            val path = (p["path"] ?: "").let { if (it.isEmpty() || Regex("/lane/[a-z-]{1,20}").matches(it)) it else "" }
            val ms = org.json.JSONObject()
            for (m in names) ms.put(m, org.json.JSONObject().put("name", if (m == "submac") "SubMac" else m).put("tool_call", true))
            prov.put(p.getValue("id"), org.json.JSONObject()
                .put("npm", "@ai-sdk/openai-compatible")
                .put("name", p["name"] ?: "SubMac")
                .put("options", org.json.JSONObject()
                    .put("baseURL", baseUrl + path)
                    .put("apiKey", "via-proxy")
                    .put("headers", org.json.JSONObject().put("x-submac-source", p["source"] ?: "opencode")))
                .put("models", ms))
        }
        val root = org.json.JSONObject()
            .put("\$schema", "https://opencode.ai/config.json")
            .put("autoupdate", false)
            .put("share", "disabled")
            .put("provider", prov)
            .put("model", "submac/submac")
            .put("skills", org.json.JSONObject().put("paths", org.json.JSONArray().put(skills)))
            .put("permission", org.json.JSONObject().put("edit", "allow").put("bash", "ask").put("webfetch", "allow")
                .put("external_directory", "ask").put("doom_loop", "ask").put("question", "allow"))
        return root.toString(2)
    }
}
