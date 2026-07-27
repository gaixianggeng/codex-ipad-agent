package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class PermissionModeTest {
    @Test
    fun `remote presets never expose approval policy never`() {
        PermissionMode.entries.forEach { assertNotEquals("never", it.approvalPolicy) }
    }

    @Test
    fun `auto review is the only on failure reviewer`() {
        assertEquals("on-failure", PermissionMode.AutoApprove.approvalPolicy)
        assertEquals("auto_review", PermissionMode.AutoApprove.approvalsReviewer)
        PermissionMode.entries.filterNot { it == PermissionMode.AutoApprove }.forEach {
            assertEquals("on-request", it.approvalPolicy)
            assertEquals("user", it.approvalsReviewer)
        }
    }

    @Test
    fun `unknown persisted permission uses the product default`() {
        assertEquals(PermissionMode.FullAccess, PermissionMode.fromWire("legacy-unknown"))
    }
}
