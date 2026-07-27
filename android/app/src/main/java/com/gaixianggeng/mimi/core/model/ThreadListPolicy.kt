package com.gaixianggeng.mimi.core.model

data class ThreadListProjection(
    val threads: List<AgentThread>,
    val cursors: Map<String, String>,
)

object ThreadListPolicy {
    fun isCurrent(
        requestGeneration: Long,
        currentGeneration: Long,
        requestProjectId: String,
        selectedProjectId: String?,
    ): Boolean =
        requestGeneration == currentGeneration && requestProjectId == selectedProjectId

    fun initial(pages: Map<String, ThreadPage>): ThreadListProjection =
        ThreadListProjection(
            threads = pages.values
                .flatMap(ThreadPage::threads)
                .distinctBy(AgentThread::id),
            cursors = pages.mapNotNull { (runtime, page) ->
                validNextCursor(page.nextCursor, previous = null)?.let { runtime to it }
            }.toMap(),
        )

    fun append(
        existing: List<AgentThread>,
        pages: Map<String, ThreadPage>,
        previousCursors: Map<String, String>,
    ): ThreadListProjection {
        val merged = existing.associateByTo(linkedMapOf(), AgentThread::id)
        pages.values.flatMap(ThreadPage::threads).forEach { merged[it.id] = it }

        val nextCursors = previousCursors.mapNotNull { (runtime, previous) ->
            val page = pages[runtime] ?: return@mapNotNull runtime to previous
            validNextCursor(page.nextCursor, previous)?.let { runtime to it }
        }.toMap()
        return ThreadListProjection(merged.values.toList(), nextCursors)
    }

    private fun validNextCursor(cursor: String?, previous: String?): String? =
        cursor
            ?.takeIf { it.isNotBlank() && it == it.trim() }
            ?.takeUnless { it == previous }
}
