import UIKit
import MetalKit
import CoreMotion

/// Main VR view controller. Owns the Metal render view, the ALVR event loop,
/// the VideoToolbox decoder, and the CoreMotion head tracker.
final class ALVRViewController: UIViewController {

    // MARK: - State

    private var mtkView: MTKView!
    private var renderer: VRRenderer?
    private var decoder: VideoDecoder?
    private var headTracker = HeadTracker()

    private var eventTimer: CADisplayLink?
    private var trackingTimer: Timer?
    private var isStreaming = false

    // Updated from ALVR StreamingStarted event.
    private var currentFov = (left: Float(-45 * Float.pi / 180),
                              right: Float(45 * Float.pi / 180),
                              up: Float(45 * Float.pi / 180),
                              down: Float(-45 * Float.pi / 180))

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupMetal()
        setupDecoder()
        setupALVR()
        headTracker.start()
        startEventLoop()
        startTrackingLoop()
        setupBatteryMonitoring()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        pvr_ios_resume()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pvr_ios_pause()
    }

    deinit {
        pvr_ios_destroy()
        headTracker.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Orientation

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeLeft }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeLeft }

    // MARK: - Setup

    private func setupMetal() {
        mtkView = MTKView(frame: view.bounds)
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(mtkView)

        renderer = VRRenderer(mtkView: mtkView)
        mtkView.delegate = self
        mtkView.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
    }

    private func setupDecoder() {
        decoder = VideoDecoder()
        decoder?.onFrame = { [weak self] pixelBuffer, _ in
            self?.renderer?.updateVideoTexture(pixelBuffer)
        }
    }

    private func setupALVR() {
        let screen = UIScreen.main.nativeBounds
        let w = UInt32(max(screen.width, screen.height) / 2)
        let h = UInt32(min(screen.width, screen.height))
        let fps = Float(UIScreen.main.maximumFramesPerSecond)
        pvr_ios_initialize(w, h, fps)
    }

    private func setupBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(batteryDidChange),
                                               name: UIDevice.batteryLevelDidChangeNotification,
                                               object: nil)
    }

    @objc private func batteryDidChange() {
        let level = max(0, UIDevice.current.batteryLevel)
        let plugged = UIDevice.current.batteryState != .unplugged
        pvr_ios_send_battery(level, plugged)
    }

    // MARK: - Event loop (polls ALVR events)

    private func startEventLoop() {
        eventTimer = CADisplayLink(target: self, selector: #selector(pollEvents))
        eventTimer?.preferredFramesPerSecond = 120
        eventTimer?.add(to: .main, forMode: .common)
    }

    @objc private func pollEvents() {
        var event = pvr_make_empty_event()
        while pvr_ios_poll_event(&event) {
            switch event.tag {
            case ALVR_EVENT_STREAMING_STARTED:
                isStreaming = true
                NSLog("[PhoneVR] Streaming started %ux%u @ %.0f Hz",
                      event.payload.STREAMING_STARTED.view_width,
                      event.payload.STREAMING_STARTED.view_height,
                      event.payload.STREAMING_STARTED.refresh_rate_hint)

            case ALVR_EVENT_STREAMING_STOPPED:
                isStreaming = false
                NSLog("[PhoneVR] Streaming stopped")

            case ALVR_EVENT_DECODER_CONFIG:
                drainNalQueue(codec: event.payload.DECODER_CONFIG.codec, isConfig: true)

            case ALVR_EVENT_FRAME_READY:
                drainNalQueue(codec: ALVR_CODEC_H264, isConfig: false)

            case ALVR_EVENT_HUD_MESSAGE_UPDATED:
                break

            default:
                break
            }
        }
    }

    private func drainNalQueue(codec: AlvrCodec_Tag, isConfig: Bool) {
        while true {
            var tsNs: UInt64 = 0
            // Two contiguous AlvrViewParams as an array so we can pass a pointer safely.
            var viewParamsArr: [AlvrViewParams] = [AlvrViewParams(), AlvrViewParams()]

            // Peek: pass nil buffer to learn the byte size without consuming.
            let size = viewParamsArr.withUnsafeMutableBufferPointer { vp in
                pvr_ios_poll_nal(&tsNs, vp.baseAddress, nil)
            }
            guard size > 0 else { break }

            var buf = [UInt8](repeating: 0, count: Int(size))
            viewParamsArr.withUnsafeMutableBufferPointer { vp in
                buf.withUnsafeMutableBufferPointer { b in
                    _ = pvr_ios_poll_nal(&tsNs, vp.baseAddress, b.baseAddress)
                }
            }

            // Mirror the FOV that the PC server expects us to render.
            currentFov.left  = viewParamsArr[0].fov.left
            currentFov.right = viewParamsArr[0].fov.right
            currentFov.up    = viewParamsArr[0].fov.up
            currentFov.down  = viewParamsArr[0].fov.down

            if isConfig {
                decoder?.configure(codec: codec, configNal: buf)
            } else {
                decoder?.submitNal(timestampNs: tsNs, nal: buf)
            }
        }
    }

    // MARK: - Tracking loop (sends head pose to PC ~200 Hz)

    private func startTrackingLoop() {
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 200.0, repeats: true) { [weak self] _ in
            self?.sendTracking()
        }
    }

    private func sendTracking() {
        let q = headTracker.currentQuaternion
        // 50 ms prediction offset – matches ALVR Android default.
        let targetNs = UInt64(Date().timeIntervalSince1970 * 1e9) + 50_000_000
        pvr_ios_send_tracking(targetNs,
                              q.imag.x, q.imag.y, q.imag.z, q.real,
                              currentFov.left, currentFov.right,
                              currentFov.up,   currentFov.down)
    }
}

// MARK: - MTKViewDelegate

extension ALVRViewController: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        renderer?.render(in: view)
    }
}
