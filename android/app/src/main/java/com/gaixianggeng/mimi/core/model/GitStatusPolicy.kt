package com.gaixianggeng.mimi.core.model

object GitStatusPolicy {
    const val MAX_FILES = 2_000
    const val MAX_FILE_PATH_CHARS = 4_096
    const val MAX_STATUS_CHARS = 500_000
    const val MAX_DIFF_STAT_CHARS = 100_000
    const val MAX_DIFF_CHARS = 2_000_000
    const val MAX_NOTE_CHARS = 2_000
    const val MAX_BRANCH_CHARS = 512
    const val MAX_HEAD_CHARS = 128

    fun sanitize(status: GitStatusResponse, expectedPath: String): GitStatusResponse {
        require(status.path == expectedPath) { "Git status path does not match the requested repository" }
        require(status.files.all { it.path.isNotBlank() && it.path.length <= MAX_FILE_PATH_CHARS }) {
            "Git status contains an invalid file path"
        }
        require(status.files.map(GitFileStatus::path).distinct().size == status.files.size) {
            "Git status contains duplicate file paths"
        }

        val filesClipped = status.files.size > MAX_FILES
        val statusText = status.statusText.bounded(MAX_STATUS_CHARS)
        val diffStat = status.diffStat.bounded(MAX_DIFF_STAT_CHARS)
        val unstagedDiff = status.unstagedDiff.bounded(MAX_DIFF_CHARS)
        val stagedDiff = status.stagedDiff.bounded(MAX_DIFF_CHARS)
        val truncatedNote = status.truncatedNote.bounded(MAX_NOTE_CHARS)
        val branchClipped = status.branch?.length?.let { it > MAX_BRANCH_CHARS } == true
        val headClipped = status.head?.length?.let { it > MAX_HEAD_CHARS } == true
        val textClipped =
            statusText.clipped || diffStat.clipped || unstagedDiff.clipped ||
                stagedDiff.clipped || truncatedNote.clipped || branchClipped || headClipped

        return status.copy(
            branch = status.branch?.take(MAX_BRANCH_CHARS),
            head = status.head?.take(MAX_HEAD_CHARS),
            statusText = statusText.value,
            diffStat = diffStat.value,
            unstagedDiff = unstagedDiff.value,
            stagedDiff = stagedDiff.value,
            files = status.files.take(MAX_FILES),
            truncated = status.truncated == true || filesClipped || textClipped,
            truncatedNote = truncatedNote.value,
        )
    }

    private fun String?.bounded(maxChars: Int): BoundedText {
        val source = this ?: return BoundedText(null, false)
        return BoundedText(source.take(maxChars), source.length > maxChars)
    }

    private data class BoundedText(val value: String?, val clipped: Boolean)
}
