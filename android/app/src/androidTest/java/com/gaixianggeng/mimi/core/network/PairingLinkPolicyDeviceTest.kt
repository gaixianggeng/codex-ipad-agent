package com.gaixianggeng.mimi.core.network

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PairingLinkPolicyDeviceTest {
    @Test
    fun signedTicketAcceptsEpochAndRfc3339NanoExpiryWithoutLongTermToken() {
        val epoch = Uri.parse(
            "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787" +
                "&issued_at=2026-07-23T00%3A00%3A00Z&expires_at=4102444800&pair_sig=abcdef",
        )
        val nano = Uri.parse(
            "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787" +
                "&issued_at=2026-07-23T00%3A00%3A00.123456Z" +
                "&expires_at=2099-12-31T23%3A59%3A59.123456Z&pair_sig=abcdef",
        )

        assertTrue(PairingLinkPolicy.assess(epoch, nowEpochSeconds = 1) is PairingLinkAssessment.SignedTicket)
        assertTrue(PairingLinkPolicy.assess(nano, nowEpochSeconds = 1) is PairingLinkAssessment.SignedTicket)
    }

    @Test
    fun legacyTokenRequiresExplicitConnectRouteAndHonorsExpiry() {
        val valid = Uri.parse(
            "mimiremote://connect?endpoint=192.168.31.163%3A8787&token=secret&expires_at=4102444800",
        )
        val parsed = PairingLinkPolicy.assess(valid, nowEpochSeconds = 1) as PairingLinkAssessment.LegacyConnection
        assertEquals("http://192.168.31.163:8787", parsed.endpoint)
        assertEquals("secret", parsed.token)

        val pairRoute = Uri.parse(valid.toString().replace("://connect", "://pair"))
        assertEquals(
            PairingLinkRejection.IncompleteTicket,
            (PairingLinkPolicy.assess(pairRoute, nowEpochSeconds = 1) as PairingLinkAssessment.Rejected).reason,
        )
    }

    @Test
    fun expiredMalformedAndInsecurePublicLinksFailClosed() {
        val expired = Uri.parse(
            "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787" +
                "&issued_at=2026-01-01T00%3A00%3A00Z&expires_at=1&pair_sig=abcdef",
        )
        val malformed = Uri.parse(expired.toString().replace("expires_at=1", "expires_at=tomorrow"))
        val publicHttp = Uri.parse(
            "mimiremote://connect?endpoint=http%3A%2F%2Fexample.com%3A8787&token=secret",
        )

        assertEquals(
            PairingLinkRejection.Expired,
            (PairingLinkPolicy.assess(expired, nowEpochSeconds = 2) as PairingLinkAssessment.Rejected).reason,
        )
        assertEquals(
            PairingLinkRejection.InvalidExpiry,
            (PairingLinkPolicy.assess(malformed, nowEpochSeconds = 2) as PairingLinkAssessment.Rejected).reason,
        )
        assertEquals(
            PairingLinkRejection.EndpointRejected,
            (PairingLinkPolicy.assess(publicHttp, nowEpochSeconds = 2) as PairingLinkAssessment.Rejected).reason,
        )
    }
}
