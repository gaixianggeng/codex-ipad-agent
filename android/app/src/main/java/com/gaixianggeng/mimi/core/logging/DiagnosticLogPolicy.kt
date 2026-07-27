package com.gaixianggeng.mimi.core.logging

import java.time.Instant

object DiagnosticLogPolicy {
    const val MAX_ENTRIES = 500
    private const val MAX_FIELD_CHARS = 200
    private const val MAX_EXPORT_LINE_CHARS = 320

    private val unsafeCharacters = Regex("[^A-Za-z0-9_./: -]")
    private val repeatedWhitespace = Regex("\\s+")
    private val bearerCredential = Regex("(?i)\\bbearer\\s+[A-Za-z0-9._~+/=-]+")
    private val namedSecret = Regex(
        "(?i)\\b(authorization|access[_ -]?token|token|password|secret)\\b\\s*[:=]\\s*[^\\s]+",
    )
    private val requestContent = Regex("(?i)\\b(prompt|body)\\b\\s*[:=]\\s*[^\\r\\n]+")

    fun transport(statusName: String, at: Instant = Instant.now()): String =
        entry("transport", statusName, at)

    fun event(methodName: String, at: Instant = Instant.now()): String =
        entry("event", methodName, at)

    fun append(current: List<String>, entry: String): List<String> =
        (current + entry).takeLast(MAX_ENTRIES)

    fun export(entries: List<String>): String =
        entries
            .takeLast(MAX_ENTRIES)
            .map(::redactExportLine)
            .joinToString("\n")

    private fun entry(kind: String, field: String, at: Instant): String {
        val safeField = redactSensitive(field)
            .replace(unsafeCharacters, "?")
            .replace(repeatedWhitespace, " ")
            .trim()
            .take(MAX_FIELD_CHARS)
            .ifEmpty { "unknown" }
        return "$at $kind $safeField"
    }

    private fun redactExportLine(line: String): String =
        redactSensitive(
            line
            .replace('\r', ' ')
                .replace('\n', ' '),
        )
            .replace(repeatedWhitespace, " ")
            .trim()
            .take(MAX_EXPORT_LINE_CHARS)

    private fun redactSensitive(value: String): String =
        value
            .replace(bearerCredential, "Bearer [redacted]")
            .replace(namedSecret) { "${it.groupValues[1]}=[redacted]" }
            .replace(requestContent) { "${it.groupValues[1]}=[redacted]" }
}
