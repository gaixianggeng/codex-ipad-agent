package com.gaixianggeng.mimi.core.network

import android.net.Uri
import java.time.Instant

sealed interface PairingLinkAssessment {
    data class SignedTicket(
        val endpoint: String,
        val issuedAt: String,
        val expiresAt: String,
        val pairSignature: String,
    ) : PairingLinkAssessment

    data class LegacyConnection(
        val endpoint: String,
        val token: String,
    ) : PairingLinkAssessment

    data class Rejected(
        val reason: PairingLinkRejection,
        val endpointReason: String? = null,
    ) : PairingLinkAssessment
}

enum class PairingLinkRejection {
    Unsupported,
    MissingEndpoint,
    MissingToken,
    IncompleteTicket,
    InvalidExpiry,
    Expired,
    EndpointRejected,
}

object PairingLinkPolicy {
    fun assess(uri: Uri, nowEpochSeconds: Long = Instant.now().epochSecond): PairingLinkAssessment {
        if (!uri.scheme.equals("mimiremote", ignoreCase = true)) {
            return PairingLinkAssessment.Rejected(PairingLinkRejection.Unsupported)
        }
        val host = uri.host?.lowercase()
        if (host != "pair" && host != "connect") {
            return PairingLinkAssessment.Rejected(PairingLinkRejection.Unsupported)
        }
        val endpoint = uri.getQueryParameter("endpoint").orEmpty().trim()
        if (endpoint.isEmpty()) return PairingLinkAssessment.Rejected(PairingLinkRejection.MissingEndpoint)
        val normalizedEndpoint = when (val assessment = EndpointPolicy.assess(endpoint)) {
            is EndpointAssessment.Allowed -> assessment.normalizedEndpoint
            is EndpointAssessment.Rejected -> {
                return PairingLinkAssessment.Rejected(PairingLinkRejection.EndpointRejected, assessment.reason)
            }
        }
        val pairSignature = uri.getQueryParameter("pair_sig").orEmpty().trim()
        if (pairSignature.isNotEmpty()) {
            val issuedAt = uri.getQueryParameter("issued_at").orEmpty().trim()
            val expiresAt = uri.getQueryParameter("expires_at").orEmpty().trim()
            if (issuedAt.isEmpty() || expiresAt.isEmpty()) {
                return PairingLinkAssessment.Rejected(PairingLinkRejection.IncompleteTicket)
            }
            val expiry = parseExpiry(expiresAt)
                ?: return PairingLinkAssessment.Rejected(PairingLinkRejection.InvalidExpiry)
            if (expiry <= nowEpochSeconds) return PairingLinkAssessment.Rejected(PairingLinkRejection.Expired)
            return PairingLinkAssessment.SignedTicket(
                endpoint = normalizedEndpoint,
                issuedAt = issuedAt,
                expiresAt = expiresAt,
                pairSignature = pairSignature,
            )
        }
        if (host != "connect") return PairingLinkAssessment.Rejected(PairingLinkRejection.IncompleteTicket)
        val token = uri.getQueryParameter("token").orEmpty().trim()
        if (token.isEmpty()) return PairingLinkAssessment.Rejected(PairingLinkRejection.MissingToken)
        uri.getQueryParameter("expires_at")?.trim()?.takeIf(String::isNotEmpty)?.let { expiresAt ->
            val expiry = parseExpiry(expiresAt)
                ?: return PairingLinkAssessment.Rejected(PairingLinkRejection.InvalidExpiry)
            if (expiry <= nowEpochSeconds) return PairingLinkAssessment.Rejected(PairingLinkRejection.Expired)
        }
        return PairingLinkAssessment.LegacyConnection(normalizedEndpoint, token)
    }

    private fun parseExpiry(value: String): Long? {
        return value.toLongOrNull() ?: runCatching { Instant.parse(value).epochSecond }.getOrNull()
    }
}
