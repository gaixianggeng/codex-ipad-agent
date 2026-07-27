package com.gaixianggeng.mimi.core.model

data class UserInputDraft(
    val selectedAnswers: Map<String, Set<String>> = emptyMap(),
    val freeformAnswers: Map<String, String> = emptyMap(),
) {
    fun toggleOption(question: UserInputQuestion, label: String): UserInputDraft {
        if (question.options.none { it.label == label }) return this
        val current = selectedAnswers[question.id].orEmpty()
        val next = if (question.multiSelect) {
            if (label in current) current - label else current + label
        } else {
            setOf(label)
        }
        return copy(
            selectedAnswers = if (next.isEmpty()) {
                selectedAnswers - question.id
            } else {
                selectedAnswers + (question.id to next)
            },
        )
    }

    fun setFreeformAnswer(questionId: String, answer: String): UserInputDraft = copy(
        freeformAnswers = if (answer.isEmpty()) {
            freeformAnswers - questionId
        } else {
            freeformAnswers + (questionId to answer)
        },
    )

    fun isSelected(questionId: String, label: String): Boolean =
        label in selectedAnswers[questionId].orEmpty()

    fun freeformAnswer(questionId: String): String = freeformAnswers[questionId].orEmpty()

    fun answers(question: UserInputQuestion): List<String> {
        val selected = selectedAnswers[question.id].orEmpty()
        return buildList {
            question.options
                .map(UserInputOption::label)
                .filter(selected::contains)
                .forEach(::add)
            freeformAnswer(question.id).trim().takeIf(String::isNotEmpty)?.let(::add)
        }.distinct()
    }

    fun answerPayload(request: UserInputRequest): Map<String, List<String>> = buildMap {
        request.questions.forEach { question ->
            answers(question).takeIf(List<String>::isNotEmpty)?.let { put(question.id, it) }
        }
    }

    fun answeredCount(request: UserInputRequest): Int =
        request.questions.count { answers(it).isNotEmpty() }

    fun canSubmit(request: UserInputRequest): Boolean =
        request.questions.all { answers(it).isNotEmpty() }
}
