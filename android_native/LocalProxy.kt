package com.submac.agent

import android.util.Log
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * A tiny HTTP proxy on 127.0.0.1 for the opencode engine.
 *
 * opencode is a Linux (musl) program: it looks names up through /etc/resolv.conf, which Android does not have, so
 * on a phone it cannot reach any host by name (2026-11-02: the first test prompt never reached ai-chat). The engine
 * gets HTTP_PROXY/HTTPS_PROXY pointing here; this proxy resolves names with Android's own resolver and pipes the
 * bytes. HTTPS goes through CONNECT, so TLS stays end to end between opencode and the real host.
 */
object LocalProxy {
    private const val TAG = "SubMacProxy"
    @Volatile private var server: ServerSocket? = null
    val port: Int get() = server?.localPort ?: 0

    /** Where the engine's model calls go (the ai-chat function) and the signed-in user's access token. The engine
     *  calls http://127.0.0.1:<port>/__submac/... ; this proxy sends it on over TLS with a fresh token, so an hour-old
     *  token in the engine's config never matters (the app pushes a new one before each prompt). */
    @Volatile var upstream: String = ""
    @Volatile var token: String = ""
    const val PREFIX = "/__submac"

    @Synchronized
    fun start(): Int {
        server?.let { if (!it.isClosed) return it.localPort }
        val s = ServerSocket()
        s.reuseAddress = true
        s.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0))
        server = s
        Thread {
            while (!s.isClosed) {
                val c = try { s.accept() } catch (_: Throwable) { break }
                Thread { handle(c) }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true; name = "submac-proxy" }.start()
        return s.localPort
    }

    @Synchronized
    fun stop() {
        try { server?.close() } catch (_: Throwable) {}
        server = null
    }

    private fun handle(c: Socket) {
        var up: Socket? = null
        try {
            c.soTimeout = 0
            val inp = c.getInputStream()
            val head = readHead(inp) ?: return c.close()
            val lines = head.split("\r\n")
            val parts = lines[0].split(" ")
            if (parts.size < 3) return c.close()
            val method = parts[0]
            val target = parts[1]
            if (method.equals("CONNECT", true)) {
                val (host, port) = hostPort(target, 443)
                up = Socket()
                up.connect(InetSocketAddress(host, port), 15000)
                c.getOutputStream().apply { write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray()); flush() }
            } else if (target.startsWith(PREFIX)) {
                up = forward(method, target.substring(PREFIX.length), parts[2], lines.drop(1)) ?: return c.close()
            } else {
                // Plain http with an absolute URI: http://host[:port]/path
                val u = java.net.URI(target)
                val host = u.host ?: return c.close()
                val port = if (u.port > 0) u.port else 80
                val path = (u.rawPath?.ifEmpty { "/" } ?: "/") + (u.rawQuery?.let { "?$it" } ?: "")
                up = Socket()
                up.connect(InetSocketAddress(host, port), 15000)
                val sb = StringBuilder("$method $path ${parts[2]}\r\n")
                for (l in lines.drop(1)) {
                    if (l.isEmpty() || l.startsWith("Proxy-", true)) continue
                    sb.append(l).append("\r\n")
                }
                sb.append("\r\n")
                up.getOutputStream().apply { write(sb.toString().toByteArray()); flush() }
            }
            val u2 = up
            val t = Thread { pipe(u2.getInputStream(), c.getOutputStream()); closeQuietly(c); closeQuietly(u2) }
            t.isDaemon = true
            t.start()
            pipe(inp, u2.getOutputStream())
        } catch (e: Throwable) {
            Log.w(TAG, "proxy: $e")
            try { c.getOutputStream().write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".toByteArray()) } catch (_: Throwable) {}
        } finally {
            closeQuietly(c)
            up?.let { closeQuietly(it) }
        }
    }

    /** Opens a TLS connection to [upstream] and sends the request head with its path, Host and Authorization
     *  rewritten. One request per connection (Connection: close), so a kept-alive second request is never piped
     *  through un-rewritten. */
    private fun forward(method: String, rest0: String, ver: String, headers: List<String>): Socket? {
        if (upstream.isEmpty()) return null
        val u = java.net.URI(upstream)
        val host = u.host ?: return null
        val port = if (u.port > 0) u.port else 443
        // The allowance lane rides in the path (owner 2026-11-03): /__submac/lane/<source>/... is a bot's or a team's
        // background work, sent with x-submac-lane: background and that source. Any other call has the lane header
        // removed, so a foreground (owner) call can never bill to the bots' share and a background one always does.
        val (rest, laneSource) = laneOf(rest0)
        val path = (u.rawPath ?: "").trimEnd('/') + rest
        val s = javax.net.ssl.SSLSocketFactory.getDefault().createSocket() as javax.net.ssl.SSLSocket
        s.connect(InetSocketAddress(host, port), 15000)
        s.startHandshake()
        val sb = StringBuilder("$method $path $ver\r\n")
        sb.append("Host: $host\r\n")
        if (token.isNotEmpty()) sb.append("Authorization: Bearer $token\r\n")
        sb.append("Connection: close\r\n")
        if (laneSource != null) {
            sb.append("$LANE_HEADER: background\r\n")
            sb.append("$SOURCE_HEADER: $laneSource\r\n")
        }
        for (l in headers) {
            if (l.isEmpty()) continue
            val k = l.substringBefore(':').trim()
            if (k.equals("Host", true) || k.equals("Authorization", true) || k.equals("Connection", true) ||
                k.equals("Keep-Alive", true) || k.startsWith("Proxy-", true)) continue
            if (k.equals(LANE_HEADER, true)) continue
            if (laneSource != null && k.equals(SOURCE_HEADER, true)) continue
            sb.append(l).append("\r\n")
        }
        sb.append("\r\n")
        s.getOutputStream().apply { write(sb.toString().toByteArray(Charsets.ISO_8859_1)); flush() }
        return s
    }

    const val LANE_HEADER = "x-submac-lane"
    const val SOURCE_HEADER = "x-submac-source"
    private val laneRe = Regex("^/lane/([a-z-]{1,20})(/.*)?$")

    /** `/lane/<source>/rest` -> (`/rest`, source); anything else is (path, null): the foreground lane. */
    fun laneOf(rest: String): Pair<String, String?> {
        val m = laneRe.find(rest.substringBefore('?')) ?: return rest to null
        val tail = rest.substring("/lane/".length + m.groupValues[1].length)
        return (if (tail.isEmpty()) "/" else tail) to m.groupValues[1]
    }

    private fun hostPort(s: String, def: Int): Pair<String, Int> {
        val i = s.lastIndexOf(':')
        if (i <= 0 || s.endsWith("]")) return s.trim('[', ']') to def
        return s.substring(0, i).trim('[', ']') to (s.substring(i + 1).toIntOrNull() ?: def)
    }

    /** Reads up to the blank line ending the request head (byte by byte, so no body bytes are swallowed). */
    private fun readHead(inp: InputStream): String? {
        val b = java.io.ByteArrayOutputStream()
        var last4 = 0
        while (b.size() < 65536) {
            val x = inp.read()
            if (x < 0) return null
            b.write(x)
            last4 = (last4 shl 8) or x
            if (last4 == 0x0D0A0D0A) return String(b.toByteArray(), Charsets.ISO_8859_1).trimEnd('\r', '\n')
        }
        return null
    }

    private fun pipe(a: InputStream, b: OutputStream) {
        val buf = ByteArray(16384)
        try {
            while (true) {
                val n = a.read(buf)
                if (n < 0) break
                b.write(buf, 0, n)
                b.flush()
            }
        } catch (_: Throwable) {}
    }

    private fun closeQuietly(s: Socket) { try { s.close() } catch (_: Throwable) {} }
}
