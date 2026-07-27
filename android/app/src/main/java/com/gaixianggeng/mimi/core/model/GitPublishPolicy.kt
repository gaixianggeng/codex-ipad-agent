package com.gaixianggeng.mimi.core.model

object GitPublishPolicy {
    const val MAX_PATH_CHARS = 4_096
    const val MAX_COMMIT_MESSAGE_CHARS = 500
    const val MAX_REMOTE_CHARS = 256
    const val MAX_PULL_REQUEST_TITLE_CHARS = 256
    const val MAX_PULL_REQUEST_BODY_CHARS = 64_000
    const val MAX_WHAT_TO_TEST_CHARS = 4_000
    const val MAX_OUTPUT_CHARS = 100_000

    fun statusRequest(path: String): GitStatusRequest = GitStatusRequest(validPath(path))

    fun commitRequest(path: String, message: String): GitCommitRequest {
        require(message.isNotBlank() && message.length <= MAX_COMMIT_MESSAGE_CHARS) {
            "Commit message is invalid"
        }
        return GitCommitRequest(validPath(path), message)
    }

    fun pushRequest(path: String, remote: String?): GitPushRequest {
        remote?.let {
            require(it == it.trim() && it.length in 1..MAX_REMOTE_CHARS) { "Git remote is invalid" }
        }
        return GitPushRequest(validPath(path), remote)
    }

    fun quickPublishRequest(path: String, message: String, confirmed: Boolean): GitQuickPublishRequest {
        require(confirmed) { "Quick publish requires explicit confirmation" }
        val commit = commitRequest(path, message)
        return GitQuickPublishRequest(commit.path, commit.message, confirmed = true)
    }

    fun pullRequest(path: String, title: String, body: String, draft: Boolean): GitPullRequestRequest {
        require(
            title == title.trim() &&
                title.length in 1..MAX_PULL_REQUEST_TITLE_CHARS &&
                body.length <= MAX_PULL_REQUEST_BODY_CHARS,
        ) { "Pull request content is invalid" }
        return GitPullRequestRequest(validPath(path), title, body, draft)
    }

    fun pullRequestStatus(path: String): GitPullRequestStatusRequest =
        GitPullRequestStatusRequest(validPath(path))

    fun testFlightStatus(path: String): GitTestFlightStatusRequest =
        GitTestFlightStatusRequest(validPath(path))

    fun testFlightRun(path: String, whatToTest: String, confirmed: Boolean): GitTestFlightRunRequest {
        require(confirmed) { "TestFlight publish requires explicit confirmation" }
        require(whatToTest.isNotBlank() && whatToTest.length <= MAX_WHAT_TO_TEST_CHARS) {
            "What to test is invalid"
        }
        return GitTestFlightRunRequest(validPath(path), whatToTest, confirmed = true)
    }

    fun bound(response: GitPushResponse): GitPushResponse =
        response.copy(output = response.output?.takeLast(MAX_OUTPUT_CHARS))

    fun bound(response: GitQuickPublishResponse): GitQuickPublishResponse =
        response.copy(output = response.output?.takeLast(MAX_OUTPUT_CHARS))

    fun bound(response: GitPullRequestResponse): GitPullRequestResponse =
        response.copy(output = response.output?.takeLast(MAX_OUTPUT_CHARS))

    fun bound(response: GitTestFlightStatusResponse): GitTestFlightStatusResponse {
        val job = response.job ?: return response
        val clipped = job.output?.length?.let { it > MAX_OUTPUT_CHARS } == true
        return response.copy(
            job = job.copy(
                output = job.output?.takeLast(MAX_OUTPUT_CHARS),
                truncated = job.truncated == true || clipped,
            ),
        )
    }

    private fun validPath(path: String): String {
        require(path.isNotBlank() && path.length <= MAX_PATH_CHARS) { "Git path is invalid" }
        return path
    }
}
