package com.gaixianggeng.mimi.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class AdaptiveWorkspacePolicyTest {
    @Test
    fun resolvesWidthClassesAtExactBoundaries() {
        assertEquals(
            AdaptiveWorkspaceLayout.Compact,
            AdaptiveWorkspacePolicy.resolve(699.99f, isTabletop = false, hasSeparatingVerticalHinge = false),
        )
        assertEquals(
            AdaptiveWorkspaceLayout.Medium,
            AdaptiveWorkspacePolicy.resolve(700f, isTabletop = false, hasSeparatingVerticalHinge = false),
        )
        assertEquals(
            AdaptiveWorkspaceLayout.Expanded,
            AdaptiveWorkspacePolicy.resolve(1_200f, isTabletop = false, hasSeparatingVerticalHinge = false),
        )
    }

    @Test
    fun tabletopDisablesExpandedWithoutCollapsingMediumLayout() {
        assertEquals(
            AdaptiveWorkspaceLayout.Medium,
            AdaptiveWorkspacePolicy.resolve(1_600f, isTabletop = true, hasSeparatingVerticalHinge = false),
        )
    }

    @Test
    fun separatingVerticalHingeOwnsThePhysicalPaneSplit() {
        assertEquals(
            AdaptiveWorkspaceLayout.SeparatingVerticalHinge,
            AdaptiveWorkspacePolicy.resolve(600f, isTabletop = false, hasSeparatingVerticalHinge = true),
        )
        assertEquals(
            AdaptiveWorkspaceLayout.SeparatingVerticalHinge,
            AdaptiveWorkspacePolicy.resolve(1_600f, isTabletop = true, hasSeparatingVerticalHinge = true),
        )
    }

    @Test
    fun rejectsInvalidMeasuredWidths() {
        assertThrows(IllegalArgumentException::class.java) {
            AdaptiveWorkspacePolicy.resolve(Float.NaN, isTabletop = false, hasSeparatingVerticalHinge = false)
        }
        assertThrows(IllegalArgumentException::class.java) {
            AdaptiveWorkspacePolicy.resolve(-1f, isTabletop = false, hasSeparatingVerticalHinge = false)
        }
    }
}
