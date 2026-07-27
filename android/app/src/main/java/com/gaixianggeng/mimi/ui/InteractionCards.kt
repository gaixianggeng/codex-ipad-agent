package com.gaixianggeng.mimi.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.gaixianggeng.mimi.R
import com.gaixianggeng.mimi.core.model.ApprovalDecisionPolicy
import com.gaixianggeng.mimi.core.model.ApprovalRequest
import com.gaixianggeng.mimi.core.model.UserInputDraft
import com.gaixianggeng.mimi.core.model.UserInputQuestion
import com.gaixianggeng.mimi.core.model.UserInputRequest
import com.gaixianggeng.mimi.ui.theme.LocalMimiCodeFontFamily

@Composable
fun ApprovalCard(
    request: ApprovalRequest,
    submitting: Boolean,
    onDecision: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var confirmingPersistentPermission by remember(request.id) { mutableStateOf(false) }
    var detailsExpanded by remember(request.id) { mutableStateOf(true) }
    val codeFontFamily = LocalMimiCodeFontFamily.current
    val hasDecisionContext = ApprovalDecisionPolicy.hasDecisionContext(request)
    val canPersistPermission = ApprovalDecisionPolicy.canPersistPermission(request)
    val decisionAvailability = stringResource(
        if (hasDecisionContext) R.string.approval_available else R.string.approval_unavailable,
    )
    if (confirmingPersistentPermission) {
        PersistentPermissionConfirmation(
            request = request,
            onDismiss = { confirmingPersistentPermission = false },
            onConfirm = {
                confirmingPersistentPermission = false
                onDecision("acceptWithPermissionUpdate")
            },
        )
    }
    Card(
        modifier.fillMaxWidth().testTag("approval_card"),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(
                    shape = MaterialTheme.shapes.medium,
                    color = MaterialTheme.colorScheme.tertiary,
                ) {
                    Icon(
                        Icons.Filled.Security,
                        stringResource(R.string.approval_waiting),
                        tint = MaterialTheme.colorScheme.onTertiary,
                        modifier = Modifier.padding(10.dp).size(24.dp),
                    )
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        stringResource(R.string.approval_waiting),
                        style = MaterialTheme.typography.labelLarge,
                        modifier = Modifier.semantics { heading() },
                    )
                    Text(
                        approvalDisplayTitle(request),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ApprovalMetadata(
                    label = stringResource(R.string.approval_type),
                    value = approvalKindTitle(request.kind),
                )
                ApprovalMetadata(
                    label = stringResource(R.string.approval_risk),
                    value = approvalRiskTitle(request.risk),
                    isRisk = true,
                )
                request.count?.let { count ->
                    ApprovalMetadata(
                        label = stringResource(R.string.approval_impact),
                        value = pluralStringResource(R.plurals.approval_items_count, count, count),
                        modifier = Modifier.testTag("approval_impact"),
                    )
                }
            }
            OutlinedCard(
                Modifier.fillMaxWidth().clickable { detailsExpanded = !detailsExpanded }.testTag("approval_details_toggle"),
            ) {
                Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            stringResource(R.string.approval_details),
                            style = MaterialTheme.typography.labelLarge,
                            modifier = Modifier.weight(1f),
                        )
                        Icon(
                            if (detailsExpanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                            stringResource(if (detailsExpanded) R.string.collapse_action else R.string.expand_action),
                        )
                    }
                    if (detailsExpanded) {
                        HorizontalDivider(Modifier.padding(vertical = 8.dp))
                        if (request.body.isNullOrBlank()) {
                            Text(
                                stringResource(R.string.approval_details_not_available),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        } else {
                            SelectionContainer {
                                Text(
                                    request.body,
                                    style = MaterialTheme.typography.bodyMedium.copy(
                                        fontFamily = if (request.kind == "command") codeFontFamily else FontFamily.Default,
                                    ),
                                    modifier = Modifier.heightIn(max = 180.dp).verticalScroll(rememberScrollState())
                                        .testTag("approval_details_body"),
                                )
                            }
                        }
                    }
                }
            }
            if (submitting) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.testTag("approval_submitting"),
                ) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Text(
                        stringResource(R.string.approval_decision_sending),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onTertiaryContainer,
                    )
                }
            }
            if (!hasDecisionContext) {
                Surface(
                    shape = MaterialTheme.shapes.medium,
                    color = MaterialTheme.colorScheme.errorContainer,
                    modifier = Modifier.fillMaxWidth().testTag("approval_missing_context"),
                ) {
                    Text(
                        stringResource(R.string.approval_missing_details),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.padding(12.dp),
                    )
                }
            }
            FlowRow(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedButton(
                    onClick = { onDecision("decline") },
                    enabled = !submitting,
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.error),
                    modifier = Modifier.heightIn(min = 48.dp).testTag("approval_deny"),
                ) { Text(stringResource(R.string.deny_action)) }
                if (request.availableDecisions.any { it.equals("acceptForSession", true) }) {
                    OutlinedButton(
                        onClick = { onDecision("acceptForSession") },
                        enabled = !submitting && hasDecisionContext,
                        modifier = Modifier.heightIn(min = 48.dp).testTag("approval_allow_session")
                            .semantics {
                                stateDescription = decisionAvailability
                            },
                    ) { Text(stringResource(R.string.allow_for_session)) }
                }
                if (canPersistPermission) {
                    FilledTonalButton(
                        onClick = { confirmingPersistentPermission = true },
                        enabled = !submitting && hasDecisionContext,
                        modifier = Modifier.heightIn(min = 48.dp).testTag("approval_always_allow"),
                    ) { Text(stringResource(R.string.always_allow)) }
                }
                Button(
                    onClick = { onDecision("accept") },
                    enabled = !submitting && hasDecisionContext,
                    modifier = Modifier.heightIn(min = 48.dp).testTag("approval_allow_once")
                        .semantics {
                            stateDescription = decisionAvailability
                        },
                ) { Text(stringResource(R.string.allow_once)) }
            }
        }
    }
}

@Composable
private fun ApprovalMetadata(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    isRisk: Boolean = false,
) {
    Surface(
        modifier = modifier,
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(
            1.dp,
            if (isRisk) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.outlineVariant,
        ),
    ) {
        Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                value,
                style = MaterialTheme.typography.labelLarge,
                color = if (isRisk) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

@Composable
private fun approvalDisplayTitle(request: ApprovalRequest): String = when {
    request.kind == "command" && !request.body.isNullOrBlank() -> stringResource(R.string.approval_command_title)
    request.kind == "file_change" -> stringResource(R.string.approval_file_change_title)
    request.kind == "permission" -> stringResource(R.string.approval_permission_title)
    else -> request.title
}

@Composable
private fun approvalKindTitle(kind: String): String = stringResource(
    when (kind) {
        "command" -> R.string.approval_kind_command
        "file_change" -> R.string.approval_kind_file_change
        "permission" -> R.string.approval_kind_permission
        "mcp_elicitation" -> R.string.approval_kind_mcp
        else -> R.string.approval_kind_other
    },
)

@Composable
private fun approvalRiskTitle(risk: String?): String = stringResource(
    when (risk?.lowercase()) {
        "low" -> R.string.approval_risk_low
        "medium", "moderate" -> R.string.approval_risk_medium
        "high", "critical" -> R.string.approval_risk_high
        else -> R.string.approval_risk_unknown
    },
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PersistentPermissionConfirmation(
    request: ApprovalRequest,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    val width = with(LocalDensity.current) { LocalWindowInfo.current.containerSize.width.toDp() }
    if (width < 600.dp) {
        ModalBottomSheet(
            onDismissRequest = onDismiss,
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            modifier = Modifier.testTag("persistent_permission_confirmation"),
        ) {
            PersistentPermissionContent(
                request = request,
                modifier = Modifier.fillMaxHeight(0.88f),
                onDismiss = onDismiss,
                onConfirm = onConfirm,
            )
        }
    } else {
        Dialog(
            onDismissRequest = onDismiss,
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(
                shape = MaterialTheme.shapes.extraLarge,
                color = MaterialTheme.colorScheme.surface,
                tonalElevation = 6.dp,
                modifier = Modifier.fillMaxWidth(0.9f).widthIn(max = 560.dp).fillMaxHeight(0.82f)
                    .testTag("persistent_permission_confirmation"),
            ) {
                PersistentPermissionContent(
                    request = request,
                    onDismiss = onDismiss,
                    onConfirm = onConfirm,
                )
            }
        }
    }
}

@Composable
private fun PersistentPermissionContent(
    request: ApprovalRequest,
    modifier: Modifier = Modifier,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    val codeFontFamily = LocalMimiCodeFontFamily.current
    Column(
        modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            stringResource(R.string.persistent_permission_confirmation_title),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.semantics { heading() },
        )
        LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Text(stringResource(R.string.current_request), style = MaterialTheme.typography.labelLarge)
                Surface(
                    shape = MaterialTheme.shapes.medium,
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                ) {
                    Text(approvalDisplayTitle(request), Modifier.padding(12.dp))
                }
            }
            item {
                Text(stringResource(R.string.persistent_permission_exact_rules), style = MaterialTheme.typography.labelLarge)
            }
            items(request.persistentPermissionRules, key = { it }) { rule ->
                Surface(
                    shape = MaterialTheme.shapes.small,
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    SelectionContainer {
                        Text(
                            rule,
                            Modifier.padding(12.dp),
                            fontFamily = codeFontFamily,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
            }
            item {
                Surface(
                    shape = MaterialTheme.shapes.medium,
                    color = MaterialTheme.colorScheme.tertiaryContainer,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(Icons.Filled.Security, null, tint = MaterialTheme.colorScheme.onTertiaryContainer)
                        Text(
                            stringResource(R.string.persistent_permission_local_scope),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onTertiaryContainer,
                        )
                    }
                }
            }
        }
        HorizontalDivider()
        Row(
            Modifier.fillMaxWidth().imePadding().padding(bottom = 8.dp),
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.cancel_action))
            }
            Spacer(Modifier.width(8.dp))
            Button(
                onClick = onConfirm,
                modifier = Modifier.heightIn(min = 48.dp).testTag("persistent_permission_confirm"),
            ) {
                Text(stringResource(R.string.confirm_permission))
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UserInputCard(
    request: UserInputRequest,
    submitting: Boolean,
    onSubmit: (Map<String, List<String>>) -> Unit,
    modifier: Modifier = Modifier,
) {
    var draft by remember(request.id) { mutableStateOf(UserInputDraft()) }
    var expanded by remember(request.id) { mutableStateOf(true) }
    val answeredCount = draft.answeredCount(request)
    val totalCount = request.questions.size
    val progress = pluralStringResource(
        R.plurals.user_input_answered_progress,
        answeredCount,
        answeredCount,
        totalCount,
    )

    BoxWithConstraints(modifier.fillMaxWidth()) {
        if (expanded) {
            if (maxWidth < 600.dp) {
                val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
                ModalBottomSheet(
                    onDismissRequest = { expanded = false },
                    sheetState = sheetState,
                    modifier = Modifier.fillMaxHeight(0.96f),
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                ) {
                    UserInputForm(
                        request = request,
                        draft = draft,
                        submitting = submitting,
                        onDraftChange = { draft = it },
                        onDismiss = { expanded = false },
                        onSubmit = onSubmit,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            } else {
                Dialog(
                    onDismissRequest = { expanded = false },
                    properties = DialogProperties(usePlatformDefaultWidth = false),
                ) {
                    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                        Surface(
                            Modifier.fillMaxWidth().widthIn(max = 560.dp).fillMaxHeight(0.9f),
                            shape = MaterialTheme.shapes.extraLarge,
                            color = MaterialTheme.colorScheme.surfaceContainerHigh,
                            tonalElevation = 3.dp,
                        ) {
                            UserInputForm(
                                request = request,
                                draft = draft,
                                submitting = submitting,
                                onDraftChange = { draft = it },
                                onDismiss = { expanded = false },
                                onSubmit = onSubmit,
                                modifier = Modifier.fillMaxSize(),
                            )
                        }
                    }
                }
            }
        } else {
            OutlinedCard(
                onClick = { expanded = true },
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 72.dp)
                    .testTag("user-input-resume")
                    .semantics { stateDescription = progress },
                colors = CardDefaults.outlinedCardColors(
                    containerColor = MaterialTheme.colorScheme.secondaryContainer,
                ),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Icon(
                        Icons.AutoMirrored.Outlined.HelpOutline,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSecondaryContainer,
                    )
                    Column(Modifier.weight(1f)) {
                        Text(
                            stringResource(R.string.continue_user_input),
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            userInputRequestTitle(request),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            progress,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.primary,
                        )
                    }
                    Text(
                        stringResource(R.string.resume_action),
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            }
        }
    }
}

@Composable
private fun UserInputForm(
    request: UserInputRequest,
    draft: UserInputDraft,
    submitting: Boolean,
    onDraftChange: (UserInputDraft) -> Unit,
    onDismiss: () -> Unit,
    onSubmit: (Map<String, List<String>>) -> Unit,
    modifier: Modifier = Modifier,
) {
    val questionCount = request.questions.size
    Column(modifier) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
                .testTag("user-input-header"),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Surface(
                shape = MaterialTheme.shapes.large,
                color = MaterialTheme.colorScheme.primaryContainer,
            ) {
                Icon(
                    Icons.AutoMirrored.Outlined.HelpOutline,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimaryContainer,
                    modifier = Modifier.padding(12.dp),
                )
            }
            Column(Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.supplementary_information),
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.semantics { heading() },
                )
                Text(
                    pluralStringResource(R.plurals.user_input_question_count, questionCount, questionCount),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            IconButton(
                onClick = onDismiss,
                enabled = !submitting,
                modifier = Modifier.testTag("user-input-close"),
            ) {
                Icon(Icons.Filled.Close, stringResource(R.string.close_action))
            }
        }

        LazyColumn(
            Modifier.weight(1f).fillMaxWidth().testTag("user-input-question-list"),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = 16.dp,
                top = 8.dp,
                end = 16.dp,
                bottom = 16.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (request.questions.isEmpty()) {
                item {
                    Text(
                        stringResource(R.string.user_input_no_questions),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 24.dp),
                    )
                }
            } else {
                items(request.questions, key = UserInputQuestion::id) { question ->
                    UserInputQuestionCard(
                        question = question,
                        draft = draft,
                        submitting = submitting,
                        onDraftChange = onDraftChange,
                    )
                }
            }
        }

        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
            tonalElevation = 3.dp,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .imePadding()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                TextButton(
                    onClick = { onSubmit(emptyMap()) },
                    enabled = !submitting,
                    modifier = Modifier.heightIn(min = 48.dp).testTag("user-input-skip"),
                ) {
                    Text(stringResource(R.string.skip_action))
                }
                Button(
                    onClick = { onSubmit(draft.answerPayload(request)) },
                    enabled = !submitting && draft.canSubmit(request),
                    modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("user-input-submit"),
                ) {
                    if (submitting) {
                        CircularProgressIndicator(
                            Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                            color = MaterialTheme.colorScheme.onPrimary,
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.submitting_answers))
                    } else {
                        Text(stringResource(R.string.submit_answers))
                    }
                }
            }
        }
    }
}

@Composable
private fun UserInputQuestionCard(
    question: UserInputQuestion,
    draft: UserInputDraft,
    submitting: Boolean,
    onDraftChange: (UserInputDraft) -> Unit,
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        shape = MaterialTheme.shapes.large,
    ) {
        Column(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            question.header.trim().takeIf(String::isNotEmpty)?.let { header ->
                Text(
                    header,
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
            question.question.trim().takeIf(String::isNotEmpty)?.let { prompt ->
                Text(
                    prompt,
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.semantics { heading() },
                )
            }
            if (question.multiSelect && question.options.isNotEmpty()) {
                Text(
                    stringResource(R.string.multiple_selections_allowed),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            question.options.forEach { option ->
                val selected = draft.isSelected(question.id, option.label)
                val selectionModifier = if (question.multiSelect) {
                    Modifier.toggleable(
                        value = selected,
                        enabled = !submitting,
                        role = Role.Checkbox,
                        onValueChange = { onDraftChange(draft.toggleOption(question, option.label)) },
                    )
                } else {
                    Modifier.selectable(
                        selected = selected,
                        enabled = !submitting,
                        role = Role.RadioButton,
                        onClick = { onDraftChange(draft.toggleOption(question, option.label)) },
                    )
                }
                Surface(
                    color = if (selected) {
                        MaterialTheme.colorScheme.secondaryContainer
                    } else {
                        MaterialTheme.colorScheme.surface
                    },
                    contentColor = if (selected) {
                        MaterialTheme.colorScheme.onSecondaryContainer
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    },
                    shape = MaterialTheme.shapes.medium,
                    border = BorderStroke(
                        1.dp,
                        if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
                    ),
                ) {
                    Row(
                        selectionModifier
                            .fillMaxWidth()
                            .heightIn(min = 56.dp)
                            .testTag("user-input-option-${question.id}-${option.label}")
                            .padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        if (question.multiSelect) {
                            Checkbox(checked = selected, onCheckedChange = null, enabled = !submitting)
                        } else {
                            RadioButton(selected = selected, onClick = null, enabled = !submitting)
                        }
                        Column(Modifier.weight(1f)) {
                            Text(
                                option.label,
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.SemiBold,
                            )
                            option.description?.trim()?.takeIf(String::isNotEmpty)?.let { description ->
                                Text(
                                    description,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }
            }
            if (question.isOther || question.options.isEmpty()) {
                OutlinedTextField(
                    value = draft.freeformAnswer(question.id),
                    onValueChange = { onDraftChange(draft.setFreeformAnswer(question.id, it)) },
                    label = { Text(stringResource(R.string.your_answer)) },
                    visualTransformation = if (question.isSecret) {
                        PasswordVisualTransformation()
                    } else {
                        VisualTransformation.None
                    },
                    modifier = Modifier.fillMaxWidth().testTag("user-input-freeform-${question.id}"),
                    enabled = !submitting,
                    minLines = 1,
                    maxLines = 4,
                )
            }
        }
    }
}

@Composable
private fun userInputRequestTitle(request: UserInputRequest): String =
    request.questions.firstNotNullOfOrNull { question ->
        question.header.trim().takeIf(String::isNotEmpty)
            ?: question.question.trim().takeIf(String::isNotEmpty)
    } ?: stringResource(R.string.supplementary_information)
