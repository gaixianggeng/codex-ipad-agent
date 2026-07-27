package com.gaixianggeng.mimi.core.model

object SessionReminderPolicy {
    const val MAX_ID_CHARS = 512
    const val MAX_TITLE_CHARS = 180
    const val MAX_DELAY_MILLIS = 366L * 24L * 60L * 60L * 1_000L

    fun validate(reminder: SessionReminder, now: Long = System.currentTimeMillis()): SessionReminder {
        require(validId(reminder.profileId) && validId(reminder.projectId) && validId(reminder.threadId)) {
            "Reminder route is invalid"
        }
        require(
            reminder.title == reminder.title.trim() &&
                reminder.title.length in 1..MAX_TITLE_CHARS,
        ) { "Reminder title is invalid" }
        require(reminder.createdAtEpochMillis in 1..<reminder.fireAtEpochMillis) {
            "Reminder timestamps are invalid"
        }
        require(reminder.fireAtEpochMillis > now) { "Reminder time must be in the future" }
        require(reminder.fireAtEpochMillis - reminder.createdAtEpochMillis <= MAX_DELAY_MILLIS) {
            "Reminder delay is too long"
        }
        return reminder
    }

    fun validRoute(profileId: String, projectId: String, threadId: String): Boolean =
        validId(profileId) && validId(projectId) && validId(threadId)

    fun validId(value: String): Boolean =
        value == value.trim() && value.length in 1..MAX_ID_CHARS
}
