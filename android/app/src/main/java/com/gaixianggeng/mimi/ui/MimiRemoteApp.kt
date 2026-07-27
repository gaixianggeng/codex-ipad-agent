package com.gaixianggeng.mimi.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.activity.BackEventCompat
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.BackHandler
import androidx.activity.compose.PredictiveBackHandler
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.PickVisualMediaRequest
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.PlaylistPlay
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.LaptopMac
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.core.content.ContextCompat
import com.gaixianggeng.mimi.app.MainUiState
import com.gaixianggeng.mimi.R
import com.gaixianggeng.mimi.ui.theme.LocalMimiCodeFontFamily
import com.gaixianggeng.mimi.ui.theme.MimiSpacing
import kotlin.math.roundToInt
import com.gaixianggeng.mimi.app.MainViewModel
import com.gaixianggeng.mimi.core.model.AgentProject
import com.gaixianggeng.mimi.core.model.AgentThread
import com.gaixianggeng.mimi.core.model.AdaptiveWorkspaceLayout
import com.gaixianggeng.mimi.core.model.AdaptiveWorkspacePolicy
import com.gaixianggeng.mimi.core.model.ConversationRole
import com.gaixianggeng.mimi.core.model.ConversationMessage
import com.gaixianggeng.mimi.core.model.ConversationFileReference
import com.gaixianggeng.mimi.core.model.DirectoryEntry
import com.gaixianggeng.mimi.core.model.ConversationFileReferenceDetector
import com.gaixianggeng.mimi.core.model.ConversationAttachmentKind
import com.gaixianggeng.mimi.core.model.ComposerSendMode
import com.gaixianggeng.mimi.core.model.CapabilityPickerPolicy
import com.gaixianggeng.mimi.core.model.GitActionKind
import com.gaixianggeng.mimi.core.model.GitMutationPolicy
import com.gaixianggeng.mimi.core.model.QueuedTurnState
import com.gaixianggeng.mimi.core.model.QueuedTurn
import com.gaixianggeng.mimi.core.model.QueuedSkill
import com.gaixianggeng.mimi.core.model.ImageAttachment
import com.gaixianggeng.mimi.core.model.PermissionMode
import com.gaixianggeng.mimi.core.model.PluginCapability
import com.gaixianggeng.mimi.core.model.ReviewTargetKind
import com.gaixianggeng.mimi.core.model.ThreadGoalStatus
import com.gaixianggeng.mimi.core.model.ThreadGoal
import com.gaixianggeng.mimi.core.model.ThreadGoalTransitionPolicy
import com.gaixianggeng.mimi.core.model.SessionReminder
import com.gaixianggeng.mimi.core.model.SessionContextSource
import com.gaixianggeng.mimi.core.model.SessionContextSubagent
import com.gaixianggeng.mimi.core.model.SessionContextTask
import com.gaixianggeng.mimi.core.model.SessionLibraryFilter
import com.gaixianggeng.mimi.core.model.SessionLibraryPolicy
import com.gaixianggeng.mimi.core.model.SessionRowStatus
import com.gaixianggeng.mimi.core.model.SkillCapability
import com.gaixianggeng.mimi.core.model.GitPatchParser
import com.gaixianggeng.mimi.core.logging.DiagnosticLogPolicy
import com.gaixianggeng.mimi.core.network.TurnLifecycleProjection
import coil3.compose.AsyncImage
import java.text.DateFormat
import java.util.Date

private enum class Destination(val label: String, val selected: ImageVector, val unselected: ImageVector) {
    Sessions("Sessions", Icons.Filled.Code, Icons.Outlined.ChatBubbleOutline),
    Projects("Projects", Icons.Filled.Folder, Icons.Outlined.Folder),
    Settings("Settings", Icons.Filled.Settings, Icons.Outlined.Settings),
}

private enum class InspectorSection(val labelRes: Int, val testTag: String) {
    Overview(R.string.inspector_overview, "inspector_section_overview"),
    Changes(R.string.inspector_changes, "inspector_section_changes"),
    Activity(R.string.inspector_activity, "inspector_section_activity"),
}

private enum class InspectorActivityMode(val labelRes: Int, val testTag: String) {
    Entries(R.string.inspector_entries, "inspector_activity_entries"),
    RawOutput(R.string.inspector_raw_output, "inspector_activity_raw_output"),
}

private enum class CapabilityPickerPage {
    Root,
    Skills,
    Plugins,
    Shortcuts,
}

@Composable
private fun destinationLabel(destination: Destination): String = when (destination) {
    Destination.Sessions -> stringResource(R.string.sessions)
    Destination.Projects -> stringResource(R.string.projects)
    Destination.Settings -> stringResource(R.string.settings)
}

@Composable
fun MimiRemoteApp(viewModel: MainViewModel, initialDeepLink: Uri?) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, viewModel) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> viewModel.setAppForeground(true)
                Lifecycle.Event.ON_STOP -> viewModel.setAppForeground(false)
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        viewModel.setAppForeground(lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(initialDeepLink) { viewModel.acceptDeepLink(initialDeepLink) }
    LaunchedEffect(state.error) {
        state.error?.let {
            snackbar.showSnackbar(it)
            viewModel.clearError()
        }
    }

    Surface(Modifier.fillMaxSize()) {
        state.pendingPairingLink?.takeIf { it.host == "connect" }?.let { link ->
            LegacyConnectionImportDialog(
                link = link,
                onImport = viewModel::confirmLegacyConnectionLink,
                onDismiss = viewModel::dismissLegacyConnectionLink,
            )
        }
        if (state.connected == null) {
            ConnectionScreen(state, viewModel, snackbar)
        } else {
            WorkspaceScreen(state, viewModel, snackbar)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConnectionScreen(state: MainUiState, viewModel: MainViewModel, snackbar: SnackbarHostState) {
    val context = LocalContext.current
    var showQrScanner by remember { mutableStateOf(false) }
    var permissionRecoveryMessage by rememberSaveable { mutableStateOf<String?>(null) }
    val localNetworkPermissionError = stringResource(R.string.local_network_permission_required)
    val emptyPairingCodeError = stringResource(R.string.pairing_qr_empty)
    val qrScannerError = stringResource(R.string.qr_scanner_failed)
    val cameraPermissionError = stringResource(R.string.camera_permission_required)
    val localNetworkPermission = "android.permission.ACCESS_LOCAL_NETWORK"
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) viewModel.connect()
        else permissionRecoveryMessage = localNetworkPermissionError
    }
    val connectWithPermission = {
        if (Build.VERSION.SDK_INT >= 37 &&
            ContextCompat.checkSelfPermission(context, localNetworkPermission) != PackageManager.PERMISSION_GRANTED
        ) {
            permissionLauncher.launch(localNetworkPermission)
        } else {
            viewModel.connect()
        }
    }
    val cameraPermissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) showQrScanner = true else permissionRecoveryMessage = cameraPermissionError
    }
    val scanPairingCode = {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            showQrScanner = true
        } else {
            cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
        }
    }
    permissionRecoveryMessage?.let { message ->
        PermissionRecoveryDialog(
            message = message,
            onDismiss = { permissionRecoveryMessage = null },
            onOpenSettings = {
                permissionRecoveryMessage = null
                context.startActivity(appPermissionSettingsIntent(context.packageName))
            },
        )
    }
    if (showQrScanner) {
        BundledQrScannerDialog(
            onDismiss = { showQrScanner = false },
            onCode = { value ->
                showQrScanner = false
                if (value.isBlank()) viewModel.showError(emptyPairingCodeError)
                else viewModel.acceptDeepLink(Uri.parse(value))
            },
            onError = { error ->
                showQrScanner = false
                viewModel.showError(error.message ?: qrScannerError)
            },
        )
    }
    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                title = { Text("Mimi Remote", fontWeight = FontWeight.SemiBold) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
            )
        },
    ) { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
            Card(
                Modifier.fillMaxWidth().padding(24.dp).width(520.dp)
                    .heightIn(max = (maxHeight - 48.dp).coerceAtLeast(320.dp)),
            ) {
                Column(
                    Modifier
                        .padding(24.dp)
                        .verticalScroll(rememberScrollState())
                        .testTag("connection_screen"),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Box(
                        Modifier.size(56.dp).clip(RoundedCornerShape(18.dp))
                            .background(MaterialTheme.colorScheme.primaryContainer),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Filled.LaptopMac, null, tint = MaterialTheme.colorScheme.primary)
                    }
                    Text(
                        stringResource(R.string.connect_title),
                        style = MaterialTheme.typography.headlineSmall,
                        modifier = Modifier.semantics { heading() },
                    )
                    Text(
                        stringResource(R.string.connect_description),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    OutlinedButton(
                        onClick = scanPairingCode,
                        enabled = !state.loading,
                        modifier = Modifier.fillMaxWidth(),
                        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 14.dp),
                    ) {
                        Icon(Icons.Filled.Code, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.scan_pairing_qr))
                    }
                    Text(
                        stringResource(R.string.manual_connection_details),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.align(Alignment.CenterHorizontally),
                    )
                    ConnectionDetailsFields(
                        displayName = state.displayName,
                        endpoint = state.endpoint,
                        token = state.token,
                        onDisplayNameChange = viewModel::setDisplayName,
                        onEndpointChange = viewModel::setEndpoint,
                        onTokenChange = viewModel::setToken,
                    )
                    Button(
                        onClick = connectWithPermission,
                        enabled = !state.loading,
                        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 14.dp),
                        modifier = Modifier.fillMaxWidth().testTag("connection_submit"),
                    ) {
                        if (state.loading) {
                            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        } else {
                            Text(stringResource(R.string.connect))
                            Spacer(Modifier.width(8.dp))
                            Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.size(18.dp))
                        }
                    }
                    Text(
                        stringResource(R.string.connection_security_note),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (state.profiles.isNotEmpty()) {
                        HorizontalDivider()
                        Text(
                            stringResource(R.string.saved_macs),
                            style = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.semantics { heading() },
                        )
                        state.profiles.forEach { profile ->
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text(profile.displayName, fontWeight = FontWeight.Medium)
                                    Text(profile.endpoint, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                TextButton(onClick = { viewModel.switchProfile(profile.id) }, enabled = !state.loading) { Text(stringResource(R.string.connect)) }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun ConnectionDetailsFields(
    displayName: String,
    endpoint: String,
    token: String,
    onDisplayNameChange: (String) -> Unit,
    onEndpointChange: (String) -> Unit,
    onTokenChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val endpointFocusRequester = remember { FocusRequester() }
    val tokenFocusRequester = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    Column(modifier, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        OutlinedTextField(
            value = displayName,
            onValueChange = onDisplayNameChange,
            label = { Text(stringResource(R.string.computer_name)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Text,
                imeAction = ImeAction.Next,
            ),
            keyboardActions = KeyboardActions(onNext = { endpointFocusRequester.requestFocus() }),
            modifier = Modifier.fillMaxWidth().testTag("connection_display_name"),
        )
        OutlinedTextField(
            value = endpoint,
            onValueChange = onEndpointChange,
            label = { Text(stringResource(R.string.agent_address)) },
            placeholder = { Text("192.168.1.10:8787") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Uri,
                imeAction = ImeAction.Next,
            ),
            keyboardActions = KeyboardActions(onNext = { tokenFocusRequester.requestFocus() }),
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(endpointFocusRequester)
                .testTag("connection_endpoint"),
        )
        OutlinedTextField(
            value = token,
            onValueChange = onTokenChange,
            label = { Text(stringResource(R.string.access_token)) },
            visualTransformation = PasswordVisualTransformation(),
            singleLine = true,
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Password,
                imeAction = ImeAction.Done,
            ),
            keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(tokenFocusRequester)
                .testTag("connection_token"),
        )
    }
}

@Composable
private fun WorkspaceScreen(state: MainUiState, viewModel: MainViewModel, snackbar: SnackbarHostState) {
    var destination by rememberSaveable { mutableStateOf(Destination.Sessions) }
    FilePreviewDialog(state, viewModel)
    val adaptiveInfo = currentWindowAdaptiveInfo()
    val posture = adaptiveInfo.windowPosture
    val density = LocalDensity.current
    val separatingVerticalHinge = posture.hingeList.firstOrNull { it.isVertical && it.isSeparating }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val layout = AdaptiveWorkspacePolicy.resolve(
            widthDp = maxWidth.value,
            isTabletop = posture.isTabletop,
            hasSeparatingVerticalHinge = separatingVerticalHinge != null,
        )
        if (layout == AdaptiveWorkspaceLayout.SeparatingVerticalHinge) {
            checkNotNull(separatingVerticalHinge)
            val leftWidth = with(density) { separatingVerticalHinge.bounds.left.toDp() }.coerceAtLeast(260.dp)
            val hingeWidth = with(density) { separatingVerticalHinge.bounds.width.toDp() }.coerceAtLeast(1.dp)
            Row(Modifier.fillMaxSize()) {
                Row(Modifier.width(leftWidth).fillMaxHeight()) {
                    AppNavigationRail(destination, viewModel::newSession) { destination = it }
                    HorizontalDivider(Modifier.fillMaxHeight().width(1.dp))
                    ProjectPane(state, viewModel, Modifier.weight(1f).fillMaxHeight())
                }
                Spacer(Modifier.width(hingeWidth).fillMaxHeight())
                if (destination == Destination.Settings) {
                    InspectorPane(state, viewModel, Modifier.weight(1f).fillMaxHeight(), settingsMode = true)
                } else {
                    MainPane(state, destination, viewModel, Modifier.weight(1f).fillMaxHeight())
                }
            }
            SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter))
        } else if (layout == AdaptiveWorkspaceLayout.Expanded) {
            Row(Modifier.fillMaxSize()) {
                AppNavigationRail(destination, viewModel::newSession) { destination = it }
                HorizontalDivider(Modifier.fillMaxHeight().width(1.dp))
                if (destination == Destination.Settings) {
                    InspectorPane(state, viewModel, Modifier.weight(1f).fillMaxHeight(), settingsMode = true)
                } else {
                    ProjectPane(state, viewModel, Modifier.width(280.dp).fillMaxHeight())
                    HorizontalDivider(Modifier.fillMaxHeight().width(1.dp))
                    MainPane(state, destination, viewModel, Modifier.weight(1f).fillMaxHeight())
                    HorizontalDivider(Modifier.fillMaxHeight().width(1.dp))
                    InspectorPane(state, viewModel, Modifier.width(320.dp).fillMaxHeight())
                }
            }
            SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter))
        } else if (layout == AdaptiveWorkspaceLayout.Medium) {
            Row(Modifier.fillMaxSize()) {
                AppNavigationRail(destination, viewModel::newSession) { destination = it }
                HorizontalDivider(Modifier.fillMaxHeight().width(1.dp))
                if (destination == Destination.Settings) {
                    InspectorPane(state, viewModel, Modifier.weight(1f).fillMaxHeight(), settingsMode = true)
                } else {
                    ProjectPane(state, viewModel, Modifier.width(300.dp).fillMaxHeight())
                    HorizontalDivider(Modifier.fillMaxHeight().width(1.dp))
                    MainPane(state, destination, viewModel, Modifier.weight(1f).fillMaxHeight())
                }
            }
            SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter))
        } else {
            var predictiveBackProgress by remember { mutableFloatStateOf(0f) }
            var predictiveBackDirection by remember { mutableFloatStateOf(1f) }
            SessionPredictiveBackHandler(
                enabled = destination == Destination.Sessions && state.selectedThreadId != null,
                onProgress = { progress, swipeEdge ->
                    predictiveBackProgress = progress
                    predictiveBackDirection = if (swipeEdge == BackEventCompat.EDGE_RIGHT) -1f else 1f
                },
                onBack = viewModel::showSessionList,
            )
            Scaffold(
                snackbarHost = { SnackbarHost(snackbar) },
                bottomBar = {
                    AppBottomBar(destination) { selected ->
                        if (
                            selected == Destination.Sessions &&
                            destination == Destination.Sessions &&
                            state.selectedThreadId != null
                        ) {
                            viewModel.showSessionList()
                        }
                        destination = selected
                    }
                },
            ) { padding ->
                when (destination) {
                    Destination.Projects -> ProjectPane(state, viewModel, Modifier.padding(padding).fillMaxSize())
                    Destination.Settings -> InspectorPane(state, viewModel, Modifier.padding(padding).fillMaxSize(), settingsMode = true)
                    Destination.Sessions -> MainPane(
                        state,
                        destination,
                        viewModel,
                        Modifier
                            .padding(padding)
                            .fillMaxSize()
                            .graphicsLayer {
                                val progress = predictiveBackProgress
                                translationX = size.width * 0.08f * progress * predictiveBackDirection
                                scaleX = 1f - (0.04f * progress)
                                scaleY = 1f - (0.04f * progress)
                                alpha = 1f - (0.08f * progress)
                            },
                        showSessionBack = true,
                    )
                }
            }
        }
    }
}

@Composable
internal fun SessionPredictiveBackHandler(
    enabled: Boolean,
    onProgress: (progress: Float, swipeEdge: Int) -> Unit,
    onBack: () -> Unit,
) {
    PredictiveBackHandler(enabled = enabled) { progress ->
        try {
            progress.collect { event ->
                onProgress(event.progress.coerceIn(0f, 1f), event.swipeEdge)
            }
            onBack()
        } finally {
            onProgress(0f, BackEventCompat.EDGE_LEFT)
        }
    }
}

@Composable
private fun FilePreviewDialog(state: MainUiState, viewModel: MainViewModel) {
    val preview = state.filePreview ?: return
    val context = LocalContext.current
    val localPath = state.filePreviewLocalPath
    val chooserTitle = stringResource(R.string.open_with_file, preview.name)
    val noFileViewerMessage = stringResource(R.string.no_file_viewer)
    val openExternally: () -> Unit = {
        runCatching {
            val intent = artifactViewIntent(context, requireNotNull(localPath), preview.contentType)
            context.startActivity(
                Intent.createChooser(
                    intent,
                    chooserTitle,
                ),
            )
        }.onFailure {
            viewModel.showError(it.message ?: noFileViewerMessage)
        }
        Unit
    }
    AlertDialog(
        onDismissRequest = viewModel::clearFilePreview,
        title = { Text(preview.name) },
        text = {
            when {
                preview.contentType.startsWith("image/") -> AsyncImage(
                    model = "data:${preview.contentType};base64,${preview.contentBase64}",
                    contentDescription = preview.name,
                    modifier = Modifier.fillMaxWidth().heightIn(max = 440.dp),
                )
                preview.contentType.startsWith("text/") || preview.contentType.contains("json") -> {
                    val decoded = remember(preview.contentBase64) {
                        runCatching { Base64.decode(preview.contentBase64, Base64.DEFAULT).toString(Charsets.UTF_8).take(200_000) }
                            .getOrDefault("Could not decode text preview")
                    }
                    Text(decoded, Modifier.heightIn(max = 440.dp).verticalScroll(rememberScrollState()))
                }
                else -> Text(pluralStringResource(R.plurals.external_file_hint, preview.size.toInt(), preview.contentType, preview.size))
            }
        },
        confirmButton = {
            Row {
                if (localPath != null) TextButton(onClick = openExternally) { Text(stringResource(R.string.open_action)) }
                TextButton(onClick = viewModel::clearFilePreview) { Text(stringResource(R.string.close_action)) }
            }
        },
        modifier = Modifier.testTag("file_preview_dialog"),
    )
}

@Composable
private fun AppBottomBar(selected: Destination, onSelect: (Destination) -> Unit) {
    NavigationBar {
        Destination.entries.forEach { item ->
            NavigationBarItem(
                selected = selected == item,
                onClick = { onSelect(item) },
                icon = { Icon(if (selected == item) item.selected else item.unselected, null) },
                label = { Text(destinationLabel(item)) },
            )
        }
    }
}

@Composable
private fun AppNavigationRail(selected: Destination, onNewSession: () -> Unit, onSelect: (Destination) -> Unit) {
    NavigationRail(header = {
        FilledIconButton(onClick = onNewSession) { Icon(Icons.Filled.Add, stringResource(R.string.new_session)) }
    }) {
        Spacer(Modifier.height(12.dp))
        Destination.entries.forEach { item ->
            NavigationRailItem(
                selected = selected == item,
                onClick = { onSelect(item) },
                icon = { Icon(if (selected == item) item.selected else item.unselected, null) },
                label = { Text(destinationLabel(item)) },
            )
        }
    }
}

private class SessionActionDialogState {
    var renameThreadId by mutableStateOf<String?>(null)
    var renameValue by mutableStateOf("")
    var archiveThreadId by mutableStateOf<String?>(null)
    var compactThreadId by mutableStateOf<String?>(null)
    var reviewThreadId by mutableStateOf<String?>(null)
    var reviewKind by mutableStateOf(ReviewTargetKind.UncommittedChanges)
    var reviewValue by mutableStateOf("")
    var goalThreadId by mutableStateOf<String?>(null)

    fun requestRename(thread: AgentThread) {
        renameThreadId = thread.id
        renameValue = thread.preview
    }

    fun requestReview(threadId: String) {
        reviewThreadId = threadId
        reviewKind = ReviewTargetKind.UncommittedChanges
        reviewValue = ""
    }
}

@Composable
private fun rememberSessionActionDialogState(): SessionActionDialogState =
    remember { SessionActionDialogState() }

@Composable
private fun SessionActionDialogs(
    dialogState: SessionActionDialogState,
    state: MainUiState,
    viewModel: MainViewModel,
) {
    dialogState.renameThreadId?.let { threadId ->
        AlertDialog(
            onDismissRequest = { dialogState.renameThreadId = null },
            title = { Text(stringResource(R.string.rename_session)) },
            text = {
                OutlinedTextField(
                    dialogState.renameValue,
                    { dialogState.renameValue = it },
                    label = { Text(stringResource(R.string.session_name)) },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.renameThread(threadId, dialogState.renameValue)
                        dialogState.renameThreadId = null
                    },
                    enabled = dialogState.renameValue.isNotBlank(),
                ) { Text(stringResource(R.string.save_action)) }
            },
            dismissButton = {
                TextButton(onClick = { dialogState.renameThreadId = null }) {
                    Text(stringResource(R.string.cancel_action))
                }
            },
        )
    }
    dialogState.archiveThreadId?.let { threadId ->
        AlertDialog(
            onDismissRequest = { dialogState.archiveThreadId = null },
            title = { Text(stringResource(R.string.archive_session_question)) },
            text = { Text(stringResource(R.string.archive_session_detail)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.archiveThread(threadId)
                    dialogState.archiveThreadId = null
                }) { Text(stringResource(R.string.archive_action)) }
            },
            dismissButton = {
                TextButton(onClick = { dialogState.archiveThreadId = null }) {
                    Text(stringResource(R.string.cancel_action))
                }
            },
        )
    }
    dialogState.compactThreadId?.let { threadId ->
        AlertDialog(
            onDismissRequest = { dialogState.compactThreadId = null },
            title = { Text(stringResource(R.string.compact_context_question)) },
            text = { Text(stringResource(R.string.compact_context_detail)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.compactThread(threadId)
                    dialogState.compactThreadId = null
                }) { Text(stringResource(R.string.compact_action)) }
            },
            dismissButton = {
                TextButton(onClick = { dialogState.compactThreadId = null }) {
                    Text(stringResource(R.string.cancel_action))
                }
            },
        )
    }
    dialogState.reviewThreadId?.let { threadId ->
        AlertDialog(
            onDismissRequest = { dialogState.reviewThreadId = null },
            title = { Text(stringResource(R.string.start_code_review)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        stringResource(R.string.review_inline_detail),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    ReviewTargetKind.entries.forEach { kind ->
                        val kindLabel = stringResource(
                            when (kind) {
                                ReviewTargetKind.UncommittedChanges -> R.string.review_uncommitted
                                ReviewTargetKind.BaseBranch -> R.string.review_base_branch
                                ReviewTargetKind.Commit -> R.string.review_specific_commit
                            },
                        )
                        OutlinedButton(
                            onClick = {
                                dialogState.reviewKind = kind
                                dialogState.reviewValue = ""
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text((if (dialogState.reviewKind == kind) "✓ " else "") + kindLabel)
                        }
                    }
                    if (dialogState.reviewKind != ReviewTargetKind.UncommittedChanges) {
                        OutlinedTextField(
                            value = dialogState.reviewValue,
                            onValueChange = { dialogState.reviewValue = it },
                            label = {
                                Text(
                                    stringResource(
                                        if (dialogState.reviewKind == ReviewTargetKind.BaseBranch) {
                                            R.string.base_branch
                                        } else {
                                            R.string.commit_sha
                                        },
                                    ),
                                )
                            },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.startReview(
                            threadId,
                            dialogState.reviewKind,
                            dialogState.reviewValue,
                        )
                        dialogState.reviewThreadId = null
                    },
                    enabled = !state.reviewLoading &&
                        (
                            dialogState.reviewKind == ReviewTargetKind.UncommittedChanges ||
                                dialogState.reviewValue.isNotBlank()
                            ),
                ) { Text(stringResource(R.string.start_review)) }
            },
            dismissButton = {
                TextButton(onClick = { dialogState.reviewThreadId = null }) {
                    Text(stringResource(R.string.cancel_action))
                }
            },
        )
    }
    dialogState.goalThreadId?.let { threadId ->
        ThreadGoalEditorDialog(
            threadId = threadId,
            goal = state.threadGoals[threadId],
            loading = state.goalLoading,
            onDismiss = { dialogState.goalThreadId = null },
            onSave = { objective, status, budget ->
                viewModel.setThreadGoal(threadId, objective, status, budget) {
                    dialogState.goalThreadId = null
                }
            },
        )
    }
}

@Composable
private fun ProjectPane(state: MainUiState, viewModel: MainViewModel, modifier: Modifier = Modifier) {
    val sessionActions = rememberSessionActionDialogState()
    SessionActionDialogs(sessionActions, state, viewModel)
    Column(modifier.background(MaterialTheme.colorScheme.surfaceContainerLow)) {
        PaneHeader(stringResource(R.string.projects), pluralStringResource(R.plurals.projects_available, state.projects.size, state.projects.size))
        LazyColumn(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)) {
            items(state.projects, key = { it.id }) { project ->
                ProjectRow(project, state.selectedProjectId == project.id) { viewModel.selectProject(project.id) }
            }
            if (state.selectedProjectId != null) {
                item {
                    Row(
                        Modifier.fillMaxWidth().padding(top = 16.dp, bottom = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(stringResource(R.string.sessions_title), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                        IconButton(onClick = viewModel::newSession) { Icon(Icons.Filled.Add, stringResource(R.string.new_session)) }
                    }
                    if (state.availableRuntimeProviders.size > 1) {
                        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            state.availableRuntimeProviders.forEach { runtime ->
                                val label = if (runtime == "claude") "Claude (experimental)" else "Codex"
                                if (state.newSessionRuntimeProvider == runtime) Button(onClick = { }) { Text(label) }
                                else OutlinedButton(onClick = { viewModel.setNewSessionRuntime(runtime) }) { Text(label) }
                            }
                        }
                    }
                }
                item {
                    SessionSearchField(
                        value = state.sessionSearchQuery,
                        onValueChange = viewModel::setSessionSearchQuery,
                        placeholder = { Text(stringResource(R.string.search_sessions)) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                val snippets = state.sessionSearchResults.associate { it.thread.id to it.snippet }
                items(visibleThreads(state), key = { "thread-${it.id}" }) { thread ->
                    ThreadRow(
                        thread = thread,
                        selected = state.selectedThreadId == thread.id,
                        status = sessionRowStatus(state, thread),
                        subtitle = snippets[thread.id],
                        onClick = { viewModel.selectThread(thread.id) },
                        onRename = { sessionActions.requestRename(thread) },
                        onArchive = { sessionActions.archiveThreadId = thread.id },
                        onCompact = { sessionActions.compactThreadId = thread.id },
                        onFork = { viewModel.forkThread(thread.id) },
                        pinned = thread.id in state.pinnedThreadIds,
                        onTogglePin = { viewModel.togglePinnedThread(thread.id) },
                        onReview = { sessionActions.requestReview(thread.id) },
                        onEditGoal = {
                            sessionActions.goalThreadId = thread.id
                        },
                        goal = state.threadGoals[thread.id],
                        reminder = state.sessionReminders[thread.id],
                        onRemindIn = { delay -> viewModel.scheduleSessionReminder(thread.id, delay) },
                        onClearReminder = { viewModel.clearSessionReminder(thread.id) },
                    )
                }
                if (state.sessionSearchQuery.isBlank() && state.threadCursor != null) {
                    item { TextButton(onClick = viewModel::loadMoreThreads, enabled = !state.loading) { Text(stringResource(R.string.load_more_sessions)) } }
                }
                if (state.sessionSearchCursor != null) {
                    item { TextButton(onClick = viewModel::loadMoreSessionSearch, enabled = !state.sessionSearchLoading) { Text(stringResource(R.string.more_results)) } }
                }
                state.recentlyArchivedThread?.let {
                    item { OutlinedButton(onClick = viewModel::restoreRecentlyArchived) { Text(stringResource(R.string.restore_session, it.preview)) } }
                }
            }
        }
    }
}

private fun sessionRowStatus(state: MainUiState, thread: AgentThread): SessionRowStatus =
    SessionLibraryPolicy.status(
        context = thread.context?.status,
        hasActiveTurn = state.selectedThreadId == thread.id &&
            TurnLifecycleProjection.isBusy(state.activeTurnId, state.awaitingTurnIdentity),
        hasPendingApproval = thread.id in state.pendingApprovals,
        hasPendingUserInput = thread.id in state.pendingUserInputs,
    )

@Composable
private fun sessionRowStatusTitle(status: SessionRowStatus): String = stringResource(
    when (status) {
        SessionRowStatus.WaitingForApproval -> R.string.session_status_waiting_approval
        SessionRowStatus.WaitingForInput -> R.string.session_status_waiting_input
        SessionRowStatus.Running -> R.string.session_status_running
        SessionRowStatus.Failed -> R.string.session_status_failed
        SessionRowStatus.Complete -> R.string.session_status_complete
        SessionRowStatus.Ended -> R.string.session_status_ended
        SessionRowStatus.Idle -> R.string.session_status_idle
        SessionRowStatus.History -> R.string.session_status_history
        SessionRowStatus.Unknown -> R.string.session_status_unknown
    },
)

@Composable
internal fun SessionStatusPill(
    status: SessionRowStatus,
    modifier: Modifier = Modifier,
) {
    val (container, content) = when (status) {
        SessionRowStatus.WaitingForApproval,
        SessionRowStatus.WaitingForInput,
        -> MaterialTheme.colorScheme.tertiaryContainer to MaterialTheme.colorScheme.onTertiaryContainer
        SessionRowStatus.Running ->
            MaterialTheme.colorScheme.primaryContainer to MaterialTheme.colorScheme.onPrimaryContainer
        SessionRowStatus.Failed ->
            MaterialTheme.colorScheme.errorContainer to MaterialTheme.colorScheme.onErrorContainer
        SessionRowStatus.Complete ->
            MaterialTheme.colorScheme.secondaryContainer to MaterialTheme.colorScheme.onSecondaryContainer
        SessionRowStatus.Ended,
        SessionRowStatus.Idle,
        SessionRowStatus.History,
        SessionRowStatus.Unknown,
        -> MaterialTheme.colorScheme.surfaceVariant to MaterialTheme.colorScheme.onSurfaceVariant
    }
    Surface(
        modifier = modifier.testTag("session_status_${status.name}"),
        color = container,
        contentColor = content,
        shape = CircleShape,
    ) {
        Row(
            Modifier.heightIn(min = 28.dp).padding(horizontal = 9.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (status == SessionRowStatus.Running) {
                CircularProgressIndicator(
                    Modifier.size(12.dp),
                    strokeWidth = 1.5.dp,
                    color = content,
                )
                Spacer(Modifier.width(5.dp))
            }
            Text(sessionRowStatusTitle(status), style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
private fun SessionMetadataPill(
    text: String,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier,
        color = MaterialTheme.colorScheme.surfaceContainerHighest,
        contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
        shape = CircleShape,
    ) {
        Text(
            text,
            Modifier.heightIn(min = 28.dp).padding(horizontal = 9.dp, vertical = 5.dp),
            style = MaterialTheme.typography.labelSmall,
        )
    }
}

@Composable
private fun sessionLibraryFilterTitle(filter: SessionLibraryFilter): String = stringResource(
    when (filter) {
        SessionLibraryFilter.All -> R.string.session_filter_all
        SessionLibraryFilter.Active -> R.string.session_filter_active
        SessionLibraryFilter.NeedsAttention -> R.string.session_filter_attention
        SessionLibraryFilter.History -> R.string.session_filter_history
    },
)

@Composable
internal fun SessionLibraryFilterBar(
    selected: SessionLibraryFilter,
    onSelect: (SessionLibraryFilter) -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyRow(
        modifier = modifier.fillMaxWidth().testTag("session_filter_bar"),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(vertical = 2.dp),
    ) {
        items(SessionLibraryFilter.entries, key = SessionLibraryFilter::name) { filter ->
            FilterChip(
                selected = selected == filter,
                onClick = { onSelect(filter) },
                label = { Text(sessionLibraryFilterTitle(filter)) },
                modifier = Modifier.testTag("session_filter_${filter.name}"),
            )
        }
    }
}

@Composable
private fun SessionSearchField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: @Composable () -> Unit,
    modifier: Modifier = Modifier,
) {
    TextField(
        value = value,
        onValueChange = onValueChange,
        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
        placeholder = placeholder,
        singleLine = true,
        shape = CircleShape,
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            disabledContainerColor = MaterialTheme.colorScheme.surfaceContainerLow,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            disabledIndicatorColor = Color.Transparent,
            errorIndicatorColor = Color.Transparent,
        ),
        modifier = modifier,
    )
}

@Composable
private fun SessionSectionHeader(
    title: String,
    count: Int,
) {
    Row(
        Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
        Text(count.toString(), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SessionActionsMenu(
    pinned: Boolean,
    reminder: SessionReminder?,
    onRename: () -> Unit,
    onArchive: () -> Unit,
    onCompact: () -> Unit,
    onFork: () -> Unit,
    onTogglePin: () -> Unit,
    onReview: () -> Unit,
    onEditGoal: () -> Unit,
    onRemindIn: (Long) -> Unit,
    onClearReminder: () -> Unit,
    buttonTestTag: String,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        IconButton(
            onClick = { expanded = true },
            modifier = Modifier.testTag(buttonTestTag),
        ) {
            Icon(Icons.Filled.MoreVert, stringResource(R.string.session_actions))
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.rename_action)) },
                onClick = { expanded = false; onRename() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(if (pinned) R.string.unpin_action else R.string.pin_action)) },
                onClick = { expanded = false; onTogglePin() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.review_changes)) },
                onClick = { expanded = false; onReview() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.goal_action)) },
                onClick = { expanded = false; onEditGoal() },
            )
            if (reminder == null) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.remind_30_minutes)) },
                    onClick = { expanded = false; onRemindIn(30 * 60 * 1_000L) },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.remind_1_hour)) },
                    onClick = { expanded = false; onRemindIn(60 * 60 * 1_000L) },
                )
            } else {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.clear_reminder)) },
                    onClick = { expanded = false; onClearReminder() },
                )
            }
            DropdownMenuItem(
                text = { Text(stringResource(R.string.fork_action)) },
                onClick = { expanded = false; onFork() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.compact_context)) },
                onClick = { expanded = false; onCompact() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.archive_action)) },
                onClick = { expanded = false; onArchive() },
            )
        }
    }
}

@Composable
internal fun SessionLibraryCard(
    thread: AgentThread,
    status: SessionRowStatus,
    selected: Boolean,
    pinned: Boolean,
    reminder: SessionReminder?,
    goal: ThreadGoal?,
    snippet: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onRename: () -> Unit = {},
    onArchive: () -> Unit = {},
    onCompact: () -> Unit = {},
    onFork: () -> Unit = {},
    onTogglePin: () -> Unit = {},
    onReview: () -> Unit = {},
    onEditGoal: () -> Unit = {},
    onRemindIn: (Long) -> Unit = {},
    onClearReminder: () -> Unit = {},
) {
    val timestamp = thread.updatedAtEpochSeconds ?: thread.createdAtEpochSeconds
    val statusLabel = sessionRowStatusTitle(status)
    val pinnedLabel = stringResource(R.string.session_pinned_state)
    Card(
        modifier = modifier.fillMaxWidth()
            .testTag("session_row_${thread.id}")
            .semantics {
                this.selected = selected
                stateDescription = if (pinned) "$statusLabel, $pinnedLabel" else statusLabel
            }
            .clickable(onClick = onClick),
        shape = MaterialTheme.shapes.medium,
        colors = CardDefaults.cardColors(
            containerColor = if (selected) {
                MaterialTheme.colorScheme.primaryContainer
            } else {
                MaterialTheme.colorScheme.surfaceContainerLow
            },
        ),
    ) {
        Column(
            Modifier.fillMaxWidth().padding(MimiSpacing.sm),
            verticalArrangement = Arrangement.spacedBy(MimiSpacing.xs),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (pinned) {
                    Text("★", color = MaterialTheme.colorScheme.primary)
                    Spacer(Modifier.width(6.dp))
                }
                Text(
                    thread.preview,
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Column(horizontalAlignment = Alignment.End) {
                    timestamp?.let { epoch ->
                        val formatted = remember(epoch) {
                            DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
                                .format(Date(epoch * 1_000))
                        }
                        Text(
                            formatted,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    SessionActionsMenu(
                        pinned = pinned,
                        reminder = reminder,
                        onRename = onRename,
                        onArchive = onArchive,
                        onCompact = onCompact,
                        onFork = onFork,
                        onTogglePin = onTogglePin,
                        onReview = onReview,
                        onEditGoal = onEditGoal,
                        onRemindIn = onRemindIn,
                        onClearReminder = onClearReminder,
                        buttonTestTag = "session_actions_${thread.id}",
                    )
                }
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(MimiSpacing.xs),
            ) {
                SessionStatusPill(status)
                Text(
                    thread.cwd,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (thread.runtimeProvider == "claude" || reminder != null || goal != null) {
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(MimiSpacing.xs),
                    verticalArrangement = Arrangement.spacedBy(MimiSpacing.xxs),
                ) {
                    if (thread.runtimeProvider == "claude") SessionMetadataPill("Claude")
                    reminder?.let { SessionMetadataPill(stringResource(R.string.session_reminder_badge)) }
                    goal?.let {
                    val progress = goal.tokenBudget?.let { budget ->
                        stringResource(R.string.session_goal_progress_badge, goal.tokensUsed, budget)
                    } ?: goalStatusTitle(goal.status)
                    SessionMetadataPill(stringResource(R.string.session_goal_badge, progress))
                    }
                }
            }
            snippet?.takeIf(String::isNotBlank)?.let {
                Text(
                    it,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
    }
}

@Composable
private fun ThreadRow(
    thread: AgentThread,
    selected: Boolean,
    status: SessionRowStatus,
    subtitle: String?,
    onClick: () -> Unit,
    onRename: () -> Unit,
    onArchive: () -> Unit,
    onCompact: () -> Unit,
    onFork: () -> Unit,
    pinned: Boolean,
    onTogglePin: () -> Unit,
    onReview: () -> Unit,
    onEditGoal: () -> Unit,
    goal: ThreadGoal?,
    reminder: SessionReminder?,
    onRemindIn: (Long) -> Unit,
    onClearReminder: () -> Unit,
) {
    val goalStatusLabel = goal?.let { goalStatusTitle(it.status) }
    val sessionStatusLabel = sessionRowStatusTitle(status)
    val pinnedLabel = stringResource(R.string.session_pinned_state)
    Row(
        Modifier.fillMaxWidth().padding(vertical = 3.dp).clip(RoundedCornerShape(14.dp))
            .background(if (selected) MaterialTheme.colorScheme.primaryContainer else Color.Transparent)
            .semantics {
                this.selected = selected
                stateDescription = buildList {
                    add(sessionStatusLabel)
                    if (pinned) add(pinnedLabel)
                    if (thread.runtimeProvider == "claude") add("Claude")
                    goalStatusLabel?.let(::add)
                }.joinToString(", ")
            }
            .clickable(onClick = onClick).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.ChatBubbleOutline, null, tint = MaterialTheme.colorScheme.secondary)
        if (pinned) {
            Spacer(Modifier.width(4.dp))
            Text("★", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelMedium)
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(thread.preview, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                if (thread.runtimeProvider == "claude") {
                    Text("Claude", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.tertiary)
                }
            }
            Text(
                thread.cwd,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier.padding(top = 5.dp),
            ) {
                SessionStatusPill(status)
                goal?.let {
                    SessionMetadataPill(stringResource(R.string.session_goal_badge, goalStatusLabel.orEmpty()))
                }
                reminder?.let {
                    SessionMetadataPill(stringResource(R.string.session_reminder_badge))
                }
            }
            subtitle?.takeIf(String::isNotBlank)?.let {
                Text(it, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        SessionActionsMenu(
            pinned = pinned,
            reminder = reminder,
            onRename = onRename,
            onArchive = onArchive,
            onCompact = onCompact,
            onFork = onFork,
            onTogglePin = onTogglePin,
            onReview = onReview,
            onEditGoal = onEditGoal,
            onRemindIn = onRemindIn,
            onClearReminder = onClearReminder,
            buttonTestTag = "session_actions_${thread.id}",
        )
    }
}

@Composable
private fun ProjectRow(project: AgentProject, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 3.dp).clip(RoundedCornerShape(14.dp))
            .background(if (selected) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent)
            .clickable(onClick = onClick).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.Folder, null, tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(project.name, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(project.path, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun MainPane(
    state: MainUiState,
    destination: Destination,
    viewModel: MainViewModel,
    modifier: Modifier = Modifier,
    showSessionBack: Boolean = false,
) {
    val project = state.projects.firstOrNull { it.id == state.selectedProjectId }
    val thread = state.threads.firstOrNull { it.id == state.selectedThreadId }
    var sessionFilterName by rememberSaveable { mutableStateOf(SessionLibraryFilter.All.name) }
    val sessionFilter = SessionLibraryFilter.entries.firstOrNull { it.name == sessionFilterName }
        ?: SessionLibraryFilter.All
    val sessionSnippets = state.sessionSearchResults.associate { it.thread.id to it.snippet }
    val filteredSessions = visibleThreads(state).filter { item ->
        SessionLibraryPolicy.includes(sessionFilter, sessionRowStatus(state, item))
    }
    val activeSessions = filteredSessions.filter { item ->
        SessionLibraryPolicy.isActive(sessionRowStatus(state, item))
    }
    val historySessions = filteredSessions.filterNot { item ->
        SessionLibraryPolicy.isActive(sessionRowStatus(state, item))
    }
    val sessionActions = rememberSessionActionDialogState()
    SessionActionDialogs(sessionActions, state, viewModel)
    Column(modifier) {
        PaneHeader(
            thread?.preview ?: project?.name ?: destinationLabel(destination),
            stringResource(if (thread == null) R.string.codex_sessions else R.string.live_codex_workspace),
            onBack = if (thread != null && showSessionBack) viewModel::showSessionList else null,
        )
        if (thread == null) {
            LazyColumn(
                Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(
                    horizontal = MimiSpacing.md,
                    vertical = MimiSpacing.sm,
                ),
                verticalArrangement = Arrangement.spacedBy(MimiSpacing.xs),
            ) {
                item {
                    Button(
                        onClick = viewModel::newSession,
                        enabled = project != null,
                        modifier = Modifier.fillMaxWidth(),
                        shape = CircleShape,
                        contentPadding = PaddingValues(
                            horizontal = MimiSpacing.md,
                            vertical = MimiSpacing.sm,
                        ),
                    ) {
                        Icon(Icons.Filled.Add, null)
                        Spacer(Modifier.width(MimiSpacing.xs))
                        Text(stringResource(R.string.new_runtime_session, if (state.newSessionRuntimeProvider == "claude") "Claude" else "Codex"))
                    }
                }
                item {
                    SessionSearchField(
                        value = state.sessionSearchQuery,
                        onValueChange = viewModel::setSessionSearchQuery,
                        placeholder = { Text(stringResource(R.string.search_sessions_history)) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                item {
                    SessionLibraryFilterBar(
                        selected = sessionFilter,
                        onSelect = { sessionFilterName = it.name },
                    )
                }
                if (activeSessions.isNotEmpty()) {
                    item(key = "session-section-active") {
                        SessionSectionHeader(stringResource(R.string.session_section_in_progress), activeSessions.size)
                    }
                    items(activeSessions, key = { "session-active-${it.id}" }) { item ->
                        SessionLibraryCard(
                            thread = item,
                            status = sessionRowStatus(state, item),
                            selected = state.selectedThreadId == item.id,
                            pinned = item.id in state.pinnedThreadIds,
                            reminder = state.sessionReminders[item.id],
                            goal = state.threadGoals[item.id],
                            snippet = sessionSnippets[item.id],
                            onClick = { viewModel.selectThread(item.id) },
                            onRename = { sessionActions.requestRename(item) },
                            onArchive = { sessionActions.archiveThreadId = item.id },
                            onCompact = { sessionActions.compactThreadId = item.id },
                            onFork = { viewModel.forkThread(item.id) },
                            onTogglePin = { viewModel.togglePinnedThread(item.id) },
                            onReview = { sessionActions.requestReview(item.id) },
                            onEditGoal = { sessionActions.goalThreadId = item.id },
                            onRemindIn = { delay -> viewModel.scheduleSessionReminder(item.id, delay) },
                            onClearReminder = { viewModel.clearSessionReminder(item.id) },
                        )
                    }
                }
                if (historySessions.isNotEmpty()) {
                    item(key = "session-section-history") {
                        SessionSectionHeader(stringResource(R.string.session_section_history), historySessions.size)
                    }
                    items(historySessions, key = { "session-history-${it.id}" }) { item ->
                        SessionLibraryCard(
                            thread = item,
                            status = sessionRowStatus(state, item),
                            selected = state.selectedThreadId == item.id,
                            pinned = item.id in state.pinnedThreadIds,
                            reminder = state.sessionReminders[item.id],
                            goal = state.threadGoals[item.id],
                            snippet = sessionSnippets[item.id],
                            onClick = { viewModel.selectThread(item.id) },
                            onRename = { sessionActions.requestRename(item) },
                            onArchive = { sessionActions.archiveThreadId = item.id },
                            onCompact = { sessionActions.compactThreadId = item.id },
                            onFork = { viewModel.forkThread(item.id) },
                            onTogglePin = { viewModel.togglePinnedThread(item.id) },
                            onReview = { sessionActions.requestReview(item.id) },
                            onEditGoal = { sessionActions.goalThreadId = item.id },
                            onRemindIn = { delay -> viewModel.scheduleSessionReminder(item.id, delay) },
                            onClearReminder = { viewModel.clearSessionReminder(item.id) },
                        )
                    }
                }
                if (state.sessionSearchCursor != null) {
                    item { OutlinedButton(onClick = viewModel::loadMoreSessionSearch, enabled = !state.sessionSearchLoading) { Text(stringResource(R.string.more_search_results)) } }
                }
                if (state.sessionSearchQuery.isBlank() && state.threadCursor != null) {
                    item { OutlinedButton(onClick = viewModel::loadMoreThreads, enabled = !state.loading) { Text(stringResource(R.string.load_more_sessions)) } }
                }
                if (filteredSessions.isEmpty() && !state.sessionSearchLoading) {
                    item {
                        Column(
                            Modifier.fillMaxWidth().padding(vertical = 28.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(
                                stringResource(R.string.no_matching_sessions),
                                style = MaterialTheme.typography.titleSmall,
                            )
                            Text(
                                stringResource(R.string.no_matching_sessions_detail),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            if (sessionFilter != SessionLibraryFilter.All) {
                                TextButton(
                                    onClick = { sessionFilterName = SessionLibraryFilter.All.name },
                                    modifier = Modifier.testTag("session_filter_clear"),
                                ) { Text(stringResource(R.string.clear_session_filter)) }
                            }
                        }
                    }
                }
                if (state.sessionSearchLoading) item { CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp) }
                state.recentlyArchivedThread?.let { archived ->
                    item { OutlinedButton(onClick = viewModel::restoreRecentlyArchived) { Text(stringResource(R.string.restore_session, archived.preview)) } }
                }
            }
        } else {
            LazyColumn(
                Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(
                    horizontal = MimiSpacing.md,
                    vertical = MimiSpacing.sm,
                ),
                verticalArrangement = Arrangement.spacedBy(MimiSpacing.sm),
            ) {
                if (state.historyCursor != null) {
                    item {
                        OutlinedButton(onClick = viewModel::loadOlderMessages, enabled = !state.loading) {
                            Text(stringResource(R.string.load_earlier_messages))
                        }
                    }
                }
                if (state.messages.isEmpty()) {
                    item {
                        MessageBubble(
                            ConversationMessage("empty", ConversationRole.Assistant, "Session connected. Send a message to Codex."),
                            viewModel,
                            state.filePreviewLoading,
                        )
                    }
                }
                val timelineEntries = conversationTimelineEntries(state.messages)
                items(timelineEntries, key = { it.key }) { entry ->
                    when (entry) {
                        is ConversationTimelineEntry.Message -> MessageBubble(entry.message, viewModel, state.filePreviewLoading)
                        is ConversationTimelineEntry.ActivityGroup -> ActivityTimelineCard(entry.messages)
                    }
                }
            }
            val threadId = state.selectedThreadId
            threadId?.let { selectedId ->
                state.pendingApprovals[selectedId]?.let { request ->
                    ApprovalCard(
                        request = request,
                        submitting = state.respondingToRequest,
                        onDecision = viewModel::decideApproval,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    )
                }
                state.pendingUserInputs[selectedId]?.let { request ->
                    UserInputCard(
                        request = request,
                        submitting = state.respondingToRequest,
                        onSubmit = viewModel::submitUserInput,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    )
                }
            }
            QueuedTurnTray(state, viewModel)
            Composer(
                state = state,
                viewModel = viewModel,
                enabled = true,
                active = TurnLifecycleProjection.isBusy(state.activeTurnId, state.awaitingTurnIdentity),
                onSend = viewModel::sendMessage,
                onInterrupt = viewModel::interruptTurn,
            )
        }
    }
}

@Composable
private fun MessageBubble(
    message: ConversationMessage,
    viewModel: MainViewModel,
    filePreviewLoading: Boolean,
) {
    val assistant = message.role != ConversationRole.User
    var previewImageUrl by remember(message.id) { mutableStateOf<String?>(null) }
    val fileReferences = remember(message.text, message.attachments) {
        val attachedPaths = message.attachments.mapNotNullTo(mutableSetOf()) { it.path }
        if (message.role == ConversationRole.Assistant) {
            ConversationFileReferenceDetector.references(message.text).filterNot { it.path in attachedPaths }
        } else {
            emptyList()
        }
    }
    previewImageUrl?.let { imageUrl ->
        AlertDialog(
            onDismissRequest = { previewImageUrl = null },
            title = { Text(stringResource(R.string.image_title)) },
            text = { AsyncImage(model = imageUrl, contentDescription = stringResource(R.string.message_image), modifier = Modifier.fillMaxWidth().heightIn(max = 520.dp)) },
            confirmButton = { TextButton(onClick = { previewImageUrl = null }) { Text(stringResource(R.string.close_action)) } },
        )
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (assistant) Arrangement.Start else Arrangement.End) {
        Surface(
            color = when (message.role) {
                ConversationRole.User -> MaterialTheme.colorScheme.primaryContainer
                ConversationRole.Commentary -> MaterialTheme.colorScheme.secondaryContainer
                else -> Color.Transparent
            },
            contentColor = when (message.role) {
                ConversationRole.User -> MaterialTheme.colorScheme.onPrimaryContainer
                ConversationRole.Commentary -> MaterialTheme.colorScheme.onSecondaryContainer
                else -> MaterialTheme.colorScheme.onSurface
            },
            shape = if (assistant) MaterialTheme.shapes.small else MaterialTheme.shapes.large,
            modifier = if (assistant) Modifier.fillMaxWidth() else Modifier.fillMaxWidth(0.84f),
        ) {
            Column(
                Modifier.padding(
                    horizontal = if (message.role == ConversationRole.Assistant) MimiSpacing.xxs else MimiSpacing.md,
                    vertical = if (message.role == ConversationRole.Assistant) MimiSpacing.xs else MimiSpacing.sm,
                ),
                verticalArrangement = Arrangement.spacedBy(MimiSpacing.xs),
            ) {
                if (message.role == ConversationRole.Commentary) {
                    Text(
                        stringResource(R.string.commentary_update),
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSecondaryContainer,
                    )
                }
                if (message.text.isNotBlank()) {
                    if (assistant) {
                        MarkdownMessageContent(
                            message.text,
                            onHistoryMedia = viewModel::previewHistoryMedia,
                            onLocalFile = viewModel::previewFile,
                        )
                    }
                    else Text(message.text, style = MaterialTheme.typography.bodyLarge)
                }
                message.attachments.forEach { attachment ->
                    when (attachment.kind) {
                        ConversationAttachmentKind.Image -> attachment.url?.let { imageUrl ->
                            val historyPrefix = "agentd-history-media://"
                            when {
                                imageUrl.startsWith(historyPrefix) -> OutlinedButton(onClick = { viewModel.previewHistoryMedia(imageUrl.removePrefix(historyPrefix)) }) {
                                    Icon(Icons.Filled.AttachFile, contentDescription = null)
                                    Spacer(Modifier.width(8.dp))
                                    Text(attachment.name ?: stringResource(R.string.history_media_load))
                                }
                                isSafeMessageImageUrl(imageUrl) -> AsyncImage(
                                    model = imageUrl,
                                    contentDescription = attachment.name ?: stringResource(R.string.message_image),
                                    modifier = Modifier.fillMaxWidth().heightIn(max = 320.dp).clip(RoundedCornerShape(12.dp)).clickable { previewImageUrl = imageUrl },
                                )
                                else -> Text(stringResource(R.string.image_source_blocked), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                            }
                        }
                        ConversationAttachmentKind.LocalImage,
                        ConversationAttachmentKind.Mention -> attachment.path?.let { path ->
                            OutlinedButton(onClick = { viewModel.previewFile(path) }) {
                                Icon(Icons.Filled.AttachFile, contentDescription = null)
                                Spacer(Modifier.width(8.dp))
                                Text(attachment.name ?: path.substringAfterLast('/').substringAfterLast('\\'), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                        ConversationAttachmentKind.Skill -> Surface(
                            color = MaterialTheme.colorScheme.secondaryContainer,
                            shape = RoundedCornerShape(10.dp),
                        ) { Text(stringResource(R.string.skill_value, attachment.name.orEmpty()), Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) }
                    }
                }
                if (fileReferences.isNotEmpty()) {
                    FileReferencePreviewStrip(
                        references = fileReferences,
                        loading = filePreviewLoading,
                        onPreview = viewModel::previewFile,
                    )
                }
            }
        }
    }
}

@Composable
internal fun FileReferencePreviewStrip(
    references: List<ConversationFileReference>,
    loading: Boolean,
    onPreview: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            stringResource(R.string.file_references),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        references.forEach { reference ->
            OutlinedButton(
                onClick = { onPreview(reference.path) },
                enabled = !loading,
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("file_reference_${reference.path}"),
            ) {
                Icon(Icons.Filled.AttachFile, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(reference.name, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(stringResource(R.string.preview_action), style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

private fun isSafeMessageImageUrl(value: String): Boolean =
    value.startsWith("https://", true) || value.startsWith("http://", true) || value.startsWith("data:image/", true)

@Composable
internal fun ComposerModeControl(
    mode: ComposerSendMode,
    onSelect: (ComposerSendMode) -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        FilterChip(
            selected = mode != ComposerSendMode.Standard,
            onClick = { expanded = true },
            label = {
                Text(
                    stringResource(
                        when (mode) {
                            ComposerSendMode.Standard -> R.string.standard_mode
                            ComposerSendMode.Goal -> R.string.goal_mode
                            ComposerSendMode.Plan -> R.string.plan_mode
                        },
                    ),
                )
            },
            leadingIcon = {
                Icon(
                    if (mode == ComposerSendMode.Goal) {
                        Icons.Filled.CheckCircle
                    } else {
                        Icons.AutoMirrored.Filled.PlaylistPlay
                    },
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
            },
            modifier = Modifier.testTag("composer_mode_chip"),
        )
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.standard_mode)) },
                onClick = {
                    onSelect(ComposerSendMode.Standard)
                    expanded = false
                },
                modifier = Modifier.testTag("composer_mode_standard"),
            )
            DropdownMenuItem(
                text = {
                    Column {
                        Text(stringResource(R.string.goal_mode))
                        Text(
                            stringResource(R.string.goal_mode_detail),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                onClick = {
                    onSelect(ComposerSendMode.Goal)
                    expanded = false
                },
                modifier = Modifier.testTag("composer_mode_goal"),
            )
            DropdownMenuItem(
                text = {
                    Column {
                        Text(stringResource(R.string.plan_mode))
                        Text(
                            stringResource(R.string.plan_mode_detail),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                onClick = {
                    onSelect(ComposerSendMode.Plan)
                    expanded = false
                },
                modifier = Modifier.testTag("composer_mode_plan"),
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CapabilityPicker(
    skills: List<SkillCapability>,
    plugins: List<PluginCapability>,
    selectedSkillPaths: Set<String>,
    loading: Boolean,
    onToggleSkill: (String) -> Unit,
    onAddManualSkill: (String, String) -> Unit,
    onInsertPlugin: (String) -> Unit,
    onInsertShortcut: (String) -> Unit,
    onPickImages: () -> Unit,
    onRefresh: () -> Unit,
    onDismiss: () -> Unit,
) {
    val density = LocalDensity.current
    val windowInfo = LocalWindowInfo.current
    val compact = with(density) { windowInfo.containerSize.width.toDp() } < 600.dp
    if (compact) {
        ModalBottomSheet(
            onDismissRequest = onDismiss,
            modifier = Modifier.testTag("capability_picker_sheet"),
        ) {
            CapabilityPickerContent(
                skills = skills,
                plugins = plugins,
                selectedSkillPaths = selectedSkillPaths,
                loading = loading,
                onToggleSkill = onToggleSkill,
                onAddManualSkill = onAddManualSkill,
                onInsertPlugin = onInsertPlugin,
                onInsertShortcut = onInsertShortcut,
                onPickImages = onPickImages,
                onRefresh = onRefresh,
                onDismiss = onDismiss,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 440.dp, max = 680.dp)
                    .padding(bottom = 16.dp),
            )
        }
    } else {
        Dialog(
            onDismissRequest = onDismiss,
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(
                shape = MaterialTheme.shapes.extraLarge,
                tonalElevation = 6.dp,
                modifier = Modifier
                    .fillMaxWidth()
                    .widthIn(max = 560.dp)
                    .heightIn(min = 480.dp, max = 720.dp)
                    .testTag("capability_picker_dialog"),
            ) {
                CapabilityPickerContent(
                    skills = skills,
                    plugins = plugins,
                    selectedSkillPaths = selectedSkillPaths,
                    loading = loading,
                    onToggleSkill = onToggleSkill,
                    onAddManualSkill = onAddManualSkill,
                    onInsertPlugin = onInsertPlugin,
                    onInsertShortcut = onInsertShortcut,
                    onPickImages = onPickImages,
                    onRefresh = onRefresh,
                    onDismiss = onDismiss,
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CapabilityPickerContent(
    skills: List<SkillCapability>,
    plugins: List<PluginCapability>,
    selectedSkillPaths: Set<String>,
    loading: Boolean,
    onToggleSkill: (String) -> Unit,
    onAddManualSkill: (String, String) -> Unit,
    onInsertPlugin: (String) -> Unit,
    onInsertShortcut: (String) -> Unit,
    onPickImages: () -> Unit,
    onRefresh: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var pageName by rememberSaveable { mutableStateOf(CapabilityPickerPage.Root.name) }
    var query by rememberSaveable { mutableStateOf("") }
    var manualSkillOpen by rememberSaveable { mutableStateOf(false) }
    var manualSkillName by rememberSaveable { mutableStateOf("") }
    var manualSkillPath by rememberSaveable { mutableStateOf("") }
    val page = CapabilityPickerPage.valueOf(pageName)
    val filteredSkills = CapabilityPickerPolicy.filterSkills(skills, query)
    val filteredPlugins = CapabilityPickerPolicy.filterPlugins(plugins, query)
    val shortcuts = listOf(
        stringResource(R.string.shortcut_check_implementation),
        stringResource(R.string.shortcut_implement_and_test),
        stringResource(R.string.shortcut_minimum_runnable),
        stringResource(R.string.shortcut_explain_failure),
    )
    val goBack = {
        query = ""
        pageName = CapabilityPickerPage.Root.name
    }
    BackHandler(enabled = page != CapabilityPickerPage.Root, onBack = goBack)

    if (manualSkillOpen) {
        AlertDialog(
            onDismissRequest = { manualSkillOpen = false },
            title = { Text(stringResource(R.string.add_skill_manually)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = manualSkillName,
                        onValueChange = { manualSkillName = it },
                        label = { Text(stringResource(R.string.skill_name)) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("manual_skill_name"),
                    )
                    OutlinedTextField(
                        value = manualSkillPath,
                        onValueChange = { manualSkillPath = it },
                        label = { Text(stringResource(R.string.skill_path_allowlist)) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("manual_skill_path"),
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onAddManualSkill(manualSkillName, manualSkillPath)
                        manualSkillOpen = false
                        manualSkillName = ""
                        manualSkillPath = ""
                    },
                    enabled = manualSkillName.isNotBlank() && manualSkillPath.isNotBlank(),
                    modifier = Modifier.testTag("confirm_manual_skill"),
                ) {
                    Text(stringResource(R.string.add_action))
                }
            },
            dismissButton = {
                TextButton(onClick = { manualSkillOpen = false }) {
                    Text(stringResource(R.string.cancel_action))
                }
            },
        )
    }

    Column(
        modifier.padding(horizontal = 20.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (page != CapabilityPickerPage.Root) {
                IconButton(
                    onClick = goBack,
                    modifier = Modifier.size(48.dp).testTag("content_picker_back"),
                ) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back_to_add_content))
                }
            }
            Column(Modifier.weight(1f)) {
                Text(
                    stringResource(
                        when (page) {
                            CapabilityPickerPage.Root -> R.string.add_content
                            CapabilityPickerPage.Skills -> R.string.capabilities
                            CapabilityPickerPage.Plugins -> R.string.plugins_tab
                            CapabilityPickerPage.Shortcuts -> R.string.shortcut_phrases
                        },
                    ),
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.semantics { heading() },
                )
                Text(
                    stringResource(
                        when (page) {
                            CapabilityPickerPage.Root -> R.string.add_content_description
                            CapabilityPickerPage.Skills -> R.string.skill_picker_description
                            CapabilityPickerPage.Plugins -> R.string.plugin_picker_description
                            CapabilityPickerPage.Shortcuts -> R.string.shortcut_picker_description
                        },
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (page != CapabilityPickerPage.Shortcuts) {
                IconButton(
                    onClick = onRefresh,
                    enabled = !loading,
                    modifier = Modifier.size(48.dp).testTag("refresh_capabilities"),
                ) {
                    if (loading) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(Icons.Filled.Refresh, stringResource(R.string.refresh_capabilities))
                    }
                }
            }
            IconButton(
                onClick = onDismiss,
                modifier = Modifier.size(48.dp).testTag("close_capability_picker"),
            ) {
                Icon(Icons.Filled.Close, stringResource(R.string.close_action))
            }
        }
        if (page == CapabilityPickerPage.Skills || page == CapabilityPickerPage.Plugins) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier.fillMaxWidth().testTag("capability_search"),
                placeholder = {
                    Text(
                        stringResource(
                            if (page == CapabilityPickerPage.Skills) R.string.search_skills
                            else R.string.search_plugins,
                        ),
                    )
                },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                trailingIcon = if (query.isNotEmpty()) {
                    {
                        IconButton(onClick = { query = "" }) {
                            Icon(Icons.Filled.Close, stringResource(R.string.clear_action))
                        }
                    }
                } else {
                    null
                },
                singleLine = true,
            )
        }
        LazyColumn(
            modifier = Modifier.fillMaxWidth().weight(1f),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(vertical = 2.dp),
        ) {
            when (page) {
                CapabilityPickerPage.Root -> {
                    item("content-images") {
                        AddContentActionRow(
                            icon = Icons.Filled.AttachFile,
                            title = stringResource(R.string.pictures),
                            subtitle = stringResource(R.string.pictures_picker_description),
                            testTag = "content_picker_images",
                            onClick = onPickImages,
                        )
                    }
                    item("content-plugins") {
                        AddContentActionRow(
                            icon = Icons.Filled.Add,
                            title = stringResource(R.string.plugins_tab),
                            subtitle = stringResource(R.string.plugin_picker_description),
                            testTag = "content_picker_plugins",
                            onClick = { pageName = CapabilityPickerPage.Plugins.name },
                        )
                    }
                    item("content-skills") {
                        AddContentActionRow(
                            icon = Icons.Filled.Code,
                            title = stringResource(R.string.skills_tab),
                            subtitle = stringResource(R.string.skill_picker_description),
                            testTag = "content_picker_skills",
                            onClick = { pageName = CapabilityPickerPage.Skills.name },
                        )
                    }
                    item("content-shortcuts") {
                        AddContentActionRow(
                            icon = Icons.Filled.Edit,
                            title = stringResource(R.string.shortcut_phrases),
                            subtitle = stringResource(R.string.shortcut_action_description),
                            testTag = "content_picker_shortcuts",
                            onClick = { pageName = CapabilityPickerPage.Shortcuts.name },
                        )
                    }
                }
                CapabilityPickerPage.Skills -> {
                    item("manual-skill") {
                        OutlinedButton(
                            onClick = { manualSkillOpen = true },
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 48.dp)
                                .testTag("add_manual_skill"),
                        ) {
                            Icon(Icons.Filled.Add, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(stringResource(R.string.add_skill_manually))
                        }
                    }
                    if (filteredSkills.isEmpty()) {
                        item("empty-skills") {
                            CapabilityEmptyState(
                                text = stringResource(R.string.no_skills),
                                onRefresh = onRefresh,
                                loading = loading,
                            )
                        }
                    } else {
                        items(filteredSkills, key = { "skill-${it.path}" }) { skill ->
                            SkillCapabilityRow(
                                skill = skill,
                                selected = skill.path in selectedSkillPaths,
                                onToggle = { onToggleSkill(skill.path) },
                            )
                        }
                    }
                }
                CapabilityPickerPage.Plugins -> {
                    if (filteredPlugins.isEmpty()) {
                        item("empty-plugins") {
                            CapabilityEmptyState(
                                text = stringResource(R.string.no_plugins),
                                onRefresh = onRefresh,
                                loading = loading,
                            )
                        }
                    } else {
                        items(filteredPlugins, key = { "plugin-${it.id}" }) { plugin ->
                            PluginCapabilityRow(
                                plugin = plugin,
                                onInsert = { onInsertPlugin(plugin.name) },
                            )
                        }
                    }
                }
                CapabilityPickerPage.Shortcuts -> {
                    items(shortcuts, key = { it }) { shortcut ->
                        Surface(
                            color = MaterialTheme.colorScheme.surfaceContainerLow,
                            shape = MaterialTheme.shapes.large,
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 64.dp)
                                .clip(MaterialTheme.shapes.large)
                                .clickable { onInsertShortcut(shortcut) }
                                .testTag("content_shortcut_${shortcuts.indexOf(shortcut)}"),
                        ) {
                            Row(
                                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(Icons.Filled.Edit, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                                Text(
                                    shortcut,
                                    modifier = Modifier.weight(1f).padding(horizontal = 12.dp),
                                    style = MaterialTheme.typography.bodyMedium,
                                )
                                Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.insert_shortcut))
                            }
                        }
                    }
                }
            }
        }
        if (selectedSkillPaths.isNotEmpty()) {
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainer,
                shape = MaterialTheme.shapes.large,
            ) {
                Text(
                    pluralStringResource(
                        R.plurals.selected_skills_summary,
                        selectedSkillPaths.size,
                        selectedSkillPaths.size,
                    ),
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun AddContentActionRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    testTag: String,
    onClick: () -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shape = MaterialTheme.shapes.large,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 68.dp)
            .clip(MaterialTheme.shapes.large)
            .clickable(onClick = onClick)
            .testTag(testTag),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Surface(
                color = MaterialTheme.colorScheme.secondaryContainer,
                contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
                shape = MaterialTheme.shapes.medium,
                modifier = Modifier.size(40.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(icon, contentDescription = null)
                }
            }
            Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = null)
        }
    }
}

@Composable
private fun SkillCapabilityRow(
    skill: SkillCapability,
    selected: Boolean,
    onToggle: () -> Unit,
) {
    Surface(
        color = if (selected) MaterialTheme.colorScheme.secondaryContainer
        else MaterialTheme.colorScheme.surfaceContainerLow,
        shape = MaterialTheme.shapes.large,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 76.dp)
            .clip(MaterialTheme.shapes.large)
            .clickable(enabled = skill.enabled, onClick = onToggle)
            .testTag("capability_skill_${skill.path}"),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Filled.Code,
                contentDescription = null,
                tint = if (selected) MaterialTheme.colorScheme.onSecondaryContainer
                else MaterialTheme.colorScheme.primary,
            )
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    "\$${skill.presentationName}",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                skill.description?.takeIf(String::isNotBlank)?.let { description ->
                    Text(
                        description,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Surface(
                color = MaterialTheme.colorScheme.tertiaryContainer,
                contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
                shape = MaterialTheme.shapes.small,
            ) {
                Text(
                    skill.scope,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                    style = MaterialTheme.typography.labelSmall,
                )
            }
            Spacer(Modifier.width(8.dp))
            Switch(
                checked = selected,
                onCheckedChange = { onToggle() },
                enabled = skill.enabled,
                modifier = Modifier.testTag("capability_skill_toggle_${skill.path}"),
            )
        }
    }
}

@Composable
private fun PluginCapabilityRow(
    plugin: PluginCapability,
    onInsert: () -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shape = MaterialTheme.shapes.large,
        modifier = Modifier.fillMaxWidth().heightIn(min = 76.dp),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Surface(
                color = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                shape = CircleShape,
                modifier = Modifier.size(40.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text("@", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                }
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    "@${plugin.name}",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val detail = listOfNotNull(
                    plugin.marketplace.takeIf(String::isNotBlank),
                    plugin.description?.takeIf(String::isNotBlank),
                ).joinToString(" · ")
                if (detail.isNotEmpty()) {
                    Text(
                        detail,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            TextButton(
                onClick = onInsert,
                enabled = plugin.enabled && plugin.installed,
                modifier = Modifier.heightIn(min = 48.dp).testTag("capability_plugin_${plugin.id}"),
            ) {
                Icon(Icons.Filled.Add, contentDescription = null)
                Spacer(Modifier.width(4.dp))
                Text(
                    if (plugin.enabled && plugin.installed) stringResource(R.string.insert_plugin)
                    else stringResource(R.string.plugin_disabled),
                )
            }
        }
    }
}

@Composable
private fun CapabilityEmptyState(
    text: String,
    onRefresh: () -> Unit,
    loading: Boolean,
) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onClick = onRefresh, enabled = !loading) {
            Icon(Icons.Filled.Refresh, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.refresh_capabilities))
        }
    }
}

@Composable
private fun Composer(
    state: MainUiState,
    viewModel: MainViewModel,
    enabled: Boolean,
    active: Boolean,
    onSend: (String) -> Unit,
    onInterrupt: () -> Unit,
) {
    var modelMenu by remember { mutableStateOf(false) }
    var effortMenu by remember { mutableStateOf(false) }
    var capabilityPickerOpen by rememberSaveable { mutableStateOf(false) }
    var permissionMenu by remember { mutableStateOf(false) }
    var permissionRecoveryMessage by rememberSaveable { mutableStateOf<String?>(null) }
    var previewImageUrl by remember { mutableStateOf<String?>(null) }
    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(8)) { uris ->
        viewModel.addImageAttachments(uris)
    }
    val context = LocalContext.current
    val microphonePermissionRequired = stringResource(R.string.microphone_permission_required)
    val microphonePermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) viewModel.startVoiceInput() else permissionRecoveryMessage = microphonePermissionRequired
    }
    val startVoice = {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            viewModel.startVoiceInput()
        } else {
            microphonePermission.launch(Manifest.permission.RECORD_AUDIO)
        }
    }
    permissionRecoveryMessage?.let { message ->
        PermissionRecoveryDialog(
            message = message,
            onDismiss = { permissionRecoveryMessage = null },
            onOpenSettings = {
                permissionRecoveryMessage = null
                context.startActivity(appPermissionSettingsIntent(context.packageName))
            },
        )
    }
    previewImageUrl?.let { imageUrl ->
        AlertDialog(
            onDismissRequest = { previewImageUrl = null },
            title = { Text(stringResource(R.string.image_attachment)) },
            text = { AsyncImage(model = imageUrl, contentDescription = stringResource(R.string.selected_image_preview), modifier = Modifier.fillMaxWidth()) },
            confirmButton = { TextButton(onClick = { previewImageUrl = null }) { Text(stringResource(R.string.close_action)) } },
        )
    }
    if (capabilityPickerOpen) {
        CapabilityPicker(
            skills = state.skills,
            plugins = state.plugins,
            selectedSkillPaths = state.selectedSkillPaths,
            loading = state.capabilitiesLoading,
            onToggleSkill = viewModel::toggleSkill,
            onAddManualSkill = viewModel::addManualSkill,
            onInsertPlugin = {
                viewModel.insertPluginMention(it)
                capabilityPickerOpen = false
            },
            onInsertShortcut = {
                viewModel.insertShortcut(it)
                capabilityPickerOpen = false
            },
            onPickImages = {
                capabilityPickerOpen = false
                if (!state.attachmentLoading && state.composerImages.size < 8) {
                    photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }
            },
            onRefresh = viewModel::refreshComposerCapabilities,
            onDismiss = { capabilityPickerOpen = false },
        )
    }
    val selectedModel = state.modelOptions.firstOrNull { it.id == state.selectedModelId }
    val efforts = selectedModel?.supportedReasoningEfforts.orEmpty().ifEmpty { listOf("minimal", "low", "medium", "high", "xhigh") }
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        tonalElevation = 0.dp,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = MimiSpacing.sm, vertical = MimiSpacing.xs)) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(MimiSpacing.xxs),
            ) {
                FilledTonalIconButton(
                    onClick = { capabilityPickerOpen = true },
                    enabled = !active,
                    modifier = Modifier.size(48.dp).testTag("open_capability_picker"),
                ) {
                    Icon(Icons.Filled.Add, stringResource(R.string.add_content))
                }
                ComposerModeControl(
                    mode = state.composerSendMode,
                    onSelect = viewModel::setComposerSendMode,
                )
                Box {
                    FilterChip(
                        selected = false,
                        onClick = { modelMenu = true },
                        enabled = state.modelOptions.isNotEmpty() && !active,
                        label = {
                            Text(
                                selectedModel?.title ?: stringResource(R.string.default_model),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                    )
                    DropdownMenu(expanded = modelMenu, onDismissRequest = { modelMenu = false }) {
                        DropdownMenuItem(text = { Text(stringResource(R.string.default_model)) }, onClick = { viewModel.selectModel(null); modelMenu = false })
                        state.modelOptions.forEach { option ->
                            DropdownMenuItem(
                                text = { Column { Text(option.title); option.description?.let { Text(it, style = MaterialTheme.typography.bodySmall) } } },
                                onClick = { viewModel.selectModel(option.id); modelMenu = false },
                            )
                        }
                    }
                }
                Box {
                    FilterChip(
                        selected = false,
                        onClick = { effortMenu = true },
                        enabled = !active,
                        label = { Text(state.selectedReasoningEffort ?: stringResource(R.string.default_effort)) },
                    )
                    DropdownMenu(expanded = effortMenu, onDismissRequest = { effortMenu = false }) {
                        DropdownMenuItem(text = { Text(stringResource(R.string.default_effort)) }, onClick = { viewModel.selectReasoningEffort(null); effortMenu = false })
                        efforts.forEach { effort -> DropdownMenuItem(
                            text = { Text(effort.replaceFirstChar(Char::uppercase)) },
                            onClick = { viewModel.selectReasoningEffort(effort); effortMenu = false },
                        ) }
                    }
                }
                Box {
                    FilterChip(
                        selected = false,
                        onClick = { permissionMenu = true },
                        enabled = !active,
                        label = { Text(permissionModeTitle(state.permissionMode)) },
                    )
                    DropdownMenu(expanded = permissionMenu, onDismissRequest = { permissionMenu = false }) {
                        PermissionMode.entries.forEach { mode ->
                            DropdownMenuItem(
                                text = {
                                    Column {
                                        Text(permissionModeTitle(mode))
                                        Text(permissionModeDetail(mode), style = MaterialTheme.typography.bodySmall)
                                    }
                                },
                                onClick = { viewModel.setPermissionMode(mode); permissionMenu = false },
                            )
                        }
                    }
                }
                if (state.voiceRecording) {
                    FilledIconButton(onClick = viewModel::stopVoiceAndTranscribe) {
                        Icon(Icons.Filled.StopCircle, stringResource(R.string.stop_and_transcribe), tint = MaterialTheme.colorScheme.error)
                    }
                } else {
                    IconButton(onClick = startVoice, enabled = !state.voiceTranscribing) { Icon(Icons.Filled.Mic, stringResource(R.string.voice_input)) }
                }
                if (state.capabilitiesLoading) CircularProgressIndicator(Modifier.size(20.dp).align(Alignment.CenterVertically), strokeWidth = 2.dp)
                if (state.voiceTranscribing) CircularProgressIndicator(Modifier.size(20.dp).align(Alignment.CenterVertically), strokeWidth = 2.dp)
            }
            if (state.composerSendMode == ComposerSendMode.Plan) {
                Text(
                    stringResource(R.string.plan_mode_detail),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(start = 4.dp, bottom = 4.dp)
                        .testTag("composer_plan_mode_detail"),
                )
            } else if (state.composerSendMode == ComposerSendMode.Goal) {
                Text(
                    stringResource(R.string.goal_mode_detail),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(start = 4.dp, bottom = 4.dp)
                        .testTag("composer_goal_mode_detail"),
                )
            }
            val selectedSkills = state.skills.filter { it.path in state.selectedSkillPaths }
            if (selectedSkills.isNotEmpty()) {
                LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    contentPadding = PaddingValues(vertical = 4.dp),
                    modifier = Modifier.testTag("selected_skill_attachments"),
                ) {
                    items(selectedSkills, key = { "selected-${it.path}" }) { skill ->
                        FilterChip(
                            selected = true,
                            onClick = { viewModel.toggleSkill(skill.path) },
                            enabled = !active,
                            label = {
                                Text(
                                    "\$${skill.presentationName} ×",
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            },
                            leadingIcon = { Icon(Icons.Filled.Code, contentDescription = null) },
                            modifier = Modifier.testTag("selected_skill_${skill.path}"),
                        )
                    }
                }
            }
            if (state.composerImages.isNotEmpty()) {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(vertical = 4.dp)) {
                    items(state.composerImages, key = { it.id }) { attachment ->
                        Card {
                            Row(Modifier.padding(6.dp), verticalAlignment = Alignment.CenterVertically) {
                                AsyncImage(
                                    model = attachment.dataUrl,
                                    contentDescription = stringResource(R.string.selected_image),
                                    modifier = Modifier.size(48.dp).clip(RoundedCornerShape(8.dp)).clickable { previewImageUrl = attachment.dataUrl },
                                )
                                Column(Modifier.padding(start = 8.dp)) {
                                    Text("${attachment.pixelWidth}×${attachment.pixelHeight}", style = MaterialTheme.typography.bodySmall)
                                    TextButton(onClick = { viewModel.removeImageAttachment(attachment.id) }) { Text(stringResource(R.string.remove_action)) }
                                }
                            }
                        }
                    }
                }
            }
            if (state.attachmentLoading) Text(stringResource(R.string.preparing_image), style = MaterialTheme.typography.bodySmall)
            if (active) {
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        stringResource(
                            if (state.awaitingTurnIdentity) R.string.identifying_active_turn
                            else R.string.while_running,
                        ),
                        style = MaterialTheme.typography.labelLarge,
                    )
                    FilterChip(
                        selected = !state.guideActiveTurn || !state.composerSendMode.allowsGuidedFollowUp,
                        onClick = { viewModel.setGuideActiveTurn(false) },
                        label = { Text(stringResource(R.string.queue_next_turn)) },
                    )
                    FilterChip(
                        selected = state.guideActiveTurn,
                        onClick = { viewModel.setGuideActiveTurn(true) },
                        enabled = state.activeTurnId != null && state.composerSendMode.allowsGuidedFollowUp,
                        label = { Text(stringResource(R.string.guide_current_reply)) },
                    )
                }
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                OutlinedTextField(
                    value = state.composerText,
                    onValueChange = viewModel::setComposerText,
                    placeholder = {
                        Text(
                            stringResource(
                                when (state.composerSendMode) {
                                    ComposerSendMode.Standard -> R.string.ask_codex
                                    ComposerSendMode.Goal -> R.string.goal_prompt
                                    ComposerSendMode.Plan -> R.string.plan_prompt
                                },
                            ),
                        )
                    },
                    modifier = Modifier.weight(1f),
                    maxLines = 5,
                    shape = MaterialTheme.shapes.large,
                )
                Spacer(Modifier.width(MimiSpacing.xs))
                if (active) {
                    IconButton(onClick = onInterrupt, enabled = state.activeTurnId != null) {
                        Icon(Icons.Filled.StopCircle, stringResource(R.string.stop_action), tint = MaterialTheme.colorScheme.error)
                    }
                }
                FilledIconButton(
                    onClick = { onSend(state.composerText) },
                    enabled = enabled && when (state.composerSendMode) {
                        ComposerSendMode.Goal -> state.composerText.isNotBlank()
                        else -> state.composerText.isNotBlank() || state.composerImages.isNotEmpty()
                    },
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.Send,
                        when {
                            state.composerSendMode == ComposerSendMode.Goal -> stringResource(R.string.start_goal)
                            state.composerSendMode == ComposerSendMode.Plan -> stringResource(R.string.generate_plan)
                            !active -> stringResource(R.string.send_action)
                            state.guideActiveTurn -> stringResource(R.string.guide_current_reply)
                            else -> stringResource(R.string.queue_message)
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun QueuedTurnTray(state: MainUiState, viewModel: MainViewModel) {
    if (state.queuedTurns.isEmpty() && !state.queueLoading) return
    var managerOpen by rememberSaveable { mutableStateOf(false) }
    var editId by remember { mutableStateOf<String?>(null) }
    var editText by remember { mutableStateOf("") }
    var editImages by remember { mutableStateOf<List<ImageAttachment>>(emptyList()) }
    var editSkills by remember { mutableStateOf<List<QueuedSkill>>(emptyList()) }
    var deleteId by remember { mutableStateOf<String?>(null) }

    fun beginEdit(queued: QueuedTurn) {
        editId = queued.id
        editText = queued.text
        editImages = queued.images
        editSkills = queued.skills
    }

    if (managerOpen) {
        QueuedTurnManager(
            state = state,
            onDismiss = { managerOpen = false },
            onEdit = ::beginEdit,
            onDelete = { deleteId = it.id },
            onRetry = viewModel::retryQueuedTurn,
            onGuideNow = viewModel::guideQueuedTurnNow,
            onMove = viewModel::moveQueuedTurn,
        )
    }
    editId?.let { id ->
        AlertDialog(
            onDismissRequest = { editId = null },
            title = { Text(stringResource(R.string.edit_queued_message)) },
            text = {
                Column(
                    Modifier.fillMaxWidth().heightIn(max = 520.dp).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    OutlinedTextField(
                        editText,
                        { editText = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text(stringResource(R.string.queued_message_text)) },
                        minLines = 3,
                        maxLines = 8,
                    )
                    if (editImages.isNotEmpty()) {
                        Text(stringResource(R.string.queued_images), style = MaterialTheme.typography.labelLarge)
                        editImages.forEach { image ->
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                AsyncImage(
                                    model = image.dataUrl,
                                    contentDescription = stringResource(R.string.queued_image_preview),
                                    modifier = Modifier.size(48.dp).clip(RoundedCornerShape(8.dp)),
                                )
                                Text(
                                    stringResource(R.string.queued_image_attachment),
                                    modifier = Modifier.weight(1f).padding(horizontal = 12.dp),
                                )
                                TextButton(onClick = { editImages = editImages.filterNot { it.id == image.id } }) {
                                    Text(stringResource(R.string.remove_action))
                                }
                            }
                        }
                    }
                    if (editSkills.isNotEmpty()) {
                        Text(stringResource(R.string.queued_skills), style = MaterialTheme.typography.labelLarge)
                        editSkills.forEach { skill ->
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Filled.Code, null)
                                Text(skill.name, modifier = Modifier.weight(1f).padding(horizontal = 12.dp))
                                TextButton(onClick = { editSkills = editSkills.filterNot { it.path == skill.path } }) {
                                    Text(stringResource(R.string.remove_action))
                                }
                            }
                        }
                    }
                    Text(
                        stringResource(R.string.queued_edit_local_only),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.editQueuedTurn(id, editText, editImages, editSkills)
                        editId = null
                    },
                    enabled = editText.isNotBlank() || editImages.isNotEmpty() || editSkills.isNotEmpty(),
                ) { Text(stringResource(R.string.save_action)) }
            },
            dismissButton = { TextButton(onClick = { editId = null }) { Text(stringResource(R.string.cancel_action)) } },
        )
    }
    deleteId?.let { id ->
        AlertDialog(
            onDismissRequest = { deleteId = null },
            title = { Text(stringResource(R.string.delete_queued_message_question)) },
            text = { Text(stringResource(R.string.delete_queued_message_detail)) },
            confirmButton = { TextButton(onClick = { viewModel.deleteQueuedTurn(id); deleteId = null }) { Text(stringResource(R.string.delete_action), color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { deleteId = null }) { Text(stringResource(R.string.cancel_action)) } },
        )
    }
    Surface(
        color = MaterialTheme.colorScheme.secondaryContainer,
        tonalElevation = 1.dp,
        modifier = Modifier.testTag("queued_turn_tray"),
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.queued_messages), style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
                if (state.queueLoading) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                else {
                    Text(state.queuedTurns.size.toString(), style = MaterialTheme.typography.labelMedium)
                    TextButton(onClick = { managerOpen = true }, modifier = Modifier.testTag("manage_queued_turns")) {
                        Text(stringResource(R.string.manage_action))
                    }
                }
            }
            state.queuedTurns.take(2).forEach { queued ->
                QueuedTurnPreviewRow(
                    queued = queued,
                    onOpenManager = { managerOpen = true },
                    onRetry = { viewModel.retryQueuedTurn(queued.id) },
                )
            }
            if (state.queuedTurns.size > 2) {
                val additionalCount = state.queuedTurns.size - 2
                Text(pluralStringResource(R.plurals.more_queued, additionalCount, additionalCount), style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun QueuedTurnPreviewRow(
    queued: QueuedTurn,
    onOpenManager: () -> Unit,
    onRetry: () -> Unit,
) {
    val status = queuedTurnStatusTitle(queued.state)
    Surface(
        onClick = onOpenManager,
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface,
        modifier = Modifier.fillMaxWidth().semantics { stateDescription = status },
    ) {
        Row(
            Modifier.fillMaxWidth().padding(start = 12.dp, top = 8.dp, bottom = 8.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            QueuedTurnStateIcon(queued.state)
            Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                Text(
                    queuedTurnPreview(queued),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodyMedium,
                )
                Text(
                    status,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (queued.state == QueuedTurnState.NeedsConfirmation) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }
            if (queued.state == QueuedTurnState.NeedsConfirmation) {
                TextButton(onClick = onRetry) { Text(stringResource(R.string.confirm_retry)) }
            } else if (queued.state == QueuedTurnState.Dispatching) {
                CircularProgressIndicator(Modifier.padding(12.dp).size(18.dp), strokeWidth = 2.dp)
            } else {
                Icon(Icons.Filled.MoreVert, stringResource(R.string.manage_queued_messages))
            }
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun QueuedTurnManager(
    state: MainUiState,
    onDismiss: () -> Unit,
    onEdit: (QueuedTurn) -> Unit,
    onDelete: (QueuedTurn) -> Unit,
    onRetry: (String) -> Unit,
    onGuideNow: (String) -> Unit,
    onMove: (String, Int) -> Unit,
) {
    val windowWidth = with(LocalDensity.current) { LocalWindowInfo.current.containerSize.width.toDp() }
    val compact = windowWidth < 600.dp
    if (compact) {
        ModalBottomSheet(
            onDismissRequest = onDismiss,
            modifier = Modifier.testTag("queued_turn_manager"),
        ) {
            QueuedTurnManagerContent(state, onDismiss, onEdit, onDelete, onRetry, onGuideNow, onMove)
        }
    } else {
        Dialog(
            onDismissRequest = onDismiss,
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(
                shape = RoundedCornerShape(28.dp),
                color = MaterialTheme.colorScheme.surface,
                tonalElevation = 6.dp,
                modifier = Modifier.width(560.dp).fillMaxHeight(0.86f).testTag("queued_turn_manager"),
            ) {
                QueuedTurnManagerContent(state, onDismiss, onEdit, onDelete, onRetry, onGuideNow, onMove)
            }
        }
    }
}

@Composable
internal fun QueuedTurnManagerContent(
    state: MainUiState,
    onDismiss: () -> Unit,
    onEdit: (QueuedTurn) -> Unit,
    onDelete: (QueuedTurn) -> Unit,
    onRetry: (String) -> Unit,
    onGuideNow: (String) -> Unit,
    onMove: (String, Int) -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                stringResource(R.string.queued_turn_manager_title),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.semantics { heading() },
            )
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.secondaryContainer,
                modifier = Modifier.padding(start = 8.dp),
            ) {
                Text(state.queuedTurns.size.toString(), Modifier.padding(horizontal = 10.dp, vertical = 4.dp))
            }
        }
        Text(
            stringResource(R.string.queued_turn_manager_detail),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
        )
        LazyColumn(
            modifier = Modifier.weight(1f, fill = true),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            contentPadding = PaddingValues(bottom = 12.dp),
        ) {
            items(state.queuedTurns, key = QueuedTurn::id) { queued ->
                QueuedTurnManagerRow(
                    queued = queued,
                    index = state.queuedTurns.indexOfFirst { it.id == queued.id },
                    count = state.queuedTurns.size,
                    canGuide = queued.state == QueuedTurnState.Waiting &&
                        ComposerSendMode.fromWire(queued.collaborationMode).allowsGuidedFollowUp &&
                        queued.goalObjective == null &&
                        state.activeTurnId != null &&
                        state.conversationConnected,
                    reorderLocked = state.queuedTurns.any { it.state == QueuedTurnState.Dispatching },
                    onEdit = { onEdit(queued) },
                    onDelete = { onDelete(queued) },
                    onRetry = { onRetry(queued.id) },
                    onGuideNow = { onGuideNow(queued.id) },
                    onMove = { onMove(queued.id, it) },
                )
            }
        }
        HorizontalDivider()
        TextButton(
            onClick = onDismiss,
            modifier = Modifier.align(Alignment.End).padding(vertical = 4.dp),
        ) { Text(stringResource(R.string.close_action)) }
    }
}

@Composable
private fun QueuedTurnManagerRow(
    queued: QueuedTurn,
    index: Int,
    count: Int,
    canGuide: Boolean,
    reorderLocked: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onRetry: () -> Unit,
    onGuideNow: () -> Unit,
    onMove: (Int) -> Unit,
) {
    var menuOpen by remember(queued.id) { mutableStateOf(false) }
    val status = queuedTurnStatusTitle(queued.state)
    val errorState = queued.state == QueuedTurnState.NeedsConfirmation
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = if (errorState) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.surfaceVariant,
        modifier = Modifier.fillMaxWidth().testTag("queued_turn_${queued.id}").semantics { stateDescription = status },
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                QueuedTurnStateIcon(queued.state)
                Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                    Text(
                        queuedTurnPreview(queued),
                        style = MaterialTheme.typography.bodyLarge,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        status,
                        style = MaterialTheme.typography.labelMedium,
                        color = if (errorState) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Box {
                    IconButton(
                        onClick = { menuOpen = true },
                        enabled = queued.state != QueuedTurnState.Dispatching,
                        modifier = Modifier.testTag("queued_turn_menu_${queued.id}"),
                    ) {
                        Icon(Icons.Filled.MoreVert, stringResource(R.string.queued_message_actions))
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.edit_action)) },
                            leadingIcon = { Icon(Icons.Filled.Edit, null) },
                            onClick = { menuOpen = false; onEdit() },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.guide_current_reply_now)) },
                            leadingIcon = { Icon(Icons.AutoMirrored.Filled.Send, null) },
                            enabled = canGuide,
                            modifier = Modifier.testTag("guide_queued_turn_${queued.id}"),
                            onClick = { menuOpen = false; onGuideNow() },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.move_up_action)) },
                            leadingIcon = { Icon(Icons.Filled.ArrowUpward, null) },
                            enabled = index > 0 && !reorderLocked,
                            onClick = { menuOpen = false; onMove(-1) },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.move_down_action)) },
                            leadingIcon = { Icon(Icons.Filled.ArrowDownward, null) },
                            enabled = index < count - 1 && !reorderLocked,
                            modifier = Modifier.testTag("move_down_queued_turn_${queued.id}"),
                            onClick = { menuOpen = false; onMove(1) },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.delete_action), color = MaterialTheme.colorScheme.error) },
                            leadingIcon = { Icon(Icons.Filled.Delete, null, tint = MaterialTheme.colorScheme.error) },
                            onClick = { menuOpen = false; onDelete() },
                        )
                    }
                }
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                queued.model?.takeIf(String::isNotBlank)?.let { QueueMetadataChip(it) }
                queued.effort?.takeIf(String::isNotBlank)?.let { QueueMetadataChip(it) }
                QueueMetadataChip(permissionModeTitle(PermissionMode.fromWire(queued.permissionMode)))
                if (ComposerSendMode.fromWire(queued.collaborationMode) == ComposerSendMode.Plan) {
                    QueueMetadataChip(stringResource(R.string.plan_mode))
                }
                if (queued.goalObjective != null) {
                    QueueMetadataChip(stringResource(R.string.goal_mode))
                }
                if (queued.skills.isNotEmpty()) {
                    QueueMetadataChip(pluralStringResource(R.plurals.queued_skills_count, queued.skills.size, queued.skills.size))
                }
                if (queued.images.isNotEmpty()) {
                    QueueMetadataChip(pluralStringResource(R.plurals.queued_images_count, queued.images.size, queued.images.size))
                }
            }
            if (queued.images.isNotEmpty()) {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(queued.images, key = { it.id }) { image ->
                        AsyncImage(
                            model = image.dataUrl,
                            contentDescription = stringResource(R.string.queued_image_preview),
                            modifier = Modifier.size(52.dp).clip(RoundedCornerShape(10.dp)),
                        )
                    }
                }
            }
            queued.lastError?.takeIf(String::isNotBlank)?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (errorState) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            when (queued.state) {
                QueuedTurnState.Dispatching -> LinearProgressIndicator(Modifier.fillMaxWidth())
                QueuedTurnState.NeedsConfirmation -> {
                    OutlinedButton(onClick = onRetry, modifier = Modifier.align(Alignment.End).testTag("retry_queued_turn_${queued.id}")) {
                        Text(stringResource(R.string.confirm_retry))
                    }
                }
                QueuedTurnState.Waiting -> Unit
            }
        }
    }
}

@Composable
private fun QueueMetadataChip(label: String) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Text(label, Modifier.padding(horizontal = 10.dp, vertical = 5.dp), style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
private fun QueuedTurnStateIcon(state: QueuedTurnState) {
    val icon = when (state) {
        QueuedTurnState.Waiting -> Icons.Filled.Schedule
        QueuedTurnState.Dispatching -> Icons.AutoMirrored.Filled.PlaylistPlay
        QueuedTurnState.NeedsConfirmation -> Icons.Filled.ErrorOutline
    }
    val tint = if (state == QueuedTurnState.NeedsConfirmation) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary
    Icon(icon, queuedTurnStatusTitle(state), tint = tint, modifier = Modifier.size(22.dp))
}

@Composable
private fun queuedTurnStatusTitle(state: QueuedTurnState): String = stringResource(
    when (state) {
        QueuedTurnState.Waiting -> R.string.queued_waiting
        QueuedTurnState.Dispatching -> R.string.queued_dispatching
        QueuedTurnState.NeedsConfirmation -> R.string.queued_needs_confirmation
    },
)

@Composable
private fun queuedTurnPreview(queued: QueuedTurn): String = if (queued.text.isNotBlank()) {
    queued.text
} else {
    pluralStringResource(R.plurals.queued_image_attachments, queued.images.size, queued.images.size)
}

@Composable
private fun permissionModeTitle(mode: PermissionMode): String = stringResource(
    when (mode) {
        PermissionMode.RequestApproval -> R.string.permission_ask
        PermissionMode.ReadOnly -> R.string.permission_read_only
        PermissionMode.AutoApprove -> R.string.permission_auto_review
        PermissionMode.FullAccess -> R.string.permission_full_access
    },
)

@Composable
private fun permissionModeDetail(mode: PermissionMode): String = stringResource(
    when (mode) {
        PermissionMode.RequestApproval -> R.string.permission_ask_detail
        PermissionMode.ReadOnly -> R.string.permission_read_only_detail
        PermissionMode.AutoApprove -> R.string.permission_auto_review_detail
        PermissionMode.FullAccess -> R.string.permission_full_access_detail
    },
)

@Composable
private fun goalStatusTitle(status: ThreadGoalStatus): String = stringResource(
    when (status) {
        ThreadGoalStatus.Active -> R.string.goal_active
        ThreadGoalStatus.Paused -> R.string.goal_paused
        ThreadGoalStatus.Blocked -> R.string.goal_blocked
        ThreadGoalStatus.UsageLimited -> R.string.goal_usage_limited
        ThreadGoalStatus.BudgetLimited -> R.string.goal_budget_limited
        ThreadGoalStatus.Complete -> R.string.goal_complete
    },
)

@Composable
private fun goalTransitionTitle(current: ThreadGoalStatus, target: ThreadGoalStatus): String = stringResource(
    when (target) {
        ThreadGoalStatus.Paused -> R.string.goal_pause
        ThreadGoalStatus.Complete -> R.string.goal_mark_complete
        ThreadGoalStatus.Blocked -> R.string.goal_mark_blocked
        ThreadGoalStatus.Active -> if (current == ThreadGoalStatus.Complete) {
            R.string.goal_reactivate
        } else {
            R.string.goal_resume
        }
        ThreadGoalStatus.UsageLimited -> R.string.goal_usage_limited
        ThreadGoalStatus.BudgetLimited -> R.string.goal_budget_limited
    },
)

private fun formatGoalDuration(seconds: Long): String {
    val hours = seconds / 3_600
    val minutes = (seconds % 3_600) / 60
    return when {
        hours > 0 -> "${hours}h ${minutes}m"
        minutes > 0 -> "${minutes}m"
        else -> "${seconds.coerceAtLeast(0)}s"
    }
}

@Composable
private fun ThreadGoalEditorDialog(
    threadId: String,
    goal: ThreadGoal?,
    loading: Boolean,
    onDismiss: () -> Unit,
    onSave: (objective: String, status: ThreadGoalStatus, tokenBudget: String) -> Unit,
) {
    var objective by remember(threadId, goal?.objective) { mutableStateOf(goal?.objective.orEmpty()) }
    var tokenBudget by remember(threadId, goal?.tokenBudget) { mutableStateOf(goal?.tokenBudget?.toString().orEmpty()) }
    val objectiveValid = objective.isNotBlank() && objective.trim().toByteArray().size <= 8_192
    val parsedBudget = tokenBudget.trim().takeIf(String::isNotEmpty)?.toLongOrNull()
    val budgetValid = tokenBudget.isBlank() || parsedBudget?.let { it > 0 } == true
    AlertDialog(
        onDismissRequest = { if (!loading) onDismiss() },
        title = { Text(stringResource(if (goal == null) R.string.goal_add else R.string.goal_edit)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = objective,
                    onValueChange = { objective = it },
                    label = { Text(stringResource(R.string.objective)) },
                    supportingText = {
                        Text(
                            stringResource(
                                if (objective.trim().toByteArray().size > 8_192) {
                                    R.string.goal_objective_too_long
                                } else {
                                    R.string.goal_objective_help
                                },
                            ),
                        )
                    },
                    isError = objective.isNotBlank() && objective.trim().toByteArray().size > 8_192,
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 3,
                )
                OutlinedTextField(
                    value = tokenBudget,
                    onValueChange = { tokenBudget = it.filter(Char::isDigit) },
                    label = { Text(stringResource(R.string.token_budget_optional)) },
                    supportingText = {
                        Text(
                            stringResource(
                                if (budgetValid) R.string.goal_budget_help else R.string.goal_budget_invalid,
                            ),
                        )
                    },
                    isError = !budgetValid,
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
                if (loading) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.goal_syncing), style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    onSave(
                        objective.trim(),
                        goal?.status ?: ThreadGoalStatus.Active,
                        tokenBudget,
                    )
                },
                enabled = objectiveValid && budgetValid && !loading,
                modifier = Modifier.testTag("goal_editor_save"),
            ) { Text(stringResource(R.string.save_action)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !loading) {
                Text(stringResource(R.string.cancel_action))
            }
        },
    )
}

@Composable
internal fun GoalLifecycleCard(
    goal: ThreadGoal?,
    loading: Boolean,
    onEdit: () -> Unit,
    onRefresh: () -> Unit,
    onTransition: (ThreadGoalStatus) -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Card(modifier.fillMaxWidth().testTag("goal_section")) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    stringResource(R.string.session_goal),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f).semantics { heading() },
                )
                if (goal != null) {
                    Surface(
                        color = MaterialTheme.colorScheme.secondaryContainer,
                        contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
                        shape = CircleShape,
                    ) {
                        Text(
                            goalStatusTitle(goal.status),
                            Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                            style = MaterialTheme.typography.labelMedium,
                        )
                    }
                }
            }
            if (goal == null) {
                Text(
                    stringResource(R.string.goal_no_goal),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                )
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Button(
                        onClick = onEdit,
                        enabled = !loading,
                        modifier = Modifier.testTag("goal_action_add"),
                    ) { Text(stringResource(R.string.goal_add)) }
                    OutlinedButton(
                        onClick = onRefresh,
                        enabled = !loading,
                        modifier = Modifier.testTag("goal_action_refresh"),
                    ) { Text(stringResource(R.string.goal_refresh)) }
                }
            } else {
                Text(stringResource(R.string.objective), style = MaterialTheme.typography.labelMedium)
                Text(goal.objective, style = MaterialTheme.typography.bodyLarge)
                goal.tokenBudget?.let { budget ->
                    val progress = if (budget > 0) {
                        (goal.tokensUsed.toFloat() / budget.toFloat()).coerceIn(0f, 1f)
                    } else {
                        0f
                    }
                    Text(
                        stringResource(R.string.goal_token_progress, goal.tokensUsed, budget),
                        style = MaterialTheme.typography.bodySmall,
                    )
                    LinearProgressIndicator(
                        progress = { progress },
                        modifier = Modifier.fillMaxWidth().testTag("goal_progress"),
                    )
                }
                if (goal.timeUsedSeconds > 0 || goal.updatedAtEpochSeconds != null) {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        if (goal.timeUsedSeconds > 0) {
                            Text(
                                stringResource(R.string.goal_time_used, formatGoalDuration(goal.timeUsedSeconds)),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        goal.updatedAtEpochSeconds?.let { epoch ->
                            val updated = remember(epoch) {
                                DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(epoch * 1_000))
                            }
                            Text(
                                stringResource(R.string.goal_updated, updated),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    OutlinedButton(
                        onClick = onEdit,
                        enabled = !loading,
                        modifier = Modifier.testTag("goal_action_edit"),
                    ) { Text(stringResource(R.string.goal_edit)) }
                    ThreadGoalTransitionPolicy.allowedTransitions(goal.status).forEach { target ->
                        OutlinedButton(
                            onClick = { onTransition(target) },
                            enabled = !loading,
                            modifier = Modifier.testTag("goal_action_${target.wireName}"),
                        ) { Text(goalTransitionTitle(goal.status, target)) }
                    }
                    OutlinedButton(
                        onClick = onRefresh,
                        enabled = !loading,
                        modifier = Modifier.testTag("goal_action_refresh"),
                    ) { Text(stringResource(R.string.goal_refresh)) }
                }
                HorizontalDivider()
                TextButton(
                    onClick = onClear,
                    enabled = !loading,
                    modifier = Modifier.testTag("goal_action_clear"),
                ) {
                    Text(stringResource(R.string.goal_clear), color = MaterialTheme.colorScheme.error)
                }
            }
            if (loading) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.goal_syncing), style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun InspectorPane(
    state: MainUiState,
    viewModel: MainViewModel,
    modifier: Modifier = Modifier,
    settingsMode: Boolean = false,
) {
    val connection = state.connected
    val context = LocalContext.current
    val codeFontFamily = LocalMimiCodeFontFamily.current
    var notificationsGranted by remember {
        mutableStateOf(Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
    }
    var permissionRecoveryMessage by rememberSaveable { mutableStateOf<String?>(null) }
    val lifecycleOwner = LocalLifecycleOwner.current
    val notificationsDisabledSettings = stringResource(R.string.notifications_disabled_settings)
    val couldNotOpenDocument = stringResource(R.string.could_not_open_document)
    val couldNotOpenPullRequest = stringResource(R.string.could_not_open_pull_request)
    val exportLogFailed = stringResource(R.string.export_log_failed)
    val diagnosticLogSubject = stringResource(R.string.diagnostic_log_subject)
    val diagnosticLogChooserTitle = stringResource(R.string.diagnostic_log_chooser_title)
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        notificationsGranted = granted
        if (!granted) permissionRecoveryMessage = notificationsDisabledSettings
    }
    DisposableEffect(lifecycleOwner, context) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                notificationsGranted = Build.VERSION.SDK_INT < 33 ||
                    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    permissionRecoveryMessage?.let { message ->
        PermissionRecoveryDialog(
            message = message,
            onDismiss = { permissionRecoveryMessage = null },
            onOpenSettings = {
                permissionRecoveryMessage = null
                context.startActivity(appPermissionSettingsIntent(context.packageName))
            },
        )
    }
    var commitMessage by rememberSaveable { mutableStateOf("") }
    var artifactPath by rememberSaveable { mutableStateOf("") }
    var worktreeName by rememberSaveable { mutableStateOf("") }
    var worktreeBase by rememberSaveable { mutableStateOf("") }
    var pendingWorktreeDelete by remember { mutableStateOf<String?>(null) }
    var pendingRevert by remember { mutableStateOf<String?>(null) }
    var confirmPush by remember { mutableStateOf(false) }
    var confirmQuickPublish by remember { mutableStateOf(false) }
    var workspacePath by rememberSaveable { mutableStateOf("") }
    var pendingCommandAction by remember { mutableStateOf<String?>(null) }
    var pendingRevertPatch by remember { mutableStateOf<String?>(null) }
    var pullRequestTitle by rememberSaveable { mutableStateOf("") }
    var pullRequestBody by rememberSaveable { mutableStateOf("") }
    var pullRequestDraft by rememberSaveable { mutableStateOf(true) }
    var confirmPullRequest by remember { mutableStateOf(false) }
    var whatToTest by rememberSaveable { mutableStateOf("") }
    var confirmTestFlight by remember { mutableStateOf(false) }
    var legalDocument by remember { mutableStateOf<String?>(null) }
    var forgetProfileId by remember { mutableStateOf<String?>(null) }
    var renameProfileId by remember { mutableStateOf<String?>(null) }
    var renameProfileValue by remember { mutableStateOf("") }
    var themeMenu by remember { mutableStateOf(false) }
    var uiFontMenu by remember { mutableStateOf(false) }
    var codeFontMenu by remember { mutableStateOf(false) }
    var inspectorSection by rememberSaveable { mutableStateOf(InspectorSection.Overview) }
    var activityMode by rememberSaveable { mutableStateOf(InspectorActivityMode.Entries) }
    var goalEditorThreadId by remember { mutableStateOf<String?>(null) }
    var clearGoalThreadId by remember { mutableStateOf<String?>(null) }
    val uriHandler = LocalUriHandler.current
    LaunchedEffect(state.worktreeBranches?.path, state.worktreeBranches?.defaultBase) {
        if (worktreeBase.isBlank()) worktreeBase = state.worktreeBranches?.defaultBase.orEmpty()
    }
    goalEditorThreadId?.let { threadId ->
        ThreadGoalEditorDialog(
            threadId = threadId,
            goal = state.threadGoals[threadId],
            loading = state.goalLoading,
            onDismiss = { goalEditorThreadId = null },
            onSave = { objective, status, budget ->
                viewModel.setThreadGoal(threadId, objective, status, budget) {
                    goalEditorThreadId = null
                }
            },
        )
    }
    clearGoalThreadId?.let { threadId ->
        AlertDialog(
            onDismissRequest = { if (!state.goalLoading) clearGoalThreadId = null },
            title = { Text(stringResource(R.string.goal_clear_question)) },
            text = { Text(stringResource(R.string.goal_clear_detail)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.clearThreadGoal(threadId) {
                            clearGoalThreadId = null
                        }
                    },
                    enabled = !state.goalLoading,
                ) {
                    Text(stringResource(R.string.goal_clear), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(
                    onClick = { clearGoalThreadId = null },
                    enabled = !state.goalLoading,
                ) { Text(stringResource(R.string.cancel_action)) }
            },
        )
    }
    if (state.workspaceLoading || state.directoryListing != null) {
        val listing = state.directoryListing
        AlertDialog(
            onDismissRequest = { if (!state.workspaceLoading) viewModel.dismissDirectoryBrowser() },
            title = { Text(stringResource(R.string.open_workspace)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        listing?.path ?: stringResource(R.string.locating_authorized_folder),
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listing?.parentPath?.let { parent ->
                            OutlinedButton(onClick = { viewModel.browseDirectory(parent) }, enabled = !state.workspaceLoading) { Text(stringResource(R.string.up_action)) }
                        }
                        Button(
                            onClick = { listing?.path?.let(viewModel::openWorkspace) },
                            enabled = listing?.path?.isNotBlank() == true && !state.workspaceLoading,
                        ) { Text(stringResource(R.string.open_this_folder)) }
                    }
                    if (state.workspaceLoading) CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                    else LazyColumn(Modifier.heightIn(max = 300.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        items(listing?.entries.orEmpty(), key = { "directory-${it.path}" }) { entry ->
                            DirectoryBrowserEntry(
                                entry = entry,
                                onBrowse = viewModel::browseDirectory,
                                onOpen = viewModel::openWorkspace,
                                onPreview = viewModel::previewFile,
                            )
                        }
                    }
                    OutlinedTextField(workspacePath, { workspacePath = it }, label = { Text(stringResource(R.string.absolute_path)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    OutlinedButton(onClick = { viewModel.openWorkspace(workspacePath) }, enabled = workspacePath.isNotBlank() && !state.workspaceLoading) { Text(stringResource(R.string.open_typed_path)) }
                    if (listing?.truncated == true) Text(stringResource(R.string.directory_truncated), style = MaterialTheme.typography.labelSmall)
                }
            },
            confirmButton = { TextButton(onClick = viewModel::dismissDirectoryBrowser, enabled = !state.workspaceLoading) { Text(stringResource(R.string.close_action)) } },
        )
    }
    state.commandActionResult?.let { result ->
        AlertDialog(
            onDismissRequest = viewModel::clearCommandActionResult,
            title = { Text(result.name) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        stringResource(
                            if (result.success) R.string.command_completed_in
                            else R.string.command_failed_with_exit_code,
                            if (result.success) result.durationMs else result.exitCode,
                        ),
                    )
                    result.output?.takeIf(String::isNotBlank)?.let { output ->
                        Text(output.take(100_000), Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()), fontFamily = codeFontFamily)
                    }
                    if (result.truncated == true) Text(stringResource(R.string.output_truncated), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            },
            confirmButton = { TextButton(onClick = viewModel::clearCommandActionResult) { Text(stringResource(R.string.close_action)) } },
        )
    }
    pendingCommandAction?.let { id ->
        val action = state.commandActions.firstOrNull { it.id == id }
        AlertDialog(
            onDismissRequest = { pendingCommandAction = null },
            title = {
                Text(
                    action?.let { stringResource(R.string.run_named_action_question, it.name) }
                        ?: stringResource(R.string.action_no_longer_available),
                )
            },
            text = {
                Text(
                    action?.let {
                        stringResource(R.string.command_details, it.displayCommand, it.workingDir, it.timeoutSeconds)
                    } ?: stringResource(R.string.action_no_longer_available),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = { viewModel.runCommandAction(id, true); pendingCommandAction = null },
                    enabled = action != null && !state.commandActionLoading,
                ) {
                    Text(stringResource(R.string.run_action))
                }
            },
            dismissButton = { TextButton(onClick = { pendingCommandAction = null }) { Text(stringResource(R.string.cancel_action)) } },
        )
    }
    pendingRevertPatch?.let { patch ->
        AlertDialog(
            onDismissRequest = { pendingRevertPatch = null },
            title = { Text(stringResource(R.string.discard_hunk_question)) },
            text = { Text(stringResource(R.string.discard_hunk_detail)) },
            confirmButton = { TextButton(onClick = { viewModel.gitPatchAction(GitActionKind.RevertPatch, patch); pendingRevertPatch = null }) { Text(stringResource(R.string.discard_action), color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { pendingRevertPatch = null }) { Text(stringResource(R.string.cancel_action)) } },
        )
    }
    if (confirmQuickPublish) {
        AlertDialog(
            onDismissRequest = { confirmQuickPublish = false },
            title = { Text(stringResource(R.string.quick_publish_question)) },
            text = { Text(stringResource(R.string.quick_publish_detail, commitMessage)) },
            confirmButton = {
                TextButton(
                    onClick = { viewModel.gitQuickPublish(commitMessage); confirmQuickPublish = false; commitMessage = "" },
                    enabled = commitMessage.trim().length in 1..500 && !state.gitLoading,
                ) {
                    Text(stringResource(R.string.commit_and_push))
                }
            },
            dismissButton = { TextButton(onClick = { confirmQuickPublish = false }) { Text(stringResource(R.string.cancel_action)) } },
        )
    }
    if (confirmPullRequest) {
        AlertDialog(
            onDismissRequest = { confirmPullRequest = false },
            title = { Text(stringResource(if (pullRequestDraft) R.string.create_draft_pull_request_question else R.string.create_pull_request_question)) },
            text = { Text(stringResource(R.string.pull_request_safety_detail, pullRequestTitle)) },
            confirmButton = {
                TextButton(
                    onClick = { viewModel.createPullRequest(pullRequestTitle, pullRequestBody, pullRequestDraft); confirmPullRequest = false },
                    enabled = pullRequestTitle.trim().length in 1..256 && pullRequestBody.length <= 64_000 && !state.gitLoading,
                ) {
                    Text(stringResource(R.string.create_action))
                }
            },
            dismissButton = { TextButton(onClick = { confirmPullRequest = false }) { Text(stringResource(R.string.cancel_action)) } },
        )
    }
    if (confirmTestFlight) {
        AlertDialog(
            onDismissRequest = { confirmTestFlight = false },
            title = { Text(stringResource(R.string.publish_testflight_question)) },
            text = { Text(stringResource(R.string.publish_testflight_detail, whatToTest)) },
            confirmButton = {
                TextButton(
                    onClick = { viewModel.runTestFlight(whatToTest); confirmTestFlight = false },
                    enabled = whatToTest.trim().length in 1..4_000 && !state.gitLoading,
                ) {
                    Text(stringResource(R.string.publish_action))
                }
            },
            dismissButton = { TextButton(onClick = { confirmTestFlight = false }) { Text(stringResource(R.string.cancel_action)) } },
        )
    }
    legalDocument?.let { key ->
        if (key == "licenses") {
            val loadFailure = stringResource(R.string.legal_document_load_failed)
            val projectLicense = remember(context) {
                runCatching { BundledLegalAssets.read(context, BundledLegalAssets.ProjectLicense) }
                    .getOrDefault(loadFailure)
            }
            val notices = remember(context) {
                runCatching { BundledLegalAssets.read(context, BundledLegalAssets.ThirdPartyNotices) }
                    .getOrDefault(loadFailure)
            }
            OpenSourceLicensesDialog(
                projectLicense = projectLicense,
                notices = notices,
                onDismiss = { legalDocument = null },
                onViewOnline = {
                    runCatching {
                        uriHandler.openUri("https://github.com/gaixianggeng/mimi-remote/blob/main/THIRD_PARTY_NOTICES.md")
                    }.onFailure { viewModel.showError(couldNotOpenDocument) }
                },
            )
        } else {
            val document = remember(key, context) { legalDocumentContent(key, context) }
            AlertDialog(
                onDismissRequest = { legalDocument = null },
                title = { Text(document.title) },
                text = { MarkdownMessageContent(document.body, Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState())) },
                confirmButton = { TextButton(onClick = { legalDocument = null }) { Text(stringResource(R.string.close_action)) } },
                dismissButton = { TextButton(onClick = { runCatching { uriHandler.openUri(document.url) }.onFailure { viewModel.showError(couldNotOpenDocument) } }) { Text(stringResource(R.string.view_online)) } },
            )
        }
    }
    renameProfileId?.let { profileId ->
        AlertDialog(
            onDismissRequest = { renameProfileId = null },
            title = { Text(stringResource(R.string.rename_mac)) },
            text = { OutlinedTextField(renameProfileValue, { renameProfileValue = it }, label = { Text(stringResource(R.string.mac_name)) }, singleLine = true) },
            confirmButton = { TextButton(onClick = { viewModel.renameProfile(profileId, renameProfileValue); renameProfileId = null }, enabled = renameProfileValue.isNotBlank()) { Text(stringResource(R.string.save_action)) } },
            dismissButton = { TextButton(onClick = { renameProfileId = null }) { Text(stringResource(R.string.cancel_action)) } },
        )
    }
    forgetProfileId?.let { profileId ->
        val profile = state.profiles.firstOrNull { it.id == profileId }
        AlertDialog(
            onDismissRequest = { forgetProfileId = null },
            title = { Text(stringResource(R.string.forget_mac_question, profile?.displayName ?: "Mac")) },
            text = { Text(stringResource(R.string.forget_mac_detail)) },
            confirmButton = { TextButton(onClick = { viewModel.deleteProfile(profileId); forgetProfileId = null }) { Text(stringResource(R.string.forget_action), color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { forgetProfileId = null }) { Text(stringResource(R.string.cancel_action)) } },
        )
    }
    pendingRevert?.let { file ->
        AlertDialog(
            onDismissRequest = { pendingRevert = null },
            title = { Text(stringResource(R.string.discard_changes_question)) },
            text = { Text(stringResource(R.string.discard_changes_detail, file)) },
            confirmButton = {
                TextButton(onClick = { viewModel.gitAction(GitActionKind.Revert, file); pendingRevert = null }) {
                    Text(stringResource(R.string.discard_action), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { pendingRevert = null }) { Text(stringResource(R.string.cancel_action)) } },
        )
    }
    if (confirmPush) {
        AlertDialog(
            onDismissRequest = { confirmPush = false },
            title = { Text(stringResource(R.string.push_current_branch_question)) },
            text = { Text(stringResource(R.string.push_current_branch_detail)) },
            confirmButton = {
                TextButton(
                    onClick = { viewModel.gitPush(); confirmPush = false },
                    enabled = !state.gitLoading,
                ) {
                    Text(stringResource(R.string.push_action))
                }
            },
            dismissButton = { TextButton(onClick = { confirmPush = false }) { Text(stringResource(R.string.cancel_action)) } },
        )
    }
    pendingWorktreeDelete?.let { path ->
        AlertDialog(
            onDismissRequest = { pendingWorktreeDelete = null },
            title = { Text(stringResource(R.string.delete_worktree_question)) },
            text = { Text(stringResource(R.string.delete_worktree_detail, path)) },
            confirmButton = {
                TextButton(onClick = { viewModel.deleteWorktree(path); pendingWorktreeDelete = null }) {
                    Text(stringResource(R.string.delete_action), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { pendingWorktreeDelete = null }) { Text(stringResource(R.string.cancel_action)) } },
        )
    }
    state.worktreeCleanupPreview?.let { preview ->
        AlertDialog(
            onDismissRequest = viewModel::dismissWorktreeCleanup,
            title = { Text(stringResource(R.string.cleanup_old_worktrees_question)) },
            text = {
                Column(Modifier.heightIn(max = 440.dp).verticalScroll(rememberScrollState())) {
                    Text(
                        pluralStringResource(
                            R.plurals.worktree_cleanup_policy,
                            preview.policy.candidateAfterDays,
                            preview.policy.candidateAfterDays,
                            preview.policy.keepLatestPerProject,
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(12.dp))
                    if (preview.candidatePaths.isEmpty()) {
                        Text(stringResource(R.string.no_worktrees_eligible))
                    } else {
                        Text(stringResource(R.string.eligible_count, preview.candidatePaths.size), fontWeight = FontWeight.SemiBold)
                        preview.candidatePaths.forEach { Text("• $it", style = MaterialTheme.typography.bodySmall) }
                    }
                    val blocked = preview.worktrees.filter { !it.eligible && it.blockers.isNotEmpty() }
                    if (blocked.isNotEmpty()) {
                        Spacer(Modifier.height(12.dp))
                        Text(stringResource(R.string.protected_title), fontWeight = FontWeight.SemiBold)
                        blocked.forEach { item ->
                            Text("${item.worktree.path}: ${item.blockers.joinToString()}", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = viewModel::executeWorktreeCleanup,
                    enabled = preview.candidatePaths.isNotEmpty() && !preview.planId.isNullOrBlank(),
                ) { Text(stringResource(R.string.delete_eligible), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = viewModel::dismissWorktreeCleanup) { Text(stringResource(R.string.close_action)) } },
        )
    }
    val activityGroups = conversationTimelineEntries(state.messages)
        .filterIsInstance<ConversationTimelineEntry.ActivityGroup>()
        .takeLast(8)
    val selectedThread = state.threads.firstOrNull { it.id == state.selectedThreadId }
    val sessionContext = selectedThread?.context
    Column(modifier.background(MaterialTheme.colorScheme.surfaceContainerLowest)) {
        PaneHeader(
            stringResource(if (settingsMode) R.string.settings else R.string.inspector),
            stringResource(if (settingsMode) R.string.app_preferences_and_diagnostics else R.string.session_overview_subtitle),
        )
        if (!settingsMode) {
            PrimaryTabRow(
                selectedTabIndex = inspectorSection.ordinal,
                modifier = Modifier.fillMaxWidth(),
            ) {
                InspectorSection.entries.forEach { section ->
                    Tab(
                        selected = inspectorSection == section,
                        onClick = { inspectorSection = section },
                        text = { Text(stringResource(section.labelRes), maxLines = 1) },
                        modifier = Modifier.testTag(section.testTag),
                    )
                }
            }
        }
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (!settingsMode && inspectorSection == InspectorSection.Overview) {
            item {
                InspectorItem(
                    Icons.Filled.CheckCircle,
                    when {
                        connection == null -> stringResource(R.string.not_connected)
                        state.conversationConnected -> stringResource(R.string.connected)
                        else -> stringResource(R.string.reconnecting)
                    },
                    connection?.profile?.displayName.orEmpty(),
                )
            }
            item { InspectorItem(Icons.Filled.Info, stringResource(R.string.agent_version), connection?.version.orEmpty()) }
            item { InspectorItem(Icons.Filled.Folder, stringResource(R.string.projects), state.projects.size.toString()) }
            item { HorizontalDivider() }
            item {
                Text(stringResource(R.string.endpoint), style = MaterialTheme.typography.labelLarge)
                Text(connection?.profile?.endpoint.orEmpty(), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            state.selectedThreadId?.let { selectedThreadId ->
                item {
                    Text(stringResource(R.string.session_context), style = MaterialTheme.typography.titleMedium, modifier = Modifier.semantics { heading() })
                    Text(stringResource(R.string.runtime_value, selectedThread?.runtimeProvider ?: "codex"), style = MaterialTheme.typography.bodySmall)
                    Text(stringResource(R.string.workspace_value, selectedThread?.cwd.orEmpty()), style = MaterialTheme.typography.bodySmall, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    Text(
                        stringResource(
                            R.string.status_permission_value,
                            when {
                                sessionContext?.status?.activeFlags.orEmpty().any { it.equals("waitingOnApproval", true) } ->
                                    stringResource(R.string.context_status_waiting)
                                sessionContext?.status?.activeFlags.orEmpty().any { it.equals("waitingOnUserInput", true) } ->
                                    stringResource(R.string.context_status_waiting)
                                else -> contextStatusPresentation(sessionContext?.status?.type)?.first
                                    ?: stringResource(
                                        if (TurnLifecycleProjection.isBusy(state.activeTurnId, state.awaitingTurnIdentity)) {
                                            R.string.status_running
                                        } else {
                                            R.string.status_idle
                                        },
                                    )
                            },
                            permissionModeTitle(state.permissionMode),
                        ),
                        style = MaterialTheme.typography.bodySmall,
                    )
                    state.selectedModelId?.let { Text(stringResource(R.string.model_effort_value, it, state.selectedReasoningEffort.orEmpty()), style = MaterialTheme.typography.bodySmall) }
                    state.sessionTokenUsage[selectedThreadId]?.let { usage -> Text(stringResource(R.string.context_value, usage), style = MaterialTheme.typography.bodySmall) }
                }
                item(key = "goal-$selectedThreadId") {
                    GoalLifecycleCard(
                        goal = state.threadGoals[selectedThreadId],
                        loading = state.goalLoading,
                        onEdit = { goalEditorThreadId = selectedThreadId },
                        onRefresh = { viewModel.refreshThreadGoal(selectedThreadId) },
                        onTransition = { status -> viewModel.updateThreadGoalStatus(selectedThreadId, status) },
                        onClear = { clearGoalThreadId = selectedThreadId },
                    )
                }
                sessionContext?.let { contextSnapshot ->
                    item(key = "context-environment-$selectedThreadId") {
                        InspectorContextSection(stringResource(R.string.context_environment)) {
                            ContextInfoRow(
                                icon = Icons.Filled.Code,
                                title = stringResource(R.string.context_runtime),
                                value = contextSnapshot.environment?.runtimeProvider ?: selectedThread.runtimeProvider,
                            )
                            contextSnapshot.environment?.provider?.takeIf(String::isNotBlank)?.let { provider ->
                                ContextInfoRow(Icons.Filled.Info, stringResource(R.string.context_provider), provider)
                            }
                            ContextInfoRow(
                                icon = Icons.Filled.Folder,
                                title = stringResource(R.string.context_workspace),
                                value = contextSnapshot.environment?.cwd ?: selectedThread.cwd,
                            )
                        }
                    }
                    contextSnapshot.git?.let { git ->
                        item(key = "context-git-$selectedThreadId") {
                            InspectorContextSection(stringResource(R.string.context_git)) {
                                git.branch?.takeIf(String::isNotBlank)?.let { branch ->
                                    ContextInfoRow(Icons.Filled.Code, stringResource(R.string.context_branch), branch)
                                }
                                git.sha?.takeIf(String::isNotBlank)?.let { sha ->
                                    ContextInfoRow(Icons.Filled.Info, stringResource(R.string.commit_sha), sha.take(12))
                                }
                            }
                        }
                    }
                    item(key = "context-tasks-$selectedThreadId") {
                        InspectorContextSection(stringResource(R.string.context_tasks)) {
                            if (contextSnapshot.tasks.isEmpty()) {
                                ContextEmptyRow(stringResource(R.string.context_no_tasks))
                            } else {
                                contextSnapshot.tasks.forEach { SessionContextTaskRow(it) }
                            }
                        }
                    }
                    item(key = "context-sources-$selectedThreadId") {
                        InspectorContextSection(stringResource(R.string.context_sources)) {
                            if (contextSnapshot.sources.isEmpty()) {
                                ContextEmptyRow(stringResource(R.string.context_no_sources))
                            } else {
                                contextSnapshot.sources.forEach { SessionContextSourceRow(it) }
                            }
                        }
                    }
                    item(key = "context-subagents-$selectedThreadId") {
                        InspectorContextSection(stringResource(R.string.context_subagents)) {
                            if (contextSnapshot.subagents.isEmpty()) {
                                ContextEmptyRow(stringResource(R.string.context_no_subagents))
                            } else {
                                contextSnapshot.subagents.forEach { SessionContextSubagentRow(it) }
                            }
                        }
                    }
                }
            }
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.workspace_actions), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                    IconButton(onClick = viewModel::refreshInspectorCapabilities, enabled = !state.commandActionLoading) {
                        Icon(Icons.Filled.Refresh, stringResource(R.string.refresh_actions))
                    }
                }
                if (state.commandActions.isEmpty()) {
                    Text(stringResource(R.string.no_workspace_actions), style = MaterialTheme.typography.bodySmall)
                }
            }
            items(state.commandActions, key = { "overview-action-${it.id}" }) { action ->
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp)) {
                        Text(action.name, fontWeight = FontWeight.Medium)
                        Text(action.displayCommand, style = MaterialTheme.typography.bodySmall, fontFamily = codeFontFamily)
                        Text("${action.workingDir} · ${action.timeoutSeconds}s", style = MaterialTheme.typography.labelSmall)
                        TextButton(
                            onClick = {
                                if (action.requiresConfirmation) pendingCommandAction = action.id
                                else viewModel.runCommandAction(action.id, false)
                            },
                            enabled = !state.commandActionLoading,
                        ) { Text(stringResource(R.string.run_action)) }
                    }
                }
            }
            }
            if (settingsMode) {
            item {
                SettingsGroupCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.agent_diagnostics), style = MaterialTheme.typography.titleMedium)
                        Text(
                            stringResource(
                                when {
                                    state.doctorResults == null -> R.string.doctor_not_checked
                                    state.doctorResults.ok -> R.string.doctor_all_checks_passed
                                    else -> R.string.doctor_attention_needed
                                },
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = if (state.doctorResults?.ok == false) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    IconButton(onClick = viewModel::refreshDiagnostics, enabled = !state.diagnosticsLoading) {
                        Icon(Icons.Filled.Refresh, stringResource(R.string.refresh_diagnostics))
                    }
                }
                if (state.diagnosticsLoading) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = viewModel::testConnection, enabled = !state.connectionDiagnosticLoading) { Text(stringResource(R.string.test_connection)) }
                    if (state.connectionDiagnosticLoading) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                }
                state.connectionDiagnostic?.let { diagnostic ->
                    Text(
                        stringResource(
                            R.string.connection_diagnostic_summary,
                            diagnostic.transport,
                            diagnostic.latencyMillis,
                            diagnostic.agentVersion,
                        ),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                state.tailscaleNetworkPath?.let { networkPath ->
                    val pathLabel = when (networkPath.kind) {
                        "direct" -> stringResource(R.string.tailscale_direct)
                        "peer_relay" -> stringResource(R.string.tailscale_peer_relay)
                        "derp" -> networkPath.relayRegion
                            ?.let { stringResource(R.string.tailscale_derp_region, it) }
                            ?: stringResource(R.string.tailscale_derp)
                        "not_tailscale" -> stringResource(R.string.tailscale_not_in_use)
                        "unavailable" -> stringResource(R.string.tailscale_path_unavailable)
                        else -> stringResource(R.string.tailscale_path_unknown)
                    }
                    Text(pathLabel, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                state.relayDiagnostics?.let { relay ->
                    val gateway = relay.appServerGateway
                    Text(
                        stringResource(
                            R.string.gateway_diagnostic_summary,
                            gateway.activeConnections,
                            gateway.totalConnections,
                            gateway.failedUpstreamDials,
                            gateway.policyErrors,
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = if (gateway.failedUpstreamDials > 0 || gateway.policyErrors > 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    relay.hints.orEmpty().take(3).forEach { hint -> Text(hint, style = MaterialTheme.typography.labelSmall) }
                }
                state.doctorResults?.checks?.forEach { check ->
                    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.Top) {
                        Text(if (check.ok) "✓" else "!", color = if (check.ok) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error)
                        Spacer(Modifier.width(8.dp))
                        Column(Modifier.weight(1f)) {
                            Text(check.name, fontWeight = FontWeight.Medium)
                            Text(check.message, style = MaterialTheme.typography.bodySmall)
                            if (!check.ok) check.fix?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
                        }
                    }
                }
                if (state.mcpServers.isNotEmpty()) {
                    Spacer(Modifier.height(12.dp))
                    Text(stringResource(R.string.mcp_servers), style = MaterialTheme.typography.labelLarge)
                    state.mcpServers.forEach { server ->
                        Text(
                            "${if (server.enabled) "●" else "○"} ${server.name} · ${server.status ?: server.transport.orEmpty()}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Spacer(Modifier.height(12.dp))
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.developer_mode), style = MaterialTheme.typography.labelLarge)
                        Text(
                            stringResource(R.string.developer_mode_detail),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Switch(checked = state.developerMode, onCheckedChange = viewModel::setDeveloperMode)
                }
                if (state.developerMode) {
                    OutlinedButton(onClick = viewModel::loadHistoryDiagnostics, enabled = !state.historyDiagnosticsLoading) {
                        if (state.historyDiagnosticsLoading) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        else Text(stringResource(R.string.load_historical_diagnostics))
                    }
                    state.historyDiagnostics?.let { payload ->
                        Text(
                            payload,
                            Modifier.fillMaxWidth().heightIn(max = 320.dp).verticalScroll(rememberScrollState()),
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = codeFontFamily,
                        )
                    }
                }
                }
            }
            item {
                SettingsGroupCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.run_notifications), style = MaterialTheme.typography.titleMedium)
                        Text(
                            stringResource(if (notificationsGranted) R.string.notification_enabled_detail else R.string.disabled),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (!notificationsGranted && Build.VERSION.SDK_INT >= 33) {
                        OutlinedButton(onClick = { notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS) }) { Text(stringResource(R.string.enable_action)) }
                    }
                }
                }
            }
            item {
                SettingsGroupCard {
                Text(stringResource(R.string.default_permissions), style = MaterialTheme.typography.titleMedium)
                Text(
                    stringResource(R.string.default_permissions_detail),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp, bottom = 8.dp),
                )
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    PermissionMode.entries.forEach { mode ->
                        val selected = state.permissionMode == mode
                        Card(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { viewModel.setPermissionMode(mode) }
                                .testTag("default_permission_${mode.wireName}"),
                            colors = CardDefaults.cardColors(
                                containerColor = if (selected) {
                                    MaterialTheme.colorScheme.secondaryContainer
                                } else {
                                    MaterialTheme.colorScheme.surfaceContainerHigh
                                },
                            ),
                        ) {
                            Row(
                                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(permissionModeTitle(mode), style = MaterialTheme.typography.titleSmall)
                                    Text(
                                        permissionModeDetail(mode),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                                if (selected) {
                                    Icon(
                                        Icons.Filled.CheckCircle,
                                        contentDescription = stringResource(R.string.selected_value),
                                        tint = MaterialTheme.colorScheme.primary,
                                    )
                                }
                            }
                        }
                    }
                }
                }
            }
            item {
                SettingsGroupCard {
                Text(stringResource(R.string.appearance), style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(8.dp))
                Box {
                    OutlinedButton(onClick = { themeMenu = true }) {
                        val themeLabel = stringResource(when (state.themeMode) {
                            "light" -> R.string.theme_light
                            "dark" -> R.string.theme_dark
                            else -> R.string.theme_system
                        })
                        Text(stringResource(R.string.theme_value, themeLabel))
                    }
                    DropdownMenu(expanded = themeMenu, onDismissRequest = { themeMenu = false }) {
                        listOf(
                            "system" to stringResource(R.string.theme_system),
                            "light" to stringResource(R.string.theme_light),
                            "dark" to stringResource(R.string.theme_dark),
                        ).forEach { (mode, label) ->
                            DropdownMenuItem(
                                text = { Text(label) },
                                onClick = { viewModel.setThemeMode(mode); themeMenu = false },
                            )
                        }
                    }
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.dynamic_color), modifier = Modifier.weight(1f))
                    Switch(checked = state.dynamicColor, onCheckedChange = viewModel::setDynamicColor)
                }
                Text(stringResource(R.string.fixed_palette), style = MaterialTheme.typography.labelLarge)
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(vertical = 4.dp)) {
                    items(listOf("codex", "github", "xcode", "gruvbox")) { preset ->
                        val label = when (preset) { "codex" -> stringResource(R.string.palette_warm_sun); else -> preset.replaceFirstChar(Char::uppercase) }
                        if (state.themePreset == preset && !state.dynamicColor) Button(onClick = { }) { Text(label) }
                        else OutlinedButton(onClick = { viewModel.setThemePreset(preset) }) { Text(label) }
                    }
                }
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(Modifier.weight(1f)) {
                        OutlinedButton(
                            onClick = { uiFontMenu = true },
                            modifier = Modifier.fillMaxWidth().testTag("appearance_ui_font_button"),
                        ) {
                            val label = stringResource(when (state.uiFontPreset) {
                                "rounded" -> R.string.font_rounded
                                "serif" -> R.string.font_serif
                                else -> R.string.font_system
                            })
                            Text(stringResource(R.string.ui_font_value, label), maxLines = 1)
                        }
                        DropdownMenu(expanded = uiFontMenu, onDismissRequest = { uiFontMenu = false }) {
                            listOf(
                                "system" to stringResource(R.string.font_system),
                                "rounded" to stringResource(R.string.font_rounded),
                                "serif" to stringResource(R.string.font_serif),
                            ).forEach { (preset, label) ->
                                DropdownMenuItem(
                                    text = { Text(label) },
                                    onClick = { viewModel.setUiFontPreset(preset); uiFontMenu = false },
                                )
                            }
                        }
                    }
                    Box(Modifier.weight(1f)) {
                        OutlinedButton(
                            onClick = { codeFontMenu = true },
                            modifier = Modifier.fillMaxWidth().testTag("appearance_code_font_button"),
                        ) {
                            val label = stringResource(if (state.codeFontPreset == "serifMono") R.string.font_serif_mono else R.string.font_system_mono)
                            Text(stringResource(R.string.code_font_value, label), maxLines = 1)
                        }
                        DropdownMenu(expanded = codeFontMenu, onDismissRequest = { codeFontMenu = false }) {
                            listOf(
                                "systemMono" to stringResource(R.string.font_system_mono),
                                "serifMono" to stringResource(R.string.font_serif_mono),
                            ).forEach { (preset, label) ->
                                DropdownMenuItem(
                                    text = { Text(label) },
                                    onClick = { viewModel.setCodeFontPreset(preset); codeFontMenu = false },
                                )
                            }
                        }
                    }
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.text_size), modifier = Modifier.weight(1f))
                    TextButton(
                        onClick = { viewModel.setFontScale(state.fontScale - 0.05f) },
                        enabled = state.fontScale > 0.851f,
                        modifier = Modifier.testTag("appearance_font_decrease"),
                    ) { Text("A−") }
                    Text(
                        "${(state.fontScale * 100).roundToInt()}%",
                        style = MaterialTheme.typography.labelLarge,
                        modifier = Modifier.testTag("appearance_font_scale"),
                    )
                    TextButton(
                        onClick = { viewModel.setFontScale(state.fontScale + 0.05f) },
                        enabled = state.fontScale < 1.349f,
                        modifier = Modifier.testTag("appearance_font_increase"),
                    ) { Text("A+") }
                }
                Card(
                    modifier = Modifier.fillMaxWidth().testTag("appearance_preview"),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    ),
                ) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(stringResource(R.string.chat_preview), style = MaterialTheme.typography.labelLarge)
                        Surface(
                            color = MaterialTheme.colorScheme.primaryContainer,
                            shape = RoundedCornerShape(14.dp),
                            modifier = Modifier.align(Alignment.End),
                        ) {
                            Text(stringResource(R.string.chat_preview_user), Modifier.padding(horizontal = 12.dp, vertical = 8.dp))
                        }
                        Text(stringResource(R.string.chat_preview_assistant), style = MaterialTheme.typography.bodyMedium)
                        Surface(
                            color = MaterialTheme.colorScheme.surfaceVariant,
                            shape = RoundedCornerShape(8.dp),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                "git status --short",
                                Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = codeFontFamily,
                            )
                        }
                    }
                }
                TextButton(
                    onClick = viewModel::resetAppearance,
                    modifier = Modifier.testTag("appearance_reset"),
                ) { Text(stringResource(R.string.restore_default_appearance)) }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.keep_screen_awake))
                        Text(stringResource(R.string.keep_screen_awake_detail), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(checked = state.keepScreenOn, onCheckedChange = viewModel::setKeepScreenOn)
                }
                Text(stringResource(R.string.language), style = MaterialTheme.typography.labelLarge)
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(
                        "system" to stringResource(R.string.language_system),
                        "en" to stringResource(R.string.language_english),
                        "zh-CN" to stringResource(R.string.language_chinese),
                    ).forEach { (tag, label) ->
                        if (state.languageTag == tag) Button(onClick = { }) { Text(label) }
                        else OutlinedButton(onClick = { viewModel.setLanguageTag(tag) }, enabled = Build.VERSION.SDK_INT >= 33) { Text(label) }
                    }
                }
                }
            }
            item {
                SettingsGroupCard {
                Text(stringResource(R.string.voice_input), style = MaterialTheme.typography.titleMedium)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (state.voiceMode == "codex") Button(onClick = { }) { Text(stringResource(R.string.voice_mac_codex)) }
                    else OutlinedButton(onClick = { viewModel.setVoiceMode("codex") }) { Text(stringResource(R.string.voice_mac_codex)) }
                    if (state.voiceMode == "device") Button(onClick = { }) { Text(stringResource(R.string.voice_on_device)) }
                    else OutlinedButton(onClick = { viewModel.setVoiceMode("device") }, enabled = state.deviceSpeechAvailable) { Text(stringResource(R.string.voice_on_device)) }
                }
                Text(
                    stringResource(if (state.voiceMode == "device") R.string.voice_device_detail else R.string.voice_mac_detail),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (!state.deviceSpeechAvailable) Text(stringResource(R.string.voice_device_unavailable), style = MaterialTheme.typography.labelSmall)
                }
            }
            item {
                HorizontalDivider()
                Spacer(Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.ai_usage), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                    IconButton(onClick = viewModel::refreshUsage, enabled = !state.usageLoading) { Icon(Icons.Filled.Refresh, stringResource(R.string.refresh_usage)) }
                }
                if (state.usageLoading) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                val usage = state.rateLimits
                if (usage == null) Text(stringResource(R.string.usage_unavailable), style = MaterialTheme.typography.bodySmall)
                else {
                    usage.planType?.let { Text(stringResource(R.string.plan_value, it), style = MaterialTheme.typography.labelLarge) }
                    usage.primaryUsedPercent?.let { used ->
                        Text(stringResource(R.string.usage_window_remaining, usage.primaryWindowDurationMinutes ?: 300, (100.0 - used).coerceIn(0.0, 100.0).toInt()))
                    }
                    usage.secondaryUsedPercent?.let { used ->
                        Text(stringResource(R.string.usage_window_remaining, usage.secondaryWindowDurationMinutes ?: 10_080, (100.0 - used).coerceIn(0.0, 100.0).toInt()))
                    }
                    usage.unavailableReason?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                }
            }
            item {
                HorizontalDivider()
                Spacer(Modifier.height(8.dp))
                Text(stringResource(R.string.legal_and_support), style = MaterialTheme.typography.titleMedium)
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    TextButton(onClick = { legalDocument = "privacy" }) { Text(stringResource(R.string.privacy)) }
                    TextButton(onClick = { legalDocument = "terms" }) { Text(stringResource(R.string.terms)) }
                    TextButton(
                        onClick = { legalDocument = "licenses" },
                        modifier = Modifier.testTag("open_source_licenses_button"),
                    ) { Text(stringResource(R.string.open_source_licenses)) }
                    TextButton(onClick = { legalDocument = "support" }) { Text(stringResource(R.string.support)) }
                }
            }
            item {
                Text(stringResource(R.string.artifact_preview), style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = artifactPath,
                    onValueChange = { artifactPath = it },
                    label = { Text(stringResource(R.string.authorized_mac_path)) },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
                Spacer(Modifier.height(8.dp))
                OutlinedButton(onClick = { viewModel.previewFile(artifactPath) }, enabled = artifactPath.isNotBlank() && !state.filePreviewLoading) {
                    if (state.filePreviewLoading) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else Text(stringResource(R.string.preview_action))
                }
            }
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.saved_macs), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                    TextButton(onClick = viewModel::prepareNewProfile) { Text(stringResource(R.string.add_mac)) }
                }
            }
            items(state.profiles, key = { "profile-${it.id}" }) { profile ->
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(14.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(profile.displayName, fontWeight = FontWeight.Medium)
                                Text(profile.endpoint, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall)
                            }
                            if (profile.id == state.activeProfileId) Text(stringResource(R.string.current), color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelMedium)
                        }
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                            TextButton(onClick = { renameProfileId = profile.id; renameProfileValue = profile.displayName }, enabled = !state.loading) { Text(stringResource(R.string.rename_action)) }
                            if (profile.id != state.activeProfileId) {
                                TextButton(onClick = { forgetProfileId = profile.id }, enabled = !state.loading) { Text(stringResource(R.string.forget_action)) }
                                TextButton(onClick = { viewModel.switchProfile(profile.id) }, enabled = !state.loading) { Text(stringResource(R.string.switch_action)) }
                            }
                        }
                    }
                }
            }
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.capabilities), style = MaterialTheme.typography.titleMedium)
                        Text(
                            pluralStringResource(R.plurals.capabilities_summary, state.skills.size, state.skills.size, state.plugins.size),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    IconButton(onClick = viewModel::refreshComposerCapabilities, enabled = !state.capabilitiesLoading) {
                        Icon(Icons.Filled.Refresh, stringResource(R.string.refresh_capabilities))
                    }
                }
                state.plugins.forEach { plugin ->
                    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.Top) {
                        Text(if (plugin.enabled) "●" else "○", color = if (plugin.enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline)
                        Spacer(Modifier.width(8.dp))
                        Column(Modifier.weight(1f)) {
                            Text(plugin.name, fontWeight = FontWeight.Medium)
                            val detail = listOfNotNull(plugin.marketplace.takeIf(String::isNotBlank), plugin.description).joinToString(" · ")
                            if (detail.isNotBlank()) Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
            item {
                HorizontalDivider()
                Spacer(Modifier.height(8.dp))
                OutlinedButton(onClick = { viewModel.browseDirectory("") }, enabled = !state.workspaceLoading, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Folder, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.open_workspace_on_mac))
                }
                Spacer(Modifier.height(12.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.worktrees), style = MaterialTheme.typography.titleMedium)
                        Text(
                            "Create and safely clean isolated project workspaces",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    IconButton(onClick = viewModel::refreshWorktrees, enabled = !state.worktreeLoading) {
                        Icon(Icons.Filled.Refresh, stringResource(R.string.refresh_worktrees))
                    }
                }
                OutlinedTextField(
                    value = worktreeName,
                    onValueChange = { worktreeName = it },
                    label = { Text(stringResource(R.string.name_optional)) },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = worktreeBase,
                    onValueChange = { worktreeBase = it },
                    label = { Text(stringResource(R.string.base_branch_optional)) },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
                state.worktreeBranches?.branches?.takeIf(List<*>::isNotEmpty)?.let { branches ->
                    Spacer(Modifier.height(6.dp))
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(branches, key = { "branch-${it.kind}-${it.name}" }) { branch ->
                            FilterChip(
                                selected = worktreeBase == branch.name,
                                onClick = { worktreeBase = branch.name },
                                label = {
                                    Text(
                                        buildString {
                                            append(branch.name)
                                            if (branch.isDefault) append(" · default")
                                            else if (branch.isCurrent) append(" · current")
                                        },
                                    )
                                },
                            )
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = {
                            viewModel.createWorktree(worktreeName, worktreeBase)
                            worktreeName = ""
                            worktreeBase = ""
                        },
                        enabled = state.selectedProjectId != null && !state.worktreeLoading,
                    ) { Text(stringResource(R.string.create_action)) }
                    OutlinedButton(onClick = viewModel::pruneWorktrees, enabled = !state.worktreeLoading) { Text(stringResource(R.string.prune_action)) }
                    OutlinedButton(onClick = viewModel::previewWorktreeCleanup, enabled = !state.worktreeLoading) { Text(stringResource(R.string.cleanup_action)) }
                }
                if (state.worktreeLoading) {
                    Spacer(Modifier.height(8.dp))
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                }
            }
            items(state.worktrees, key = { "worktree-${it.worktree.path}" }) { item ->
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(14.dp)) {
                        Text(item.workspace.name, fontWeight = FontWeight.Medium)
                        Text(item.worktree.path, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall)
                        Spacer(Modifier.height(6.dp))
                        Text(
                            listOfNotNull(
                                item.worktree.branch ?: item.worktree.base,
                                item.worktree.gitState,
                                "↑${item.worktree.ahead}",
                                "↓${item.worktree.behind}",
                            ).joinToString("  ·  "),
                            style = MaterialTheme.typography.labelMedium,
                            color = if (item.worktree.dirty) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                            TextButton(
                                onClick = { pendingWorktreeDelete = item.worktree.path },
                                enabled = !state.worktreeLoading,
                            ) { Text(stringResource(R.string.delete_action)) }
                        }
                    }
                }
            }
            }
            if (!settingsMode && inspectorSection == InspectorSection.Changes) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Git", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                    IconButton(onClick = viewModel::refreshGit, enabled = !state.gitLoading) { Icon(Icons.Filled.Refresh, stringResource(R.string.refresh_git)) }
                }
                val git = state.gitStatus
                Text(
                    if (git == null) {
                        stringResource(R.string.git_status_not_loaded)
                    } else if (!git.isRepository) {
                        stringResource(R.string.not_a_git_repository)
                    } else {
                        git.branch ?: stringResource(R.string.detached_head)
                    },
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                git?.diffStat?.takeIf(String::isNotBlank)?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            }
            state.gitStatus?.files?.let { files ->
                items(files, key = { "git-${it.path}" }) { file ->
                    Column(Modifier.fillMaxWidth()) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(file.code.ifBlank { "--" }, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                            Spacer(Modifier.width(8.dp))
                            Text(file.path, modifier = Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                            val availableActions = GitMutationPolicy.availableFileActions(file)
                            if (GitActionKind.Stage in availableActions) {
                                TextButton(onClick = { viewModel.gitAction(GitActionKind.Stage, file.path) }, enabled = !state.gitLoading) { Text(stringResource(R.string.stage_action)) }
                            }
                            if (GitActionKind.Revert in availableActions) {
                                TextButton(onClick = { pendingRevert = file.path }, enabled = !state.gitLoading) { Text(stringResource(R.string.discard_action)) }
                            }
                            if (GitActionKind.Unstage in availableActions) {
                                TextButton(onClick = { viewModel.gitAction(GitActionKind.Unstage, file.path) }, enabled = !state.gitLoading) { Text(stringResource(R.string.unstage_action)) }
                            }
                        }
                    }
                }
            }
            state.gitStatus?.unstagedDiff?.takeIf(String::isNotBlank)?.let { diff ->
                item {
                    GitHunksSection(
                        title = stringResource(R.string.unstaged_hunks),
                        diff = diff,
                        loading = state.gitLoading,
                        primaryLabel = stringResource(R.string.stage_hunk),
                        onPrimary = { viewModel.gitPatchAction(GitActionKind.StagePatch, it) },
                        destructiveLabel = stringResource(R.string.discard_hunk),
                        onDestructive = { pendingRevertPatch = it },
                    )
                }
            }
            state.gitStatus?.stagedDiff?.takeIf(String::isNotBlank)?.let { diff ->
                item {
                    GitHunksSection(
                        title = stringResource(R.string.staged_hunks),
                        diff = diff,
                        loading = state.gitLoading,
                        primaryLabel = stringResource(R.string.unstage_hunk),
                        onPrimary = { viewModel.gitPatchAction(GitActionKind.UnstagePatch, it) },
                    )
                }
            }
            if (state.gitStatus?.isRepository == true) {
                item {
                    OutlinedTextField(
                        value = commitMessage,
                        onValueChange = { commitMessage = it },
                        label = { Text(stringResource(R.string.commit_message)) },
                        modifier = Modifier.fillMaxWidth(),
                        maxLines = 3,
                    )
                    Spacer(Modifier.height(8.dp))
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        OutlinedButton(onClick = { confirmPush = true }, enabled = !state.gitLoading) { Text(stringResource(R.string.push_action)) }
                        Spacer(Modifier.width(8.dp))
                        OutlinedButton(
                            onClick = { confirmQuickPublish = true },
                            enabled = !state.gitLoading && commitMessage.isNotBlank() && state.gitStatus.files.isNotEmpty(),
                        ) { Text(stringResource(R.string.quick_publish)) }
                        Spacer(Modifier.width(8.dp))
                        Button(
                            onClick = { viewModel.gitCommit(commitMessage); commitMessage = "" },
                            enabled = !state.gitLoading && commitMessage.isNotBlank() && state.gitStatus.files.any { it.staged },
                        ) { Text(stringResource(R.string.commit_action)) }
                    }
                }
                item {
                    HorizontalDivider()
                    Spacer(Modifier.height(10.dp))
                    Text(stringResource(R.string.pull_request), style = MaterialTheme.typography.titleMedium)
                    val pr = state.pullRequestStatus
                    if (pr?.exists == true) {
                        Text("#${pr.number ?: "?"} ${pr.title.orEmpty()} · ${pr.state.orEmpty()}", style = MaterialTheme.typography.bodySmall)
                        pr.reviewDecision?.let { Text(stringResource(R.string.review_merge_value, it, pr.mergeStateStatus.orEmpty()), style = MaterialTheme.typography.labelSmall) }
                        val url = pr.url ?: state.pullRequestUrl
                        if (url?.let { it.startsWith("https://") || it.startsWith("http://") } == true) {
                            TextButton(onClick = { runCatching { uriHandler.openUri(url) }.onFailure { viewModel.showError(couldNotOpenPullRequest) } }) { Text(stringResource(R.string.open_pull_request)) }
                        }
                    } else {
                        OutlinedTextField(pullRequestTitle, { pullRequestTitle = it }, label = { Text(stringResource(R.string.title_label)) }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                        Spacer(Modifier.height(8.dp))
                        OutlinedTextField(pullRequestBody, { pullRequestBody = it }, label = { Text(stringResource(R.string.description_label)) }, modifier = Modifier.fillMaxWidth(), minLines = 3, maxLines = 8)
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(stringResource(R.string.draft), modifier = Modifier.weight(1f))
                            Switch(pullRequestDraft, { pullRequestDraft = it })
                        }
                        Button(onClick = { confirmPullRequest = true }, enabled = !state.gitLoading && pullRequestTitle.isNotBlank()) { Text(stringResource(R.string.create_pull_request)) }
                    }
                }
                state.testFlightStatus?.let { testFlight ->
                    item {
                        HorizontalDivider()
                        Spacer(Modifier.height(10.dp))
                        Text("TestFlight", style = MaterialTheme.typography.titleMedium)
                        Text(testFlight.capability.reason, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        testFlight.job?.let { job ->
                            Text(stringResource(R.string.release_value, job.state), style = MaterialTheme.typography.labelLarge)
                            job.output?.takeIf(String::isNotBlank)?.let { Text(it.takeLast(4_000), style = MaterialTheme.typography.bodySmall, fontFamily = codeFontFamily) }
                        }
                        OutlinedTextField(whatToTest, { whatToTest = it }, label = { Text(stringResource(R.string.what_to_test)) }, modifier = Modifier.fillMaxWidth(), maxLines = 5)
                        Button(
                            onClick = { confirmTestFlight = true },
                            enabled = testFlight.capability.available && testFlight.job?.state != "running" && whatToTest.isNotBlank() && !state.gitLoading,
                        ) { Text(stringResource(R.string.publish_testflight)) }
                    }
                }
                item {
                    HorizontalDivider()
                    Spacer(Modifier.height(10.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.workspace_actions), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                        IconButton(onClick = viewModel::refreshInspectorCapabilities, enabled = !state.commandActionLoading) { Icon(Icons.Filled.Refresh, stringResource(R.string.refresh_actions)) }
                    }
                    if (state.commandActions.isEmpty()) Text(stringResource(R.string.no_workspace_actions), style = MaterialTheme.typography.bodySmall)
                }
                items(state.commandActions, key = { "action-${it.id}" }) { action ->
                    Card(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(12.dp)) {
                            Text(action.name, fontWeight = FontWeight.Medium)
                            Text(action.displayCommand, style = MaterialTheme.typography.bodySmall, fontFamily = codeFontFamily)
                            Text("${action.workingDir} · ${action.timeoutSeconds}s", style = MaterialTheme.typography.labelSmall)
                            TextButton(
                                onClick = {
                                    if (action.requiresConfirmation) pendingCommandAction = action.id
                                    else viewModel.runCommandAction(action.id, false)
                                },
                                enabled = !state.commandActionLoading,
                            ) { Text(stringResource(R.string.run_action)) }
                        }
                    }
                }
            }
            }
            if (!settingsMode && inspectorSection == InspectorSection.Activity) {
                item {
                    Row(
                        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        InspectorActivityMode.entries.forEach { mode ->
                            FilterChip(
                                selected = activityMode == mode,
                                onClick = { activityMode = mode },
                                label = { Text(stringResource(mode.labelRes)) },
                                modifier = Modifier.testTag(mode.testTag),
                            )
                        }
                    }
                }
                if (activityMode == InspectorActivityMode.Entries) {
                    if (activityGroups.isEmpty()) {
                        item {
                            Text(
                                stringResource(R.string.inspector_no_activity),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    } else {
                        items(activityGroups, key = { "inspector-activity-${it.key}" }) { group ->
                            ActivityTimelineCard(group.messages, compact = true)
                        }
                    }
                } else {
                    item {
                        Text(
                            stringResource(R.string.inspector_output_redacted),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.height(8.dp))
                        if (state.diagnosticLogs.isEmpty()) {
                            Text(stringResource(R.string.inspector_no_output), style = MaterialTheme.typography.bodyMedium)
                        } else {
                            Text(
                                state.diagnosticLogs.takeLast(80).joinToString("\n"),
                                Modifier.fillMaxWidth(),
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = codeFontFamily,
                            )
                        }
                    }
                }
            }
            if (settingsMode) {
            item {
                HorizontalDivider()
                Spacer(Modifier.height(10.dp))
                Text(stringResource(R.string.diagnostic_log), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.diagnostic_log_detail), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (state.diagnosticLogs.isNotEmpty()) {
                    Text(
                        state.diagnosticLogs.takeLast(40).joinToString("\n"),
                        Modifier.fillMaxWidth().heightIn(max = 240.dp).verticalScroll(rememberScrollState()),
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = codeFontFamily,
                    )
                    TextButton(onClick = {
                        val share = diagnosticLogShareIntent(diagnosticLogSubject, state.diagnosticLogs)
                        runCatching {
                            context.startActivity(Intent.createChooser(share, diagnosticLogChooserTitle))
                        }
                            .onFailure { viewModel.showError(exportLogFailed) }
                    }, modifier = Modifier.testTag("export_diagnostic_log")) {
                        Text(stringResource(R.string.export_log))
                    }
                } else Text(stringResource(R.string.no_diagnostic_events), style = MaterialTheme.typography.bodySmall)
            }
            }
        }
    }
}

@Composable
internal fun DirectoryBrowserEntry(
    entry: DirectoryEntry,
    onBrowse: (String) -> Unit,
    onOpen: (String) -> Unit,
    onPreview: (String) -> Unit,
) {
    val primaryEnabled = when {
        entry.isDir -> entry.canBrowse || entry.canOpen
        else -> entry.canPreview
    }
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(
            onClick = {
                when {
                    entry.isDir && entry.canBrowse -> onBrowse(entry.path)
                    entry.isDir && entry.canOpen -> onOpen(entry.path)
                    !entry.isDir && entry.canPreview -> onPreview(entry.path)
                }
            },
            enabled = primaryEnabled,
            modifier = Modifier.weight(1f).testTag("directory_entry_${entry.path}"),
        ) {
            Icon(
                if (entry.isDir) Icons.Filled.Folder else Icons.Filled.AttachFile,
                contentDescription = null,
            )
            Spacer(Modifier.width(8.dp))
            Text(
                entry.name,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (entry.isDir && entry.canBrowse && entry.canOpen) {
            TextButton(
                onClick = { onOpen(entry.path) },
                modifier = Modifier.testTag("directory_open_${entry.path}"),
            ) {
                Text(stringResource(R.string.open_action))
            }
        }
    }
}

internal fun diagnosticLogShareIntent(subject: String, logs: List<String>): Intent =
    Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_SUBJECT, subject)
        putExtra(Intent.EXTRA_TEXT, DiagnosticLogPolicy.export(logs))
    }

@Composable
private fun InspectorContextSection(
    title: String,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(Modifier.fillMaxWidth()) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.semantics { heading() },
            )
            Spacer(Modifier.height(2.dp))
            content()
        }
    }
}

@Composable
private fun ContextInfoRow(
    icon: ImageVector,
    title: String,
    value: String,
    badge: String? = null,
    badgeColor: Color = MaterialTheme.colorScheme.onSurfaceVariant,
) {
    val codeFontFamily = LocalMimiCodeFontFamily.current
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(22.dp),
        )
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
            Text(
                value.ifBlank { "—" },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontFamily = codeFontFamily,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        badge?.takeIf(String::isNotBlank)?.let {
            Spacer(Modifier.width(8.dp))
            Text(it, style = MaterialTheme.typography.labelMedium, color = badgeColor, maxLines = 1)
        }
    }
}

@Composable
private fun SessionContextTaskRow(task: SessionContextTask) {
    val icon = when (task.kind) {
        "command" -> Icons.Filled.Code
        "file_change" -> Icons.Filled.Folder
        "web_search" -> Icons.Filled.Search
        "subagent" -> Icons.Filled.LaptopMac
        else -> Icons.Filled.Info
    }
    val status = contextStatusPresentation(task.status)
    ContextInfoRow(
        icon = icon,
        title = task.title,
        value = task.subtitle.orEmpty(),
        badge = status?.first,
        badgeColor = status?.second ?: MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun SessionContextSourceRow(source: SessionContextSource) {
    val title = stringResource(
        when (source.kind) {
            "session" -> R.string.context_original_source
            "thread" -> R.string.context_thread_source
            "fork" -> R.string.context_fork_source
            "project" -> R.string.context_project_source
            else -> R.string.context_sources
        },
    )
    ContextInfoRow(
        icon = if (source.kind == "project") Icons.Filled.Folder else Icons.Filled.Info,
        title = title,
        value = listOfNotNull(contextSourceLabel(source.label), source.subtitle?.takeIf(String::isNotBlank))
            .distinct().joinToString(" · "),
    )
}

private fun contextSourceLabel(raw: String): String = when (raw.trim().lowercase()) {
    "vscode", "vs code" -> "VS Code"
    "appserver", "app-server", "codex app-server" -> "app-server"
    "ipad", "iphone", "ios" -> "Mimi Remote"
    else -> raw
}

@Composable
private fun SessionContextSubagentRow(subagent: SessionContextSubagent) {
    val status = contextStatusPresentation(subagent.status)
    ContextInfoRow(
        icon = Icons.Filled.LaptopMac,
        title = subagent.displayName,
        value = subagent.role.orEmpty(),
        badge = status?.first,
        badgeColor = status?.second ?: MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun ContextEmptyRow(title: String) {
    Text(
        title,
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(vertical = 12.dp),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun contextStatusPresentation(status: String?): Pair<String, Color>? {
    val normalized = status.orEmpty().lowercase().replace("_", "").replace("-", "").replace(" ", "")
    return when (normalized) {
        "running", "started", "inprogress", "active" ->
            stringResource(R.string.status_running) to MaterialTheme.colorScheme.primary
        "completed", "complete", "success", "succeeded", "modified", "created" ->
            stringResource(R.string.context_status_complete) to MaterialTheme.colorScheme.primary
        "failed", "failure", "error", "systemerror" ->
            stringResource(R.string.context_status_failed) to MaterialTheme.colorScheme.error
        "waiting", "pending", "queued", "waitingforapproval", "waitingforinput" ->
            stringResource(R.string.context_status_waiting) to MaterialTheme.colorScheme.tertiary
        "idle", "notloaded", "history", "closed" ->
            stringResource(R.string.context_status_idle) to MaterialTheme.colorScheme.onSurfaceVariant
        "" -> null
        else -> status?.replace("_", " ")?.let { it to MaterialTheme.colorScheme.onSurfaceVariant }
    }
}

@Composable
private fun GitHunksSection(
    title: String,
    diff: String,
    loading: Boolean,
    primaryLabel: String,
    onPrimary: (String) -> Unit,
    destructiveLabel: String? = null,
    onDestructive: ((String) -> Unit)? = null,
) {
    val hunks = remember(diff) { GitPatchParser.parse(diff).take(100) }
    val codeFontFamily = LocalMimiCodeFontFamily.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall)
        if (hunks.isEmpty()) {
            Text(
                diff.take(40_000),
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                style = MaterialTheme.typography.bodySmall,
                fontFamily = codeFontFamily,
            )
        } else hunks.forEach { hunk ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(hunk.title, style = MaterialTheme.typography.labelMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(
                        hunk.preview.take(12_000),
                        modifier = Modifier.fillMaxWidth().heightIn(max = 220.dp).horizontalScroll(rememberScrollState()),
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = codeFontFamily,
                    )
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        if (destructiveLabel != null && onDestructive != null) {
                            TextButton(onClick = { onDestructive(hunk.patch) }, enabled = !loading) { Text(destructiveLabel, color = MaterialTheme.colorScheme.error) }
                        }
                        TextButton(onClick = { onPrimary(hunk.patch) }, enabled = !loading) { Text(primaryLabel) }
                    }
                }
            }
        }
    }
}

@Composable
internal fun OpenSourceLicensesDialog(
    projectLicense: String,
    notices: String,
    onDismiss: () -> Unit,
    onViewOnline: () -> Unit,
) {
    var projectLicenseExpanded by rememberSaveable { mutableStateOf(false) }
    val codeFontFamily = LocalMimiCodeFontFamily.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.open_source_licenses)) },
        text = {
            Column(
                modifier = Modifier
                    .heightIn(max = 560.dp)
                    .verticalScroll(rememberScrollState())
                    .testTag("open_source_licenses_dialog"),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(stringResource(R.string.mimi_project_license), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.project_license_summary), style = MaterialTheme.typography.bodyMedium)
                OutlinedButton(
                    onClick = { projectLicenseExpanded = !projectLicenseExpanded },
                    modifier = Modifier.testTag("toggle_project_license"),
                ) {
                    Text(stringResource(if (projectLicenseExpanded) R.string.hide_full_license else R.string.show_full_license))
                }
                if (projectLicenseExpanded) {
                    SelectionContainer {
                        Text(
                            projectLicense,
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = codeFontFamily,
                        )
                    }
                }
                HorizontalDivider()
                Text(stringResource(R.string.third_party_notices), style = MaterialTheme.typography.titleMedium)
                SelectionContainer {
                    Text(
                        notices,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = codeFontFamily,
                    )
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.close_action)) } },
        dismissButton = { TextButton(onClick = onViewOnline) { Text(stringResource(R.string.view_online)) } },
    )
}

private data class BundledLegalDocument(val title: String, val body: String, val url: String)

private fun legalDocumentContent(key: String, context: Context): BundledLegalDocument {
    val (title, asset, url) = when (key) {
        "privacy" -> Triple(
            context.getString(R.string.privacy),
            BundledLegalAssets.PrivacyPolicy,
            "https://github.com/gaixianggeng/mimi-remote/blob/main/docs/privacy-policy.md",
        )
        "terms" -> Triple(
            context.getString(R.string.terms),
            BundledLegalAssets.TermsOfUse,
            "https://github.com/gaixianggeng/mimi-remote/blob/main/docs/terms-of-use.md",
        )
        else -> Triple(
            context.getString(R.string.support),
            BundledLegalAssets.Support,
            "https://github.com/gaixianggeng/mimi-remote/blob/main/docs/support.md",
        )
    }
    val body = runCatching { BundledLegalAssets.read(context, asset) }
        .getOrElse { context.getString(R.string.legal_document_load_failed) }
    return BundledLegalDocument(title, body, url)
}

@Composable
private fun InspectorItem(icon: ImageVector, title: String, value: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(12.dp))
        Column {
            Text(title, style = MaterialTheme.typography.labelLarge)
            Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

internal fun appPermissionSettingsIntent(packageName: String): Intent = Intent(
    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
    Uri.fromParts("package", packageName, null),
).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

@Composable
internal fun LegacyConnectionImportDialog(
    link: Uri,
    onImport: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        modifier = Modifier.testTag("legacy_connection_import_dialog"),
        title = { Text(stringResource(R.string.legacy_link_title)) },
        text = {
            Column {
                Text(stringResource(R.string.legacy_link_warning))
                Spacer(Modifier.height(12.dp))
                Text(
                    link.getQueryParameter("endpoint").orEmpty(),
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.testTag("legacy_connection_endpoint"),
                )
                Spacer(Modifier.height(8.dp))
                Text(stringResource(R.string.legacy_link_review), style = MaterialTheme.typography.bodySmall)
            }
        },
        confirmButton = {
            TextButton(onClick = onImport, modifier = Modifier.testTag("legacy_connection_import")) {
                Text(stringResource(R.string.import_action))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, modifier = Modifier.testTag("legacy_connection_cancel")) {
                Text(stringResource(R.string.cancel_action))
            }
        },
    )
}

@Composable
internal fun PermissionRecoveryDialog(
    message: String,
    onDismiss: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        modifier = Modifier.testTag("permission_recovery_dialog"),
        title = { Text(stringResource(R.string.permission_recovery_title)) },
        text = { Text(message) },
        confirmButton = {
            TextButton(
                onClick = onOpenSettings,
                modifier = Modifier.testTag("permission_recovery_open_settings"),
            ) {
                Text(stringResource(R.string.open_app_settings))
            }
        },
        dismissButton = {
            TextButton(
                onClick = onDismiss,
                modifier = Modifier.testTag("permission_recovery_cancel"),
            ) {
                Text(stringResource(R.string.cancel_action))
            }
        },
    )
}

@Composable
private fun SettingsGroupCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        ),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(MimiSpacing.md),
            verticalArrangement = Arrangement.spacedBy(MimiSpacing.sm),
            content = content,
        )
    }
}

@Composable
internal fun PaneHeader(
    title: String,
    subtitle: String,
    onBack: (() -> Unit)? = null,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = MimiSpacing.xs, vertical = MimiSpacing.xxs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        onBack?.let {
            IconButton(
                onClick = it,
                modifier = Modifier.testTag("back_to_session_list"),
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    stringResource(R.string.back_to_sessions),
                )
            }
        }
        Column(Modifier.weight(1f).padding(horizontal = MimiSpacing.sm, vertical = MimiSpacing.xs)) {
            Text(
                title,
                style = if (onBack == null) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = if (onBack == null) 1 else 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.semantics { heading() },
            )
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
}

private fun visibleThreads(state: MainUiState): List<AgentThread> {
    val query = state.sessionSearchQuery.trim()
    val visible = if (query.isEmpty()) state.threads else {
        val local = state.threads.filter {
            it.preview.contains(query, ignoreCase = true) || it.cwd.contains(query, ignoreCase = true)
        }
        (local + state.sessionSearchResults.map { it.thread }).distinctBy { it.id }
    }
    return visible.sortedByDescending { it.id in state.pinnedThreadIds }
}
