package com.gaixianggeng.mimi.core.model

object GitMutationPolicy {
    const val MAX_FILES = 200
    const val MAX_PATH_CHARS = 4_096
    const val MAX_PATCH_CHARS = 2_000_000

    private val fileActions = setOf(
        GitActionKind.Stage,
        GitActionKind.Unstage,
        GitActionKind.Revert,
    )
    private val patchActions = setOf(
        GitActionKind.StagePatch,
        GitActionKind.UnstagePatch,
        GitActionKind.RevertPatch,
    )

    fun availableFileActions(file: GitFileStatus): Set<GitActionKind> = buildSet {
        if (file.unstaged || file.untracked) add(GitActionKind.Stage)
        if (file.staged) add(GitActionKind.Unstage)
        if (file.unstaged && !file.untracked) add(GitActionKind.Revert)
    }

    fun fileRequest(path: String, action: GitActionKind, files: List<String>): GitActionRequest {
        require(path.isNotBlank() && path.length <= MAX_PATH_CHARS) { "Git path is invalid" }
        require(action in fileActions) { "A file Git action is required" }
        require(files.size in 1..MAX_FILES) { "Git file selection is invalid" }
        require(files.all { it.isNotBlank() && it.length <= MAX_PATH_CHARS }) { "Git file path is invalid" }
        require(files.distinct().size == files.size) { "Git file selection contains duplicates" }
        return GitActionRequest(path = path, action = action, files = files)
    }

    fun patchRequest(path: String, action: GitActionKind, patch: String): GitActionRequest {
        require(path.isNotBlank() && path.length <= MAX_PATH_CHARS) { "Git path is invalid" }
        require(action in patchActions) { "A patch Git action is required" }
        require(
            patch.length in 1..MAX_PATCH_CHARS &&
                patch.startsWith("diff --git ") &&
                patch.contains("\n@@ "),
        ) { "Git patch is invalid" }
        return GitActionRequest(path = path, action = action, patch = patch)
    }
}
