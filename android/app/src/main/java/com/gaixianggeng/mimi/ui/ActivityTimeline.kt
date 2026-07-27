package com.gaixianggeng.mimi.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.HourglassTop
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.gaixianggeng.mimi.R
import com.gaixianggeng.mimi.core.model.ConversationActivity
import com.gaixianggeng.mimi.core.model.ConversationActivityCategory
import com.gaixianggeng.mimi.core.model.ConversationMessage
import com.gaixianggeng.mimi.core.model.ConversationRole
import com.gaixianggeng.mimi.core.model.ConversationTurnLifecycle
import com.gaixianggeng.mimi.ui.theme.LocalMimiCodeFontFamily

internal sealed interface ConversationTimelineEntry {
    val key: String

    data class Message(val message: ConversationMessage) : ConversationTimelineEntry {
        override val key: String = "message:${message.id}"
    }

    data class ActivityGroup(
        val messages: List<ConversationMessage>,
    ) : ConversationTimelineEntry {
        override val key: String = "activity:${messages.first().id}"
    }
}

internal fun conversationTimelineEntries(messages: List<ConversationMessage>): List<ConversationTimelineEntry> {
    val result = mutableListOf<ConversationTimelineEntry>()
    var index = 0
    while (index < messages.size) {
        val message = messages[index]
        if (message.role != ConversationRole.Activity || message.activity == null) {
            result += ConversationTimelineEntry.Message(message)
            index += 1
            continue
        }
        val turnId = message.turnId
        val group = mutableListOf<ConversationMessage>()
        while (index < messages.size) {
            val candidate = messages[index]
            if (candidate.role != ConversationRole.Activity ||
                candidate.activity == null ||
                candidate.turnId != turnId
            ) {
                break
            }
            group += candidate
            index += 1
        }
        result += ConversationTimelineEntry.ActivityGroup(group)
    }
    return result
}

internal enum class TimelineStatus {
    Running,
    Pending,
    Completed,
    Interrupted,
    Failed,
}

@Composable
internal fun ActivityTimelineCard(
    messages: List<ConversationMessage>,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    if (messages.isEmpty()) return
    val status = groupStatus(messages)
    val statusText = groupStatusText(status)
    var expanded by rememberSaveable(messages.first().id) {
        mutableStateOf(status == TimelineStatus.Running || status == TimelineStatus.Failed)
    }
    val timelineStateDescription = stringResource(
        if (expanded) R.string.activity_state_expanded else R.string.activity_state_collapsed,
        statusText,
    )
    OutlinedCard(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(if (compact) 14.dp else 18.dp),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        colors = CardDefaults.outlinedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .semantics {
                    role = Role.Button
                    stateDescription = timelineStateDescription
                }
                .clickable { expanded = !expanded }
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TimelineStatusIcon(status, Modifier.size(22.dp))
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    statusText,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    pluralStringResource(R.plurals.activity_count, messages.size, messages.size),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Icon(
                if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = stringResource(if (expanded) R.string.collapse_activity else R.string.expand_activity),
            )
        }
        AnimatedVisibility(visible = expanded) {
            Column(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 12.dp)) {
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                Spacer(Modifier.height(8.dp))
                messages.forEachIndexed { index, message ->
                    val activity = requireNotNull(message.activity)
                    ActivityTimelineRow(
                        activity = activity,
                        lifecycle = message.turnLifecycle,
                        isLast = index == messages.lastIndex,
                        compact = compact,
                    )
                }
            }
        }
    }
}

@Composable
private fun ActivityTimelineRow(
    activity: ConversationActivity,
    lifecycle: ConversationTurnLifecycle,
    isLast: Boolean,
    compact: Boolean,
) {
    val status = timelineItemStatus(activity, lifecycle)
    val codeFontFamily = LocalMimiCodeFontFamily.current
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Column(
            Modifier.width(30.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            TimelineStatusIcon(status, Modifier.size(20.dp))
            if (!isLast) {
                Box(
                    Modifier
                        .width(2.dp)
                        .height(if (activity.category == ConversationActivityCategory.RunCommand && !compact) 16.dp else 22.dp)
                        .background(MaterialTheme.colorScheme.outlineVariant),
                )
            }
        }
        Spacer(Modifier.width(6.dp))
        Column(
            Modifier
                .weight(1f)
                .padding(bottom = if (isLast) 0.dp else 8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    activityIcon(activity.category),
                    contentDescription = null,
                    modifier = Modifier.size(17.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.width(7.dp))
                Text(
                    activityTitle(activity),
                    modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = if (compact) 2 else 3,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    itemStatusText(status),
                    style = MaterialTheme.typography.labelSmall,
                    color = statusColor(status),
                )
            }
            activity.subtitle
                ?.takeIf { it.isNotBlank() && activity.category == ConversationActivityCategory.ToolCall }
                ?.let(::plainActivityProgressText)
                ?.takeIf(String::isNotBlank)
                ?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            if (activity.category == ConversationActivityCategory.RunCommand &&
                (activity.command != null || activity.outputPreview != null || activity.cwd != null)
            ) {
                CommandActivityDetails(activity, compact)
            }
            if (activity.category == ConversationActivityCategory.EditFile && activity.filePaths.isNotEmpty()) {
                activity.filePaths.take(if (compact) 2 else 4).forEach { path ->
                    Text(
                        path,
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = codeFontFamily,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (activity.filePaths.size > if (compact) 2 else 4) {
                    val moreFileCount = activity.filePaths.size - if (compact) 2 else 4
                    Text(
                        pluralStringResource(R.plurals.more_files, moreFileCount, moreFileCount),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun CommandActivityDetails(activity: ConversationActivity, compact: Boolean) {
    var detailsExpanded by rememberSaveable(activity.command, activity.title) {
        mutableStateOf(activity.isFailure || activity.isComplete)
    }
    val clipboard = LocalClipboardManager.current
    val codeFontFamily = LocalMimiCodeFontFamily.current
    OutlinedCard(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.outlinedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 48.dp)
                .testTag("command_activity_details_toggle")
                .clickable { detailsExpanded = !detailsExpanded }
                .padding(start = 12.dp, top = 8.dp, bottom = 8.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Terminal, contentDescription = null, modifier = Modifier.size(17.dp))
            Spacer(Modifier.width(8.dp))
            Text(
                stringResource(R.string.command_details_title),
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.weight(1f),
            )
            Icon(
                if (detailsExpanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = stringResource(if (detailsExpanded) R.string.collapse_command_output else R.string.expand_command_output),
            )
        }
        AnimatedVisibility(detailsExpanded) {
            Column(Modifier.fillMaxWidth().padding(start = 12.dp, end = 6.dp, bottom = 10.dp)) {
                activity.command?.takeIf(String::isNotBlank)?.let { command ->
                    Row(verticalAlignment = Alignment.Top) {
                        Text(
                            command,
                            modifier = Modifier.weight(1f).padding(vertical = 6.dp),
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = codeFontFamily,
                        )
                        IconButton(
                            onClick = { clipboard.setText(AnnotatedString(command)) },
                            modifier = Modifier.size(48.dp),
                        ) {
                            Icon(
                                Icons.Filled.ContentCopy,
                                contentDescription = stringResource(R.string.copy_command),
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
                activity.cwd?.takeIf(String::isNotBlank)?.let { cwd ->
                    Text(
                        stringResource(R.string.working_directory_value, cwd),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                activity.outputPreview?.takeIf(String::isNotBlank)?.let { output ->
                    Spacer(Modifier.height(6.dp))
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceContainerHighest,
                        shape = RoundedCornerShape(8.dp),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Row(verticalAlignment = Alignment.Top) {
                            Text(
                                output,
                                Modifier
                                    .weight(1f)
                                    .padding(start = 10.dp, top = 10.dp, bottom = 10.dp)
                                    .heightIn(max = if (compact) 160.dp else 240.dp),
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = codeFontFamily,
                                maxLines = if (compact) 8 else 14,
                                overflow = TextOverflow.Ellipsis,
                            )
                            IconButton(
                                onClick = { clipboard.setText(AnnotatedString(output)) },
                                modifier = Modifier.size(48.dp),
                            ) {
                                Icon(
                                    Icons.Filled.ContentCopy,
                                    contentDescription = stringResource(R.string.copy_output),
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        }
                    }
                    if (activity.outputTruncated) {
                        Text(
                            stringResource(R.string.output_preview_truncated),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                activity.exitCode?.let { exitCode ->
                    Text(
                        stringResource(R.string.exit_code_value, exitCode),
                        style = MaterialTheme.typography.labelMedium,
                        color = if (exitCode == 0) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                    )
                }
            }
        }
    }
}

private fun groupStatus(messages: List<ConversationMessage>): TimelineStatus {
    if (messages.any { it.activity?.isFailure == true || it.turnLifecycle == ConversationTurnLifecycle.Failed }) {
        return TimelineStatus.Failed
    }
    if (messages.any { it.activity?.isCancelled == true || it.turnLifecycle == ConversationTurnLifecycle.Interrupted }) {
        return TimelineStatus.Interrupted
    }
    if (messages.any { it.activity?.isRunning == true } ||
        messages.any { it.turnLifecycle == ConversationTurnLifecycle.Running }
    ) {
        return TimelineStatus.Running
    }
    if (messages.any { it.activity?.isPending == true }) return TimelineStatus.Pending
    return TimelineStatus.Completed
}

internal fun timelineItemStatus(
    activity: ConversationActivity,
    lifecycle: ConversationTurnLifecycle,
): TimelineStatus = when {
    activity.isFailure -> TimelineStatus.Failed
    activity.isCancelled -> TimelineStatus.Interrupted
    activity.isComplete -> TimelineStatus.Completed
    activity.isRunning -> TimelineStatus.Running
    activity.isPending -> TimelineStatus.Pending
    lifecycle == ConversationTurnLifecycle.Failed -> TimelineStatus.Failed
    lifecycle == ConversationTurnLifecycle.Interrupted -> TimelineStatus.Interrupted
    lifecycle == ConversationTurnLifecycle.Running -> TimelineStatus.Running
    else -> TimelineStatus.Completed
}

@Composable
private fun groupStatusText(status: TimelineStatus): String = stringResource(
    when (status) {
        TimelineStatus.Running, TimelineStatus.Pending -> R.string.activity_working
        TimelineStatus.Completed -> R.string.activity_completed
        TimelineStatus.Interrupted -> R.string.activity_interrupted
        TimelineStatus.Failed -> R.string.activity_completed_with_errors
    },
)

@Composable
private fun itemStatusText(status: TimelineStatus): String = stringResource(
    when (status) {
        TimelineStatus.Running -> R.string.activity_status_running
        TimelineStatus.Pending -> R.string.activity_status_pending
        TimelineStatus.Completed -> R.string.activity_status_completed
        TimelineStatus.Interrupted -> R.string.activity_status_interrupted
        TimelineStatus.Failed -> R.string.activity_status_failed
    },
)

@Composable
private fun activityTitle(activity: ConversationActivity): String = when (activity.category) {
    ConversationActivityCategory.Thinking -> activity.subtitle
        ?.let(::plainActivityProgressText)
        ?.takeIf(String::isNotBlank)
        ?: stringResource(R.string.activity_reasoning)
    ConversationActivityCategory.Plan -> stringResource(R.string.activity_plan)
    ConversationActivityCategory.RunCommand -> activity.title.ifBlank { stringResource(R.string.activity_run_command) }
    ConversationActivityCategory.EditFile -> when {
        activity.filePaths.size > 1 -> pluralStringResource(
            R.plurals.activity_files_edited,
            activity.filePaths.size,
            activity.filePaths.size,
        )
        activity.filePaths.size == 1 -> stringResource(
            R.string.activity_file_edited,
            activity.filePaths.single().substringAfterLast('/').substringAfterLast('\\'),
        )
        else -> stringResource(R.string.activity_files_changed)
    }
    ConversationActivityCategory.ToolCall -> activity.toolName?.let {
        stringResource(R.string.activity_tool_value, it)
    } ?: stringResource(R.string.activity_tool_call)
    ConversationActivityCategory.Error -> activity.title.ifBlank { stringResource(R.string.activity_error) }
}

internal fun plainActivityProgressText(text: String): String = text
    .replace("**", "")
    .replace("`", "")
    .lineSequence()
    .map { rawLine ->
        var line = rawLine.trim()
        for (level in 6 downTo 1) {
            val prefix = "#".repeat(level) + " "
            if (line.startsWith(prefix)) {
                line = line.removePrefix(prefix)
                break
            }
        }
        if (line.length >= 2 &&
            (line.first() == '*' || line.first() == '_') &&
            line.last() == line.first()
        ) {
            line = line.substring(1, line.lastIndex)
        }
        line
    }
    .joinToString("\n")
    .trim()

private fun activityIcon(category: ConversationActivityCategory): ImageVector = when (category) {
    ConversationActivityCategory.Thinking -> Icons.Filled.HourglassTop
    ConversationActivityCategory.Plan -> Icons.Filled.Check
    ConversationActivityCategory.RunCommand -> Icons.Filled.Terminal
    ConversationActivityCategory.EditFile -> Icons.Filled.Edit
    ConversationActivityCategory.ToolCall -> Icons.Filled.Build
    ConversationActivityCategory.Error -> Icons.Filled.Error
}

@Composable
private fun TimelineStatusIcon(status: TimelineStatus, modifier: Modifier = Modifier) {
    when (status) {
        TimelineStatus.Running -> CircularProgressIndicator(
            modifier.semantics { contentDescription = "Running" },
            strokeWidth = 2.dp,
            color = MaterialTheme.colorScheme.primary,
        )
        TimelineStatus.Pending -> Icon(
            Icons.Outlined.RadioButtonUnchecked,
            contentDescription = itemStatusText(status),
            modifier = modifier,
            tint = MaterialTheme.colorScheme.outline,
        )
        TimelineStatus.Completed -> Icon(
            Icons.Filled.CheckCircle,
            contentDescription = itemStatusText(status),
            modifier = modifier,
            tint = successColor(),
        )
        TimelineStatus.Interrupted -> Icon(
            Icons.Filled.Error,
            contentDescription = itemStatusText(status),
            modifier = modifier,
            tint = MaterialTheme.colorScheme.tertiary,
        )
        TimelineStatus.Failed -> Icon(
            Icons.Filled.Error,
            contentDescription = itemStatusText(status),
            modifier = modifier,
            tint = MaterialTheme.colorScheme.error,
        )
    }
}

@Composable
private fun statusColor(status: TimelineStatus): Color = when (status) {
    TimelineStatus.Running -> MaterialTheme.colorScheme.primary
    TimelineStatus.Pending -> MaterialTheme.colorScheme.onSurfaceVariant
    TimelineStatus.Completed -> successColor()
    TimelineStatus.Interrupted -> MaterialTheme.colorScheme.tertiary
    TimelineStatus.Failed -> MaterialTheme.colorScheme.error
}

@Composable
private fun successColor(): Color {
    val dark = MaterialTheme.colorScheme.surface.red + MaterialTheme.colorScheme.surface.green +
        MaterialTheme.colorScheme.surface.blue < 1.5f
    return if (dark) Color(0xFF78D996) else Color(0xFF16883E)
}
