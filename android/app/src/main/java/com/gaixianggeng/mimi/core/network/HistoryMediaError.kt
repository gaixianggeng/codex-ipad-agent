package com.gaixianggeng.mimi.core.network

internal enum class HistoryMediaErrorKind {
    Expired,
    Unsupported,
    Other,
}

internal fun historyMediaErrorKind(error: Throwable): HistoryMediaErrorKind =
    when ((error as? AgentApiException)?.statusCode) {
        404 -> HistoryMediaErrorKind.Expired
        405 -> HistoryMediaErrorKind.Unsupported
        else -> HistoryMediaErrorKind.Other
    }
