package com.gaixianggeng.mimi.core.model

object ReviewStartPolicy {
    fun canStart(
        context: SessionContextStatus?,
        hasActiveTurn: Boolean,
    ): Boolean =
        !SessionLibraryPolicy.isActive(
            SessionLibraryPolicy.status(
                context = context,
                hasActiveTurn = hasActiveTurn,
            ),
        )
}
