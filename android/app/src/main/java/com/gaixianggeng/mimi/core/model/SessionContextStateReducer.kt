package com.gaixianggeng.mimi.core.model

object SessionContextStateReducer {
    private const val MAX_TASKS = 8
    private const val MAX_SUBAGENTS = 8

    fun merge(
        base: SessionContextSnapshot?,
        update: SessionContextSnapshot?,
    ): SessionContextSnapshot? {
        if (update == null) return base
        if (base == null || base.threadId != update.threadId) {
            return update.copy(
                tasks = update.tasks.take(MAX_TASKS),
                sources = uniqueSources(update.sources),
                subagents = uniqueSubagents(update.subagents).take(MAX_SUBAGENTS),
            )
        }
        return base.copy(
            status = update.status ?: base.status,
            environment = mergeEnvironment(base.environment, update.environment),
            git = update.git ?: base.git,
            tasks = mergeTasks(base.tasks, update.tasks),
            sources = uniqueSources(update.sources + base.sources),
            subagents = uniqueSubagents(update.subagents + base.subagents).take(MAX_SUBAGENTS),
            updatedAtEpochSeconds = update.updatedAtEpochSeconds
                ?: base.updatedAtEpochSeconds,
        )
    }

    private fun mergeEnvironment(
        base: SessionContextEnvironment?,
        update: SessionContextEnvironment?,
    ): SessionContextEnvironment? {
        if (update == null) return base
        if (base == null) return update
        return update.copy(
            id = update.id.nonBlankOr(base.id),
            kind = update.kind.nonBlankOr(base.kind),
            label = update.label.nonBlankOr(base.label),
            cwd = update.cwd.nonBlankOr(base.cwd),
            provider = update.provider.nonBlankOr(base.provider),
            runtimeProvider = update.runtimeProvider.nonBlankOr(base.runtimeProvider),
        )
    }

    private fun mergeTasks(
        base: List<SessionContextTask>,
        update: List<SessionContextTask>,
    ): List<SessionContextTask> {
        if (update.isEmpty()) return base.take(MAX_TASKS)
        val seen = mutableSetOf<String>()
        return (update + base).mapNotNull { task ->
            val key = task.id.ifBlank { "${task.kind}:${task.title}" }
            task.takeIf { key.isNotBlank() && seen.add(key) }
        }.take(MAX_TASKS)
    }

    private fun uniqueSources(values: List<SessionContextSource>): List<SessionContextSource> {
        val seen = mutableSetOf<String>()
        return values.mapNotNull { source ->
            val key = source.id.ifBlank { "${source.kind}:${source.label}" }
            source.takeIf { key.isNotBlank() && seen.add(key) }
        }
    }

    private fun uniqueSubagents(values: List<SessionContextSubagent>): List<SessionContextSubagent> {
        val seen = mutableSetOf<String>()
        return values.mapNotNull { subagent ->
            val key = subagent.id.ifBlank { subagent.displayName }
            subagent.takeIf { key.isNotBlank() && seen.add(key) }
        }
    }

    private fun String?.nonBlankOr(fallback: String?): String? =
        this?.takeIf(String::isNotBlank) ?: fallback
}
