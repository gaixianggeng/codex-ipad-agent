import AVFoundation
import SwiftUI
import UIKit

struct QRCodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scannerError: String?
    @State private var isCameraReady = false

    let onCode: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                QRCodeScannerView { value in
                    onCode(value)
                    dismiss()
                } onError: { message in
                    scannerError = message
                } onReady: {
                    isCameraReady = true
                }

                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 240, height: 240)
                    .allowsHitTesting(false)

                if !isCameraReady {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text("正在启动相机")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("如果系统弹出权限请求，请允许相机访问。")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.78))
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding()
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("扫码连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .alert("无法扫码", isPresented: Binding(
                get: { scannerError != nil },
                set: { newValue in
                    if !newValue {
                        scannerError = nil
                    }
                }
            )) {
                Button("好", role: .cancel) {
                    scannerError = nil
                    dismiss()
                }
            } message: {
                Text(scannerError ?? "")
            }
        }
    }
}

private struct QRCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void
    let onReady: () -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        QRCodeScannerViewController(onCode: onCode, onError: onError, onReady: onReady)
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
}

private final class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "CodexAgentPad.QRCodeScanner.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didReadCode = false

    private let onCode: (String) -> Void
    private let onError: (String) -> Void
    private let onReady: () -> Void

    init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void, onReady: @escaping () -> Void) {
        self.onCode = onCode
        self.onError = onError
        self.onReady = onReady
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        prepareCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    deinit {
        stopScanning()
    }

    private func prepareCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureSession()
                    } else {
                        self?.onError("没有相机权限，无法扫描二维码。")
                    }
                }
            }
        case .denied, .restricted:
            onError("没有相机权限，无法扫描二维码。")
        @unknown default:
            onError("当前设备不支持扫码连接。")
        }
    }

    private func configureSession() {
        guard previewLayer == nil else {
            startScanning()
            return
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
            onError("当前设备没有可用相机。")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard captureSession.canAddInput(input) else {
                onError("无法接入相机输入。")
                return
            }
            captureSession.addInput(input)
        } catch {
            onError("打开相机失败：\(error.localizedDescription)")
            return
        }

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            onError("当前相机不支持二维码扫描。")
            return
        }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        onReady()

        startScanning()
    }

    private func startScanning() {
        // AVCaptureSession 启停放到后台队列，避免设置页打开扫码时阻塞 SwiftUI 主线程。
        sessionQueue.async { [captureSession] in
            if !captureSession.isRunning {
                captureSession.startRunning()
            }
        }
    }

    private func stopScanning() {
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didReadCode,
              let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .first(where: { $0.type == .qr }),
              let value = object.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return
        }

        // 第一次读到二维码后立刻停扫，防止同一个码连续触发多次连接测试。
        didReadCode = true
        stopScanning()
        onCode(value)
    }
}
