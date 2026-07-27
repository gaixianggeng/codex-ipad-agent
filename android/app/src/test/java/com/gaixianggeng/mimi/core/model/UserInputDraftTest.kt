package com.gaixianggeng.mimi.core.model

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UserInputDraftTest {
    @Test
    fun `single selection replaces previous answer`() {
        val question = question(id = "scope", multiSelect = false)
        val draft = UserInputDraft()
            .toggleOption(question, "unit")
            .toggleOption(question, "all")

        assertEquals(listOf("all"), draft.answers(question))
    }

    @Test
    fun `multi selection payload follows server option order and appends freeform`() {
        val question = question(id = "optimizations", multiSelect = true, isOther = true)
        val request = request(question)
        val draft = UserInputDraft()
            .toggleOption(question, "all")
            .toggleOption(question, "unit")
            .setFreeformAnswer(question.id, "  docs  ")

        assertEquals(listOf("unit", "all", "docs"), draft.answerPayload(request)[question.id])
    }

    @Test
    fun `submission requires an answer for every question`() {
        val first = question(id = "scope")
        val second = question(id = "notes", options = emptyList(), isOther = true)
        val request = request(first, second)
        val partial = UserInputDraft().toggleOption(first, "unit")

        assertEquals(1, partial.answeredCount(request))
        assertFalse(partial.canSubmit(request))

        val complete = partial.setFreeformAnswer(second.id, "Continue")
        assertEquals(2, complete.answeredCount(request))
        assertTrue(complete.canSubmit(request))
    }

    @Test
    fun `empty request can be submitted and unknown options are rejected`() {
        val emptyRequest = request()
        val question = question(id = "scope")
        val draft = UserInputDraft().toggleOption(question, "unknown")

        assertTrue(draft.canSubmit(emptyRequest))
        assertEquals(emptyMap<String, List<String>>(), draft.answerPayload(emptyRequest))
        assertFalse(draft.isSelected(question.id, "unknown"))
    }

    private fun request(vararg questions: UserInputQuestion) = UserInputRequest(
        requestId = JsonNull,
        method = "item/tool/requestUserInput",
        params = buildJsonObject {},
        id = "request-1",
        threadId = "thread-1",
        turnId = "turn-1",
        questions = questions.toList(),
    )

    private fun question(
        id: String,
        multiSelect: Boolean = false,
        isOther: Boolean = false,
        options: List<UserInputOption> = listOf(
            UserInputOption("unit", "Run unit tests"),
            UserInputOption("all", "Run the full suite"),
        ),
    ) = UserInputQuestion(
        id = id,
        header = id,
        question = "Choose $id",
        isOther = isOther,
        isSecret = false,
        options = options,
        multiSelect = multiSelect,
    )
}
