import AVFoundation
import AppKit

/// The Quick toggles' camera mirror: a small window over every app that shows the camera as a mirror does, to check
/// yourself before a call. The camera turns off as soon as the window closes.
@MainActor @Observable
final class CameraMirror {
    private(set) var isOpen = false
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var session: AVCaptureSession?
    @ObservationIgnored private var starting: Task<Void, Error>?

    /// Opens the window, asking for camera access the first time, or closes it.
    func toggle() async throws {
        if isOpen { return close() }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .video) else { return }
        default: throw CommandFailure(message: "Allow StableBar under Camera in Privacy & Security to see yourself.")
        }
        guard let camera = AVCaptureDevice.default(for: .video) else { throw CommandFailure(message: "This Mac has no camera.") }
        let session = AVCaptureSession()
        session.addInput(try AVCaptureDeviceInput(device: camera))
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        let size = NSSize(width: 288, height: 180)
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let panel = NSPanel(contentRect: NSRect(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20, width: size.width,
                                                height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = CameraMirrorView(preview: preview) { [weak self] in self?.close() }
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
        self.panel = panel
        self.session = session
        isOpen = true
        // Starting the camera blocks for a moment, and closing waits for it to start before stopping it.
        nonisolated(unsafe) let running = session
        let start = Task { try await BlockingWork.run { running.startRunning() } }
        starting = start
        try await start.value
    }

    func close() {
        panel?.close()
        panel = nil
        isOpen = false
        guard let session else { return }
        self.session = nil
        nonisolated(unsafe) let stopping = session
        Task { [starting] in
            _ = await starting?.result
            try? await BlockingWork.run { stopping.stopRunning() }
        }
        starting = nil
    }
}

/// The camera mirror's window: the picture, with rounded corners, and a close button. A drag anywhere else moves it.
private final class CameraMirrorView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    private let onClose: () -> Void

    init(preview: AVCaptureVideoPreviewLayer, onClose: @escaping () -> Void) {
        self.preview = preview
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(preview)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!, target: self,
                             action: #selector(closeMirror))
        close.isBordered = false
        close.contentTintColor = .white
        close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        close.toolTip = "Close"
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)
        NSLayoutConstraint.activate([close.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                                     close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)])
    }

    required init?(coder: NSCoder) { fatalError("Not from a nib") }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        preview.frame = bounds
    }

    @objc private func closeMirror() { onClose() }
}
