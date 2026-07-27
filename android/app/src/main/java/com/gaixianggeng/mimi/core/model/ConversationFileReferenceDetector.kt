package com.gaixianggeng.mimi.core.model

import java.net.URLDecoder

data class ConversationFileReference(
    val path: String,
    val name: String,
)

object ConversationFileReferenceDetector {
    private val previewExtensions = setOf(
        "csv", "doc", "docx", "gif", "heic", "html", "jpeg", "jpg", "json", "log",
        "md", "numbers", "pages", "pdf", "png", "ppt", "pptx", "rtf", "txt", "webp",
        "xls", "xlsx", "yaml", "yml", "zip",
    )
    private val imageExtensions = setOf("gif", "heic", "jpeg", "jpg", "png", "webp")
    private val startBoundary = setOf('`', '"', '\'', '“', '”', '‘', '’', '(', '[', '{', '<', '：', ':', '，', ',', ';', '；')
    private val stopCharacters = setOf('\n', '\r', '\u0000', '`', '"', '\'', '“', '”', '‘', '’', '<', '>')
    private val terminators = setOf(
        ' ', '\t', '\n', '\r', '`', '"', '\'', '“', '”', '‘', '’',
        '(', ')', '[', ']', '{', '}', '<', '>', ',', ';', ':', '.', '!', '?',
        '。', '！', '？', '、', '，', '；', '：', '#',
    )
    private val edgeTrim = setOf('`', '"', '\'', '“', '”', '‘', '’', '(', ')', '[', ']', '{', '}', '<', '>', '.', ',', ';')

    fun references(text: String, limit: Int = 5): List<ConversationFileReference> =
        references(text, limit, previewExtensions)

    fun imageReferences(text: String, limit: Int = 5): List<ConversationFileReference> =
        references(text, limit, imageExtensions)

    private fun references(
        text: String,
        limit: Int,
        allowedExtensions: Set<String>,
    ): List<ConversationFileReference> {
        if (limit <= 0) return emptyList()
        val extensions = allowedExtensions.sortedWith(compareByDescending<String> { it.length }.thenBy { it })
        val result = mutableListOf<ConversationFileReference>()
        val seen = mutableSetOf<String>()
        var index = 0
        while (index < text.length && result.size < limit) {
            if (!isPathStart(text, index)) {
                index += 1
                continue
            }
            val candidate = pathCandidate(text, index, extensions)
            if (candidate == null) {
                index += 1
                continue
            }
            val path = normalize(candidate.first)
            if (path != null && seen.add(path)) {
                result += ConversationFileReference(path, path.substringAfterLast('/'))
            }
            index = candidate.second
        }
        return result
    }

    private fun pathCandidate(
        text: String,
        start: Int,
        extensions: List<String>,
    ): Pair<String, Int>? {
        var index = start
        while (index < text.length) {
            if (index != start && isPathStart(text, index)) return null
            val character = text[index]
            if (character in stopCharacters || character.isISOControl()) return null
            if (character == '.') {
                val extensionStart = index + 1
                extensions.forEach { extension ->
                    val extensionEnd = extensionStart + extension.length
                    if (
                        extensionEnd <= text.length &&
                        text.regionMatches(extensionStart, extension, 0, extension.length, ignoreCase = true) &&
                        isTerminator(text, extensionEnd)
                    ) {
                        return text.substring(start, extensionEnd) to extensionEnd
                    }
                }
            }
            index += 1
        }
        return null
    }

    private fun isPathStart(text: String, index: Int): Boolean {
        val boundary = index == 0 || text[index - 1].isWhitespace() || text[index - 1].isISOControl() || text[index - 1] in startBoundary
        if (!boundary) return false
        if (text.regionMatches(index, "file://", 0, 7, ignoreCase = true)) return true
        return text[index] == '/' && (index + 1 >= text.length || text[index + 1] != '/')
    }

    private fun isTerminator(text: String, index: Int): Boolean =
        index >= text.length || text[index] in terminators || text[index].isWhitespace() || text[index].isISOControl()

    private fun normalize(raw: String): String? {
        var token = raw.trim { it in edgeTrim }
        if (token.startsWith("file://", ignoreCase = true)) token = token.drop(7)
        token = runCatching {
            URLDecoder.decode(token.replace("+", "%2B"), Charsets.UTF_8.name())
        }.getOrDefault(token)
        token = token.replace("\\ ", " ")
        if (!token.startsWith('/') || token.length <= 1 || '\u0000' in token) return null
        return token
    }
}
