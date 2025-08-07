import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit

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

// MARK: - Helper: find PID by bundle ID
func findAppPID(bundleID: String) -> pid_t? {
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first?.processIdentifier
}

// MARK: - AppDelegate & ScreenCaptureKit
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, SCStreamDelegate, SCStreamOutput {
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

    private func beginCapture(region: CGRect, screen: NSScreen) {
        selectedRegionDescription = String(format: "W:%.0f×H:%.0f @ (%.0f,%.0f)", region.width, region.height, region.minX, region.minY)
        createPiPPanel(width: region.width, height: region.height)
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                // 찾을 Safari PID
                guard let safariPID = content.applications.first(where: { $0.bundleIdentifier == targetBundleID })?.processIdentifier else {
                    NSLog("Safari not running")
                    return
                }
                let center = CGPoint(x: region.midX, y: region.midY)
                // SCWindow 찾기
                guard let win = content.windows.first(where: { $0.ownerPID == safariPID && $0.frame.contains(center) }) else {
                    NSLog("Safari window not found at selection")
                    return
                }
                // 윈도우 단위 필터
                let filter = SCContentFilter(desktopIndependentWindow: win)
                var cfg = SCStreamConfiguration()
                cfg.capturesAudio = false
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                let scale = screen.backingScaleFactor
                cfg.width = Int(region.width * scale)
                cfg.height = Int(region.height * scale)
                //윈도우 상대 자르기
                let wf = win.frame
                let crop = CGRect(x: region.origin.x - wf.origin.x,
                                  y: region.origin.y - wf.origin.y,
                                  width: region.width,
                                  height: region.height)
                cfg.sourceRect = crop
                cfg.showsCursor = true
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
        let panel = NSPanel(contentRect: NSRect(x:100, y:100, width:width, height:height), styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let cv = NSView(frame: panel.contentView!.bounds)
        cv.wantsLayer = true
        cv.layer?.contentsGravity = .resizeAspectFill
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
    var body: some View {
        VStack(spacing:16) {
            Text("Screen PiP Utility").font(.title2)
            Text(app.isCapturing ? app.selectedRegionDescription : "Select a region to PiP-capture.")
                .multilineTextAlignment(.center)
            Button(app.isCapturing ? "Stop PiP" : "Start PiP") {
                if app.isCapturing { app.stopCapture() } else { app.startCapture() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(minWidth:360)
    }
}

@main struct ScreenPiPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(delegate) }
    }
}
