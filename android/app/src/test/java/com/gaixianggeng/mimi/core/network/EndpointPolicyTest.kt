package com.gaixianggeng.mimi.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress

class EndpointPolicyTest {
    @Test
    fun `private endpoint receives default agent port`() {
        val result = EndpointPolicy.assess("192.168.1.25")
        assertEquals(EndpointAssessment.Allowed("http://192.168.1.25:8787", true), result)
    }

    @Test
    fun `numeric private endpoints are assessed without hostname resolution`() {
        assertEquals(
            EndpointAssessment.Allowed("http://192.168.31.163:8787", true),
            EndpointPolicy.assess("192.168.31.163"),
        )
        assertEquals(
            EndpointAssessment.Allowed("http://100.127.16.9:8787", true),
            EndpointPolicy.assess("100.127.16.9"),
        )
        assertTrue(EndpointPolicy.assess("8.8.8.8") is EndpointAssessment.Rejected)
        assertTrue(EndpointPolicy.assess("999.168.1.1") is EndpointAssessment.Rejected)
    }

    @Test
    fun `tailscale and local names allow cleartext`() {
        assertEquals(
            EndpointAssessment.Allowed("http://pixel.mac.ts.net:8787", true),
            EndpointPolicy.assess("pixel.mac.ts.net"),
        )
        assertEquals(
            EndpointAssessment.Allowed("http://mimi.local:8787", true),
            EndpointPolicy.assess("mimi.local"),
        )
    }

    @Test
    fun `public cleartext endpoint is rejected`() {
        assertTrue(EndpointPolicy.assess("http://8.8.8.8:8787") is EndpointAssessment.Rejected)
    }

    @Test
    fun `public https endpoint remains valid`() {
        assertEquals(
            EndpointAssessment.Allowed("https://example.com", false),
            EndpointPolicy.assess("https://example.com"),
        )
    }

    @Test
    fun `paths credentials query and fragments are rejected`() {
        listOf(
            "https://example.com/api",
            "https://user@example.com",
            "https://example.com?token=secret",
            "https://example.com#fragment",
        ).forEach { assertTrue("Expected rejection for $it", EndpointPolicy.assess(it) is EndpointAssessment.Rejected) }
    }

    @Test
    fun `resolved address allowlist includes lan tailscale cgnat and ula`() {
        assertTrue(EndpointPolicy.isAllowedResolvedAddress(InetAddress.getByName("127.0.0.1")))
        assertTrue(EndpointPolicy.isAllowedResolvedAddress(InetAddress.getByName("10.1.2.3")))
        assertTrue(EndpointPolicy.isAllowedResolvedAddress(InetAddress.getByName("100.64.0.1")))
        assertTrue(EndpointPolicy.isAllowedResolvedAddress(InetAddress.getByName("fd00::1")))
        assertFalse(EndpointPolicy.isAllowedResolvedAddress(InetAddress.getByName("8.8.8.8")))
    }
}
