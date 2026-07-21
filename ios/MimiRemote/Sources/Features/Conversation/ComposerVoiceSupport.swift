import AVFoundation
import AudioToolbox
import SwiftUI
import UIKit

struct VoiceMicButton: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isPreparing: Bool
    let isRecording: Bool
    let isTranscribing: Bool
    let usesRealtimeTranscription: Bool
    let onTap: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Button(action: onTap) {
            Group {
                if isPreparing || isTranscribing {
                    ProgressView()
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                }
            }
            .foregroundStyle(tokens.primaryAction)
            .frame(width: 44, height: 44)
            .background(tokens.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .modifier(
                ComposerFlatControlSurface(
                    tokens: tokens,
                    cornerRadius: 12,
                    isEmphasized: false
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ComposerPressButtonStyle(reduceMotion: reduceMotion))
        .disabled(isPreparing || isTranscribing)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
    }

    private var accessibilityTitle: String {
        if isRecording {
            return L10n.text("ui.stop_recording")
        }
        if isPreparing {
            return L10n.text("ui.preparing_microphone")
        }
        return isTranscribing ? L10n.text("ui.transcribing_speech") : L10n.text("ui.start_voice_input")
    }

    private var accessibilityValue: String {
        if isRecording {
            return L10n.text("ui.recording")
        }
        if isPreparing {
            return L10n.text("ui.preparing")
        }
        return isTranscribing ? L10n.text("ui.transcribing") : L10n.text("ui.not_started")
    }

    private var accessibilityHint: String {
        if isRecording {
            return usesRealtimeTranscription
                ? L10n.text("ui.tap_to_stop_apple_voice_input")
                : L10n.text("ui.tap_to_stop_recording_and_start_transcribing")
        }
        return usesRealtimeTranscription
            ? L10n.text("ui.tap_to_start_apple_realtime_voice_input")
            : L10n.text("ui.click_to_start_recording")
    }
}

struct ComposerPressButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // 平铺控件只用明度变化响应触摸，不再通过缩放和下沉模拟实体键程。
            .opacity(configuration.isPressed ? 0.68 : 1)
            .animation(
                .easeOut(duration: reduceMotion ? 0 : 0.08),
                value: configuration.isPressed
            )
    }
}

/// Composer 控件统一使用实色和细边界分组，层级来自布局关系而不是高光或投影。
struct ComposerFlatControlSurface: ViewModifier {
    let tokens: ThemeTokens
    let cornerRadius: CGFloat
    let isEmphasized: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var borderColor: Color {
        if isEmphasized {
            return .clear
        }
        return tokens.border.opacity(tokens.resolvedScheme == .light ? 0.62 : 0.82)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: 0.75)
            }
    }
}

struct VoiceWaveformLevelMapping {
    static let noiseGate: CGFloat = 0.035
    static let responseCurve: Double = 0.42
    static let audibleFloor: CGFloat = 0.10

    static func visualLevel(for rawLevel: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, rawLevel))
        guard clamped > noiseGate else {
            return 0
        }
        // 低音量区做更明显的视觉增益：静音仍被 gate 压住，一开口就能看到清楚的上下起伏。
        let normalized = (clamped - noiseGate) / (1 - noiseGate)
        let boosted = pow(Double(normalized), responseCurve)
        let lifted = audibleFloor + CGFloat(boosted) * (1 - audibleFloor)
        return max(0, min(1, lifted))
    }
}

struct VoiceWaveformSampleShape {
    static let barCount = 22

    static func samples(for rawLevel: CGFloat, count: Int = Self.barCount) -> [CGFloat] {
        let clamped = max(0, min(1, rawLevel))
        guard count > 0 else {
            return []
        }
        guard VoiceWaveformLevelMapping.visualLevel(for: clamped) > 0 else {
            return Array(repeating: 0, count: count)
        }

        return (0..<count).map { index in
            // 固定条位生成一个中间波峰：每一帧只反映“此刻声音大小”，不再把历史音量往前滚动。
            let progress = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
            let distanceFromCenter = abs(progress - 0.5) * 2
            let bell = CGFloat(exp(-pow(Double(distanceFromCenter / 0.48), 2)))
            let shoulder: CGFloat = 0.16
            return min(1, clamped * (shoulder + bell * (1 - shoulder)))
        }
    }
}

struct VoiceWaveformView: View {
    @ObservedObject var meter: VoiceLevelMeter
    let isActive: Bool
    let colors: [Color]

    var body: some View {
        GeometryReader { proxy in
            let samples = Array(meter.samples.enumerated())
            let spacing: CGFloat = 3
            let count = max(samples.count, 1)
            let availableWidth = max(0, proxy.size.width - spacing * CGFloat(max(count - 1, 0)))
            let barWidth = max(2.7, min(5.2, availableWidth / CGFloat(count)))

            // 用一条铺满整个宽度的横向渐变，再用竖条形状做 mask：每根条只露出它所在位置的渐变色，
            // 于是整组波形从左到右是平滑的主题渐变，而不是每根单独着色拼出来的硬边。
            LinearGradient(
                colors: colors,
                startPoint: .leading,
                endPoint: .trailing
            )
            .mask {
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(samples, id: \.offset) { index, level in
                        RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                            .frame(width: barWidth, height: barHeight(index: index, level: level, maxHeight: proxy.size.height))
                            .animation(.easeOut(duration: 0.07), value: level)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .opacity(isActive ? 1 : 0.45)
        }
    }

    private func barHeight(index: Int, level: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 3
        let usable = max(0, maxHeight - minHeight)
        guard isActive else {
            // 静止时给一点高低错落，避免看起来像坏掉的直线。
            return minHeight + (index.isMultiple(of: 2) ? 3 : 0)
        }
        let visibleLevel = VoiceWaveformLevelMapping.visualLevel(for: level)
        return minHeight + visibleLevel * usable
    }
}

@MainActor
final class VoiceLevelMeter: ObservableObject {
    static let barCount = VoiceWaveformSampleShape.barCount

    @Published private(set) var samples: [CGFloat] = Array(repeating: 0, count: VoiceLevelMeter.barCount)
    private var previousLevel: CGFloat = 0

    func push(_ level: CGFloat) {
        let clamped = max(0, min(1, level))
        let risingDelta = max(0, clamped - previousLevel)
        // 只对“正在变大”的瞬间做一点 attack 增强；不保留历史队列，所以视觉不会横向滚动。
        let emphasizedLevel = min(1, clamped + risingDelta * 0.35)
        samples = VoiceWaveformSampleShape.samples(for: emphasizedLevel, count: Self.barCount)
        previousLevel = clamped
    }

    func prepareForRecording() {
        // 录音器刚启动但还没检测到声音时保持平线；一开口再按当前音量抬起中心波峰。
        samples = Array(repeating: 0, count: Self.barCount)
        previousLevel = 0
    }

    func reset() {
        samples = Array(repeating: 0, count: VoiceLevelMeter.barCount)
        previousLevel = 0
    }
}

@MainActor
enum VoiceHaptics {
    private static let recordingStartGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private static let recordingReadyGenerator = UINotificationFeedbackGenerator()

    static func prepareRecordingStarted() {
        recordingStartGenerator.prepare()
        recordingReadyGenerator.prepare()
    }

    static func recordingStarted() {
        // 语音输入的唯一震动锚点：只有录音器已经开始采样后才震动。
        // 用户感受到这次反馈，就可以立即开口。
        recordingStartGenerator.impactOccurred(intensity: 1.0)
        recordingReadyGenerator.notificationOccurred(.success)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        recordingStartGenerator.prepare()
        recordingReadyGenerator.prepare()
    }
}

struct ManualSkillInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var path = ""

    let onAdd: (CodexAppServerUserInput) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.text("ui.skill_name"), text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.text("ui.path_within_allowlist"), text: $path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle(L10n.text("ui.add_skills_manually"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.add")) {
                        if let input {
                            onAdd(input)
                            dismiss()
                        }
                    }
                    .disabled(input == nil)
                }
            }
        }
    }

    private var input: CodexAppServerUserInput? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !value.isEmpty else {
            return nil
        }
        return .skill(name: title, path: value)
    }
}

struct AdvancedTurnOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CodexAppServerTurnOptions
    @State private var configText: String
    @State private var outputSchemaText: String
    @State private var errorMessage: String?

    let onSave: (CodexAppServerTurnOptions) -> Void

    init(options: CodexAppServerTurnOptions, onSave: @escaping (CodexAppServerTurnOptions) -> Void) {
        _draft = State(initialValue: options)
        _configText = State(initialValue: Self.jsonText(from: options.config))
        _outputSchemaText = State(initialValue: Self.jsonText(from: options.outputSchema))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("ui.model")) {
                    TextField(L10n.text("ui.runtime_provider"), text: optionalStringBinding(\.runtimeProvider))
                    TextField(L10n.text("ui.model"), text: optionalStringBinding(\.model))
                    TextField(L10n.text("ui.model_provider"), text: optionalStringBinding(\.modelProvider))
                    TextField(L10n.text("ui.service_name"), text: optionalStringBinding(\.serviceName))
                }

                Section(L10n.text("ui.thread_source")) {
                    TextField(L10n.text("ui.session_start_source"), text: optionalStringBinding(\.sessionStartSource))
                    TextField(L10n.text("ui.thread_source"), text: optionalStringBinding(\.threadSource))
                }

                Section(L10n.text("ui.instructions")) {
                    TextEditor(text: optionalStringBinding(\.baseInstructions))
                        .frame(minHeight: 90)
                    TextEditor(text: optionalStringBinding(\.developerInstructions))
                        .frame(minHeight: 90)
                }

                Section("JSON") {
                    TextEditor(text: $configText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 110)
                    TextEditor(text: $outputSchemaText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 130)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.text("ui.advanced_options"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(L10n.text("ui.clear")) { clearAdvancedOptions() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.application")) { apply() }
                }
            }
        }
    }

    private func optionalStringBinding(_ keyPath: WritableKeyPath<CodexAppServerTurnOptions, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                draft[keyPath: keyPath] = trimmed.isEmpty ? nil : value
            }
        )
    }

    private func apply() {
        do {
            draft.config = try parseOptionalJSON(configText, requireObject: true, label: "config")
            draft.outputSchema = try parseOptionalJSON(outputSchemaText, requireObject: false, label: "outputSchema")
            onSave(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearAdvancedOptions() {
        draft.runtimeProvider = nil
        draft.modelProvider = nil
        draft.config = nil
        draft.baseInstructions = nil
        draft.developerInstructions = nil
        draft.outputSchema = nil
        draft.serviceName = nil
        draft.sessionStartSource = nil
        draft.threadSource = nil
        configText = ""
        outputSchemaText = ""
        errorMessage = nil
    }

    private func parseOptionalJSON(_ text: String, requireObject: Bool, label: String) throws -> CodexAppServerJSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let value = try JSONDecoder().decode(CodexAppServerJSONValue.self, from: Data(trimmed.utf8))
        if requireObject, value.objectValue == nil {
            throw AdvancedTurnOptionsError.invalidJSON(label + L10n.text("ui.must_be_a_json_object"))
        }
        return value
    }

    private static func jsonText(from value: CodexAppServerJSONValue?) -> String {
        guard let value else {
            return ""
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum AdvancedTurnOptionsError: LocalizedError {
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let message):
            return message
        }
    }
}

@MainActor
final class VoiceInputController: NSObject, ObservableObject {
    @Published private(set) var isPreparing = false
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?

    // 音量计单独成对象：波形按 buffer 频率刷新，只让 VoiceWaveformView 订阅它，
    // 避免高频 level 变化把整个 ComposerView 一起重绘。
    let levelMeter = VoiceLevelMeter()

    private var recorder: AVAudioRecorder?
    private var meteringTask: Task<Void, Never>?
    private var finishHandler: ((VoiceRecordingResult?) -> Void)?
    private var recordingURL: URL?
    private var startRequestID: UUID?
    private var pressStartedAt: Date?
    private var recordingStartedAt: Date?
    private var activeProvider: VoiceInputProvider?
    private var appleSession: AppleSpeechTranscriptionSession?
    private var appleLifecycleTask: Task<Void, Never>?
    private var appleFinishHandler: (() -> Void)?

    func start(onFinish: @escaping (VoiceRecordingResult?) -> Void) {
        guard activeProvider == nil, !isRecording, finishHandler == nil else {
            return
        }
        let requestID = UUID()
        activeProvider = .codex
        startRequestID = requestID
        finishHandler = onFinish
        pressStartedAt = Date()
        recordingStartedAt = nil
        errorMessage = nil
        noticeMessage = nil

        switch recordPermissionState() {
        case .undetermined:
            Task {
                // 首次系统权限弹窗可能吞掉按住手势结束事件；授权后不自动接着录，
                // 让用户重新按住一次，保证 UI 状态和真实录音起点一致。
                let granted = await requestRecordPermission()
                guard startRequestID == requestID else {
                    return
                }
                if granted {
                    noticeMessage = L10n.text("ui.the_microphone_is_on_please_press_and_hold")
                } else {
                    errorMessage = L10n.text("ui.microphone_permission_is_not_enabled_please_allow_it")
                }
                finish(fileURL: nil)
            }
            return
        case .denied:
            errorMessage = L10n.text("ui.microphone_permission_is_not_enabled_please_allow_it")
            finish(fileURL: nil)
            return
        case .granted:
            break
        }

        isPreparing = true
        VoiceHaptics.prepareRecordingStarted()

        Task {
            // 按住说话时权限弹窗可能晚于松手返回；用 requestID 防止松手后又启动录音。
            guard await requestRecordPermission() else {
                guard startRequestID == requestID else {
                    return
                }
                errorMessage = L10n.text("ui.microphone_permission_is_not_enabled")
                finish(fileURL: nil)
                return
            }
            guard startRequestID == requestID else {
                return
            }
            do {
                try startRecording()
            } catch {
                guard startRequestID == requestID else {
                    return
                }
                errorMessage = error.localizedDescription
                finish(fileURL: nil)
            }
        }
    }

    func startAppleTranscription(
        locale: Locale,
        onTranscript: @escaping @MainActor (String) -> Void,
        onFinish: @escaping () -> Void
    ) {
        guard activeProvider == nil, !isRecording, appleFinishHandler == nil else {
            return
        }
        let requestID = UUID()
        activeProvider = .apple
        startRequestID = requestID
        appleFinishHandler = onFinish
        errorMessage = nil
        noticeMessage = nil

        isPreparing = true
        VoiceHaptics.prepareRecordingStarted()
        let session = AppleSpeechTranscriptionSession()
        appleSession = session
        appleLifecycleTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                guard await requestRecordPermission() else {
                    guard startRequestID == requestID else { return }
                    errorMessage = L10n.text("ui.microphone_permission_is_not_enabled_please_allow_it")
                    await session.cancel()
                    completeAppleInteraction(notifyFinish: true)
                    return
                }
                guard startRequestID == requestID else {
                    await session.cancel()
                    return
                }
                try await session.start(
                    locale: locale,
                    onTranscript: { [weak self] transcript in
                        guard self?.activeProvider == .apple else { return }
                        onTranscript(transcript)
                    },
                    onLevel: { [weak self] level in
                        self?.levelMeter.push(level)
                    },
                    onFailure: { [weak self, weak session] error in
                        guard let self, let session, activeProvider == .apple else { return }
                        errorMessage = userFacingAppleSpeechError(error)
                        isPreparing = false
                        isRecording = false
                        levelMeter.reset()
                        appleLifecycleTask = Task { [weak self, weak session] in
                            await session?.cancel()
                            self?.completeAppleInteraction(notifyFinish: true)
                        }
                    }
                )
                guard startRequestID == requestID else {
                    await session.cancel()
                    return
                }
                appleLifecycleTask = nil
                isPreparing = false
                isRecording = true
                levelMeter.prepareForRecording()
                VoiceHaptics.recordingStarted()
            } catch is CancellationError {
                await session.cancel()
                if startRequestID == requestID {
                    completeAppleInteraction(notifyFinish: true)
                }
            } catch {
                await session.cancel()
                guard startRequestID == requestID else { return }
                errorMessage = userFacingAppleSpeechError(error)
                completeAppleInteraction(notifyFinish: true)
            }
        }
    }

    func stop() {
        if activeProvider == .apple {
            finishAppleTranscription()
            return
        }
        let shouldFinishImmediately = !isRecording && recorder == nil
        startRequestID = nil
        if shouldFinishImmediately {
            finish(fileURL: nil)
            return
        }
        finish(fileURL: recordingURL)
    }

    func cancel() {
        if activeProvider == .apple {
            cancelAppleTranscription(notifyFinish: false)
            return
        }
        let fileURL = recordingURL
        startRequestID = nil
        finishHandler = nil
        finish(fileURL: nil)
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func finishAppleTranscription() {
        guard activeProvider == .apple else { return }
        guard let session = appleSession else {
            completeAppleInteraction(notifyFinish: true)
            return
        }
        isPreparing = false
        isRecording = false
        levelMeter.reset()
        appleLifecycleTask?.cancel()
        appleLifecycleTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                try await session.finish()
            } catch is CancellationError {
                await session.cancel()
            } catch {
                errorMessage = userFacingAppleSpeechError(error)
                await session.cancel()
            }
            completeAppleInteraction(notifyFinish: true)
        }
    }

    private func cancelAppleTranscription(notifyFinish: Bool) {
        let session = appleSession
        appleLifecycleTask?.cancel()
        appleLifecycleTask = nil
        completeAppleInteraction(notifyFinish: notifyFinish)
        Task {
            await session?.cancel()
        }
    }

    private func completeAppleInteraction(notifyFinish: Bool) {
        let handler = appleFinishHandler
        appleFinishHandler = nil
        appleSession = nil
        appleLifecycleTask = nil
        activeProvider = nil
        startRequestID = nil
        isPreparing = false
        isRecording = false
        levelMeter.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if notifyFinish {
            handler?()
        }
    }

    private func userFacingAppleSpeechError(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return L10n.text("ui.apple_voice_input_is_currently_unavailable")
        }
        if error is AppleSpeechTranscriptionError {
            return message
        }
        return L10n.format("ui.apple_voice_input_failed", message)
    }

    func setErrorMessage(_ message: String?) {
        errorMessage = message
        if message != nil {
            noticeMessage = nil
        }
    }

    func setNoticeMessage(_ message: String?) {
        noticeMessage = message
        if message != nil {
            errorMessage = nil
        }
    }

    func prewarm() {
        // 进入对话页时先把音频会话 category 配好（不激活、不触发麦克风指示灯）。
        // 这样真正按住说话时只需 setActive + record，省掉冷启动里最慢的 category 切换，
        // 缩短“按下 → 看到红色波形”的可感知延迟。
        guard recorder == nil, !isRecording else {
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.duckOthers])
        VoiceHaptics.prepareRecordingStarted()
    }

    private func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw VoiceInputError.recordingFailed
        }
        self.recorder = recorder
        recordingURL = url
        recordingStartedAt = Date()
        levelMeter.prepareForRecording()
        isPreparing = false
        isRecording = true
        VoiceHaptics.recordingStarted()
        startMetering()
    }

    private func startMetering() {
        meteringTask?.cancel()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                // 45ms ≈ 22fps：比原来的 80ms 更跟手，波形随语音瞬态跳动而不是一卡一卡，
                // 同时仍远低于会让主线程吃紧的刷新频率。
                try? await Task.sleep(nanoseconds: 45_000_000)
                await MainActor.run {
                    guard let self, let recorder = self.recorder, self.isRecording else {
                        return
                    }
                    recorder.updateMeters()
                    let level = Self.normalizedPower(
                        average: recorder.averagePower(forChannel: 0),
                        peak: recorder.peakPower(forChannel: 0)
                    )
                    self.levelMeter.push(level)
                }
            }
        }
    }

    private func requestRecordPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func recordPermissionState() -> VoiceRecordPermissionState {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined:
                return .undetermined
            case .denied:
                return .denied
            case .granted:
                return .granted
            @unknown default:
                return .denied
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .undetermined:
                return .undetermined
            case .denied:
                return .denied
            case .granted:
                return .granted
            @unknown default:
                return .denied
            }
        }
    }

    private func finish(fileURL: URL?) {
        let now = Date()
        let pressDuration = pressStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let recordedDuration = max(
            recorder?.currentTime ?? 0,
            recordingStartedAt.map { now.timeIntervalSince($0) } ?? 0
        )
        recorder?.stop()
        recorder = nil
        meteringTask?.cancel()
        meteringTask = nil
        recordingURL = nil
        startRequestID = nil
        pressStartedAt = nil
        recordingStartedAt = nil
        isPreparing = false
        isRecording = false
        activeProvider = nil
        levelMeter.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let fileURL {
            finishHandler?(VoiceRecordingResult(
                fileURL: fileURL,
                recordedDuration: recordedDuration,
                pressDuration: pressDuration
            ))
        } else {
            finishHandler?(nil)
        }
        finishHandler = nil
    }

    nonisolated private static func normalizedPower(average: Float, peak: Float) -> CGFloat {
        // 以峰值为主、平均值兜底：峰值跟住人声爆破音，平均值避免纯底噪把波形误拉高。
        // 映射区间略收紧到 [-50, -4] dBFS，轻声会更早动起来，正常说话会明显上下波动。
        let floorDB: Float = -50
        let ceilDB: Float = -4
        let blended = max(average + 2, peak - 4)
        let clamped = max(floorDB, min(ceilDB, blended))
        return CGFloat((clamped - floorDB) / (ceilDB - floorDB))
    }
}

struct VoiceRecordingResult {
    let fileURL: URL
    let recordedDuration: TimeInterval
    let pressDuration: TimeInterval
}

struct VoiceTranscriptionContext: Equatable {
    let id = UUID()
    let sessionID: SessionID?
}

struct RetryableVoiceTranscription: Identifiable {
    let id = UUID()
    let filename: String
    let contentType: String
    let audioData: Data
    let recordedDuration: TimeInterval
    let pressDuration: TimeInterval
    let sessionID: SessionID?
}

enum VoiceRecordPermissionState {
    case undetermined
    case denied
    case granted
}

enum VoiceInputError: LocalizedError {
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .recordingFailed:
            return L10n.text("ui.recording_startup_failed")
        }
    }
}
