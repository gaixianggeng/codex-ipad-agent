package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ComposerSendModeTest {
    @Test
    fun wireValuesAreFailClosedAndOnlyStandardCanGuide() {
        assertEquals(ComposerSendMode.Plan, ComposerSendMode.fromWire(" plan "))
        assertEquals(ComposerSendMode.Standard, ComposerSendMode.fromWire("unexpected"))
        assertEquals(ComposerSendMode.Standard, ComposerSendMode.fromWire(null))
        assertEquals("default", ComposerSendMode.Goal.wireName)
        assertTrue(ComposerSendMode.Standard.allowsGuidedFollowUp)
        assertFalse(ComposerSendMode.Goal.allowsGuidedFollowUp)
        assertFalse(ComposerSendMode.Plan.allowsGuidedFollowUp)
    }
}
