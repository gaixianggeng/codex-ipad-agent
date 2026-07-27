package com.gaixianggeng.mimi.core.model

enum class AdaptiveWorkspaceLayout {
    Compact,
    Medium,
    Expanded,
    SeparatingVerticalHinge,
}

object AdaptiveWorkspacePolicy {
    fun resolve(
        widthDp: Float,
        isTabletop: Boolean,
        hasSeparatingVerticalHinge: Boolean,
    ): AdaptiveWorkspaceLayout {
        require(widthDp >= 0f && widthDp.isFinite())
        return when {
            hasSeparatingVerticalHinge -> AdaptiveWorkspaceLayout.SeparatingVerticalHinge
            widthDp >= 1_200f && !isTabletop -> AdaptiveWorkspaceLayout.Expanded
            widthDp >= 700f -> AdaptiveWorkspaceLayout.Medium
            else -> AdaptiveWorkspaceLayout.Compact
        }
    }
}
