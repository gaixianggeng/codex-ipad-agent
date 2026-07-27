package com.gaixianggeng.mimi.core.model

enum class ComposerSendMode(val wireName: String) {
    Standard("default"),
    Goal("default"),
    Plan("plan"),
    ;

    val allowsGuidedFollowUp: Boolean
        get() = this == Standard

    companion object {
        fun fromWire(value: String?): ComposerSendMode =
            entries.firstOrNull { it.wireName == value?.trim()?.lowercase() } ?: Standard
    }
}
