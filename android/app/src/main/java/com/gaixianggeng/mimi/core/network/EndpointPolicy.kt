package com.gaixianggeng.mimi.core.network

import java.net.Inet6Address
import java.net.InetAddress
import java.net.URI

sealed interface EndpointAssessment {
    data class Allowed(val normalizedEndpoint: String, val cleartext: Boolean) : EndpointAssessment
    data class Rejected(val reason: String) : EndpointAssessment
}

object EndpointPolicy {
    fun assess(raw: String): EndpointAssessment {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return EndpointAssessment.Rejected("Connection address is required")
        val candidate = if (trimmed.contains("://")) trimmed else "http://$trimmed"
        val uri = runCatching { URI(candidate) }.getOrNull()
            ?: return EndpointAssessment.Rejected("Connection address is invalid")
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") {
            return EndpointAssessment.Rejected("Only HTTP and HTTPS endpoints are supported")
        }
        val host = uri.host?.trim('[', ']')?.lowercase()
            ?: return EndpointAssessment.Rejected("Connection host is missing")
        if (uri.userInfo != null || uri.rawQuery != null || uri.rawFragment != null) {
            return EndpointAssessment.Rejected("Credentials, query parameters and fragments are not allowed")
        }
        if (uri.rawPath?.let { it.isNotEmpty() && it != "/" } == true) {
            return EndpointAssessment.Rejected("Connection address must not contain a path")
        }
        if (uri.port !in -1..65535) return EndpointAssessment.Rejected("Connection port is invalid")
        if (scheme == "http" && !isPrivateHostLiteralOrName(host)) {
            return EndpointAssessment.Rejected("Public HTTP endpoints are blocked; use HTTPS")
        }

        val port = if (uri.port == -1 && scheme == "http") 8787 else uri.port
        val authorityHost = if (host.contains(':')) "[$host]" else host
        val authority = if (port == -1) authorityHost else "$authorityHost:$port"
        return EndpointAssessment.Allowed("$scheme://$authority", cleartext = scheme == "http")
    }

    fun isAllowedResolvedAddress(address: InetAddress): Boolean {
        if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress || address.isSiteLocalAddress) {
            return true
        }
        val bytes = address.address.map { it.toInt() and 0xff }
        if (bytes.size == 4 && bytes[0] == 100 && bytes[1] in 64..127) return true
        if (address is Inet6Address && bytes.isNotEmpty() && (bytes[0] and 0xfe) == 0xfc) return true
        return false
    }

    private fun isPrivateHostLiteralOrName(host: String): Boolean {
        if (host == "localhost" || host.endsWith(".local") || host.endsWith(".ts.net")) return true
        val parsed = parseIpv4Literal(host)
            ?: host.takeIf { ':' in it }?.let { runCatching { InetAddress.getByName(it) }.getOrNull() }
        return parsed?.let(::isAllowedResolvedAddress) == true
    }

    /**
     * Endpoint assessment runs from UI and network call sites, so it must never perform DNS for
     * numeric LAN addresses. InetAddress.getByName() can trigger Android's main-thread network
     * guard even for an IPv4-looking string on some releases.
     */
    private fun parseIpv4Literal(host: String): InetAddress? {
        val octets = host.split('.')
        if (octets.size != 4) return null
        val bytes = ByteArray(4)
        octets.forEachIndexed { index, octet ->
            if (octet.isEmpty() || octet.any { !it.isDigit() }) return null
            val value = octet.toIntOrNull()?.takeIf { it in 0..255 } ?: return null
            bytes[index] = value.toByte()
        }
        return InetAddress.getByAddress(bytes)
    }
}
