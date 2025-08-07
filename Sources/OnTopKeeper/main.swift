import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import CoreMedia
import IOSurface

// MARK: - Selection Overlay
class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

class OverlayView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var startPoint = CGPoint.zero
    private var selectionRect = CGRect.zero
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        if selectionRect.width > 0 && selectionRect.height > 0 {
            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(rect: selectionRect).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            let border = NSBezierPath(rect: selectionRect)
            border.setLineDash([6,4], count: 2, phase: 0)
            border.lineWidth = 2
            NSColor.white.setStroke()
            border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selectionRect = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        updateSelection(from: startPoint, to: p)
    }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        updateSelection(from: startPoint, to: p)
        if selectionRect.width > 0 && selectionRect.height > 0 {
            onComplete?(selectionRect)
        } else {
            onCancel?()
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
    private func updateSelection(from a: CGPoint, to b: CGPoint) {
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
        let x1 = max(a.x, b.x), y1 = max(a.y, b.y)
        selectionRect = CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0)
        needsDisplay = true
    }
}

// MARK: - AppDelegate & ScreenCaptureKit
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, SCStreamDelegate, SCStreamOutput {
    @Published var targetBundleID = "com.apple.Safari" // 기본값
    @Published var isCapturing = false
    @Published var selectedRegionDescription = ""
    @Published var opacity: Double = 1.0 // PiP 투명도
    @Published var alwaysOnTop = true // 항상 위에 유지
    @Published var frameRate: Int = 60 // 프레임 레이트
    @Published var showCursor = true // 커서 표시
    private var overlayWindow: NSWindow?
    private var pipWindow: NSPanel?
    private var pipView: NSView?
    private var stream: SCStream?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func startCapture() {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showPermissionAlert()
            return
        }
        guard let screen = NSScreen.main else { return }
        let ov = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        ov.level = .screenSaver
        ov.backgroundColor = .clear
        ov.isOpaque = false
        ov.ignoresMouseEvents = false
        ov.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let view = OverlayView(frame: screen.frame)
        ov.contentView = view
        ov.makeFirstResponder(view)
        overlayWindow = ov
        view.onComplete = { [weak self] rect in
            ov.orderOut(nil)
            self?.overlayWindow = nil
            self?.beginCapture(region: rect, screen: screen)
        }
        view.onCancel = {
            ov.orderOut(nil)
            self.overlayWindow = nil
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false
        stream?.stopCapture { _ in }
        stream = nil
        pipWindow?.orderOut(nil)
        pipWindow = nil
        pipView = nil
        selectedRegionDescription = ""
    }

    func updatePiPSettings() {
        pipWindow?.alphaValue = CGFloat(opacity)
        pipWindow?.level = alwaysOnTop ? .screenSaver : .normal
    }

    private func beginCapture(region: CGRect, screen: NSScreen) {
        selectedRegionDescription = String(format: "W:%.0f×H:%.0f @ (%.0f,%.0f)", region.width, region.height, region.minX, region.minY)
        createPiPPanel(width: region.width, height: region.height)
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                // 찾을 브라우저 PID
                guard let pid = content.applications.first(where: { $0.bundleIdentifier == targetBundleID })?.processID else {
                    NSLog("\(targetBundleID) not running")
                    return
                }
                let center = CGPoint(x: region.midX, y: region.midY)
                // SCWindow 찾기
                guard let win = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.frame.contains(center) }) else {
                    NSLog("\(targetBundleID) window not found at selection")
                    return
                }
                // 윈도우 단위 필터 (desktopIndependentWindow 사용으로 모든 Space에서 캡처 가능)
                let filter = SCContentFilter(desktopIndependentWindow: win)
                var cfg = SCStreamConfiguration()
                cfg.capturesAudio = false
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: Int32(frameRate))
                let scale = screen.backingScaleFactor
                cfg.width = Int(region.width * scale)
                cfg.height = Int(region.height * scale)
                // 윈도우 상대 자르기
                let wf = win.frame
                let crop = CGRect(x: region.origin.x - wf.origin.x,
                                  y: region.origin.y - wf.origin.y,
                                  width: region.width,
                                  height: region.height)
                cfg.sourceRect = crop
                cfg.showsCursor = showCursor
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                try await s.startCapture()
                self.stream = s
                DispatchQueue.main.async { self.isCapturing = true }
            } catch {
                NSLog("Capture error: \(error.localizedDescription)")
            }
        }
    }

    private func createPiPPanel(width: CGFloat, height: CGFloat) {
        let panel = NSPanel(contentRect: NSRect(x:100, y:100, width:width, height:height), styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = alwaysOnTop ? .screenSaver : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle] // 모든 Space(데스크탑)에서 보이도록 설정
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = CGFloat(opacity)

        let cv = NSView(frame: panel.contentView!.bounds)
        cv.wantsLayer = true
        cv.layer?.contentsGravity = .resizeAspectFill
        cv.autoresizingMask = [.width, .height] // 뷰가 패널 크기 변경에 따라 자동 조정
        panel.contentView = cv

        panel.makeKeyAndOrderFront(nil)
        pipWindow = panel
        pipView = cv
    }

    private func showPermissionAlert() {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = "Screen Recording Permission Needed"
            a.informativeText = "Enable in Settings → Privacy & Security → Screen Recording"
            a.addButton(withTitle: "OK")
            a.runModal()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Stream stopped: \(error.localizedDescription)")
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, isCapturing,
              let buf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pb = buf as CVPixelBuffer
        if let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
            pipView?.layer?.contents = unsafeBitCast(surf, to: IOSurface.self)
        }
    }
}

// MARK: - SwiftUI View
struct ContentView: View {
    @EnvironmentObject var app: AppDelegate
    @State private var selectedBrowser: String = "Safari"

    var body: some View {
        VStack(spacing: 20) {
            // 헤더
            HStack {
                Image(systemName: "pip")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.blue)
                Text("Screen PiP Pro")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundColor(.primary)
            }
            .padding(.top, 10)

            // 상태 표시
            Text(app.isCapturing ? "Capturing: \(app.selectedRegionDescription)" : "Ready to capture a screen region")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(app.isCapturing ? .green : .secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // 주요 버튼
            Button(app.isCapturing ? "Stop Capture" : "Start Capture") {
                if app.isCapturing {
                    app.stopCapture()
                } else {
                    // 브라우저 선택 적용
                    app.targetBundleID = selectedBrowser == "Safari" ? "com.apple.Safari" : "com.google.Chrome"
                    app.startCapture()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(app.isCapturing ? .red : .blue)
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .padding(.bottom, 10)

            // 설정 섹션
            Divider()
            Text("Capture Settings")
                .font(.headline)
                .foregroundColor(.secondary)

            // 브라우저 선택
            Picker("Target Browser", selection: $selectedBrowser) {
                Text("Safari").tag("Safari")
                Text("Chrome").tag("Chrome")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            // 투명도 슬라이더
            HStack {
                Text("Opacity:")
                Slider(value: $app.opacity, in: 0.3...1.0, step: 0.1)
                    .onChange(of: app.opacity) { _ in app.updatePiPSettings() }
                Text(String(format: "%.1f", app.opacity))
            }

            // 항상 위에 토글
            Toggle("Always on Top", isOn: $app.alwaysOnTop)
                .onChange(of: app.alwaysOnTop) { _ in app.updatePiPSettings() }

            // 프레임 레이트 선택
            Picker("Frame Rate", selection: $app.frameRate) {
                Text("30 FPS").tag(30)
                Text("60 FPS").tag(60)
            }
            .pickerStyle(.menu)

            // 커서 표시 토글
            Toggle("Show Cursor in PiP", isOn: $app.showCursor)

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 400)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }
}

// MARK: - Visual Effect View (macOS 15 호환)
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

@main struct ScreenPiPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(delegate)
        }
    }
}