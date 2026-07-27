package com.gaixianggeng.mimi.ui.theme

import androidx.compose.material3.Shapes
import androidx.compose.ui.unit.dp

/**
 * A small, shared spacing scale keeps the workspace dense without making
 * large-font or adaptive layouts feel cramped.
 */
object MimiSpacing {
    val xxs = 4.dp
    val xs = 8.dp
    val sm = 12.dp
    val md = 16.dp
    val lg = 24.dp
    val xl = 32.dp
}

val MimiShapes = Shapes(
    extraSmall = androidx.compose.foundation.shape.RoundedCornerShape(8.dp),
    small = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
    medium = androidx.compose.foundation.shape.RoundedCornerShape(16.dp),
    large = androidx.compose.foundation.shape.RoundedCornerShape(24.dp),
    extraLarge = androidx.compose.foundation.shape.RoundedCornerShape(32.dp),
)
