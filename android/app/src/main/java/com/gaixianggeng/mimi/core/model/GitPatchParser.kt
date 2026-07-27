package com.gaixianggeng.mimi.core.model

data class GitPatchHunk(
    val id: String,
    val title: String,
    val patch: String,
    val preview: String,
)

object GitPatchParser {
    fun parse(diff: String): List<GitPatchHunk> {
        val normalized = diff.replace("\r\n", "\n").replace('\r', '\n').let { if (it.endsWith('\n')) it else "$it\n" }
        var fileHeader = mutableListOf<String>()
        var currentHunk = mutableListOf<String>()
        val result = mutableListOf<GitPatchHunk>()

        fun finishHunk() {
            if (fileHeader.isEmpty() || currentHunk.isEmpty()) {
                currentHunk = mutableListOf()
                return
            }
            val patch = (fileHeader + currentHunk).joinToString("")
            val hunkHeader = currentHunk.first().trim().ifBlank { "hunk" }
            val filePath = displayPath(fileHeader)
            val title = if (filePath.isBlank()) hunkHeader else "$filePath · $hunkHeader"
            result += GitPatchHunk("${result.size}-$title", title, patch, currentHunk.joinToString(""))
            currentHunk = mutableListOf()
        }

        normalized.split('\n').dropLast(1).asSequence().map { "$it\n" }.forEach { line ->
            when {
                line.startsWith("diff --git ") -> {
                    finishHunk()
                    fileHeader = mutableListOf(line)
                }
                line.startsWith("@@ ") -> {
                    finishHunk()
                    currentHunk = mutableListOf(line)
                }
                currentHunk.isEmpty() && fileHeader.isNotEmpty() -> fileHeader += line
                currentHunk.isNotEmpty() -> currentHunk += line
            }
        }
        finishHunk()
        return result
    }

    private fun displayPath(header: List<String>): String = header.asReversed()
        .firstOrNull { it.startsWith("+++ ") }
        ?.removePrefix("+++ ")
        ?.trim()
        ?.takeUnless { it == "/dev/null" }
        ?.removePrefix("b/")
        ?.removePrefix("a/")
        .orEmpty()
}
