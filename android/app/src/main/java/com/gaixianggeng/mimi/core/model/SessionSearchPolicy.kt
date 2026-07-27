package com.gaixianggeng.mimi.core.model

data class SessionSearchProjection(
    val results: List<ThreadSearchResult>,
    val cursors: Map<String, String>,
)

object SessionSearchPolicy {
    const val DEBOUNCE_MILLIS = 300L

    fun isCurrent(
        requestGeneration: Long,
        currentGeneration: Long,
        requestQuery: String,
        currentQuery: String,
    ): Boolean =
        requestGeneration == currentGeneration && requestQuery == currentQuery.trim()

    fun initial(
        pages: Map<String, ThreadSearchPage>,
        projectPath: String?,
    ): SessionSearchProjection =
        SessionSearchProjection(
            results = pages.values
                .flatMap(ThreadSearchPage::results)
                .filter { projectPath == null || it.thread.cwd == projectPath }
                .distinctBy { it.thread.id },
            cursors = pages.mapNotNull { (runtime, page) ->
                page.nextCursor?.takeIf(String::isNotBlank)?.let { runtime to it }
            }.toMap(),
        )

    fun append(
        existing: List<ThreadSearchResult>,
        pages: Map<String, ThreadSearchPage>,
        previousCursors: Map<String, String>,
        projectPath: String?,
    ): SessionSearchProjection {
        val merged = existing.associateByTo(linkedMapOf()) { it.thread.id }
        pages.values
            .flatMap(ThreadSearchPage::results)
            .filter { projectPath == null || it.thread.cwd == projectPath }
            .forEach { merged[it.thread.id] = it }
        val nextCursors = pages.mapNotNull { (runtime, page) ->
            page.nextCursor
                ?.takeIf(String::isNotBlank)
                ?.takeUnless { it == previousCursors[runtime] }
                ?.let { runtime to it }
        }.toMap()
        return SessionSearchProjection(merged.values.toList(), nextCursors)
    }
}
