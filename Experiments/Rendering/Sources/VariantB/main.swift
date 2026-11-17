import AppKit
import CoreImage
import Metal
@preconcurrency import ScreenCaptureKit
import SpikeKit

// Variant B: ScreenCaptureKit stream of each display without Sonorus windows,
// Core Image Gaussian blur + dimming on the GPU, shown in a click-through
// overlay. A shape-layer mask limits it to visible parts of inactive windows.
// Requires Screen Recording. Without it the spike exits (no prompt) unless
// --request is passed, which calls CGRequestScreenCaptureAccess().
//
// Usage: swift run VariantB [--duration 8] [--radius 12] [--dim 0.3]
//   [--downscale 0.5] [--fps 30] [--request] [--follow]
//
// - SCStream: https://developer.apple.com/documentation/screencapturekit/scstream
// - SCContentFilter(display:excludingApplications:exceptingWindows:):
//   https://developer.apple.com/documentation/screencapturekit/sccontentfilter
// - CGRequestScreenCaptureAccess: https://developer.apple.com/documentation/coregraphics/cgrequestscreencaptureaccess()

let args = Args()

/// Receives frames on the capture queue and renders the blurred image.
final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  let context: CIContext
  let radiusPixels: Double
  let brightness: Double
  let label: String
  let deliver: @Sendable (CGImage) -> Void
  private let lock = NSLock()
  private var processing = Samples()
  private var latency = Samples()
  private var intervals = Samples()
  private var lastFrame: DispatchTime?
  private var dropped = 0

  init(
    label: String, radiusPixels: Double, brightness: Double, context: CIContext,
    deliver: @escaping @Sendable (CGImage) -> Void
  ) {
    self.label = label
    self.radiusPixels = radiusPixels
    self.brightness = brightness
    self.context = context
    self.deliver = deliver
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType
  ) {
    guard type == .screen else { return }
    let start = DispatchTime.now()
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let statusRaw = attachments.first?[.status] as? Int,
      SCFrameStatus(rawValue: statusRaw) == .complete,
      let pixelBuffer = CMSampleBufferGetImageBuffer(buffer)
    else {
      lock.withLock { dropped += 1 }
      return
    }
    let displayTime = attachments.first?[.displayTime] as? UInt64
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    var output = image
    if radiusPixels > 0 {
      output = image.clampedToExtent().applyingGaussianBlur(sigma: radiusPixels).cropped(
        to: image.extent)
    }
    if brightness < 1 {
      let b = CGFloat(brightness)
      output = output.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: b, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: b, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
        ])
    }
    guard let cgImage = context.createCGImage(output, from: image.extent) else { return }
    let cost = Log.elapsedMilliseconds(since: start)
    lock.withLock {
      processing.add(cost)
      if let lastFrame { intervals.add(Log.elapsedMilliseconds(since: lastFrame)) }
      lastFrame = start
      if let displayTime {
        // displayTime is mach absolute time of the captured frame.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nowTicks = mach_absolute_time()
        if nowTicks > displayTime {
          let nanos =
            Double(nowTicks - displayTime) * Double(timebase.numer) / Double(timebase.denom)
          latency.add(nanos / 1_000_000)
        }
      }
    }
    deliver(cgImage)
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    Log.observed("\(label): stream stopped with error \(error.localizedDescription)")
  }

  func summary() -> String {
    lock.withLock {
      "\(label): processing \(processing.summary); frame interval \(intervals.summary); "
        + "capture->processed latency \(latency.summary); incomplete/idle frames \(dropped)"
    }
  }
}

/// The layer is only touched on the main queue; the box only crosses queues.
struct LayerBox: @unchecked Sendable {
  let layer: CALayer
}

@MainActor
final class VariantB {
  let runner: SpikeRunner
  let radius = args.double("radius", default: 12)
  let brightness = 1 - args.double("dim", default: 0.3)
  let downscale = min(1, max(0.1, args.double("downscale", default: 0.5)))
  let fps = args.int("fps", default: 30)
  let focusTracker = FocusTracker()
  var streams: [SCStream] = []
  var sinks: [FrameSink] = []
  var maskLayers: [(DisplayInfo, CAShapeLayer)] = []

  init(runner: SpikeRunner) { self.runner = runner }

  func start() {
    SpikeEnvironment.report()
    guard CGPreflightScreenCaptureAccess() else {
      Log.observed("Screen Recording not granted; Variant B cannot capture")
      if args.flag("request") {
        // Shows the system prompt / opens System Settings; returns immediately.
        Log.observed("CGRequestScreenCaptureAccess() -> \(CGRequestScreenCaptureAccess())")
        Log.manual(
          "grant Screen Recording to the launching terminal app, restart it, rerun VariantB")
      } else {
        Log.manual("rerun with --request to trigger the system permission prompt deliberately")
      }
      runner.finish(code: 2)
    }
    Task { await self.startCapture() }
    runner.onTeardown {
      for stream in self.streams { stream.stopCapture { _ in } }
      for sink in self.sinks { Log.observed(sink.summary()) }
    }
  }

  func startCapture() async {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      let own = content.applications.filter { $0.processID == getpid() }
      Log.observed(
        "SCShareableContent: \(content.displays.count) displays, \(content.windows.count) windows")
      guard let device = MTLCreateSystemDefaultDevice() else { return }
      let ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
      for display in Displays.all() {
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.displayID })
        else { continue }
        let panel = OverlayPanel(
          appKitFrame: display.appKitFrame,
          level: NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1))
        // Belt and braces: the filter already excludes this app.
        panel.sharingType = .none
        let view = NSView(frame: CGRect(origin: .zero, size: display.appKitFrame.size))
        view.wantsLayer = true
        let imageLayer = CALayer()
        imageLayer.frame = view.bounds
        imageLayer.contentsGravity = .resize
        imageLayer.isGeometryFlipped = true
        let mask = CAShapeLayer()
        mask.frame = view.bounds
        mask.isGeometryFlipped = true
        imageLayer.mask = mask
        view.layer?.addSublayer(imageLayer)
        panel.contentView = view
        runner.track(panel)
        panel.orderFrontRegardless()
        maskLayers.append((display, mask))

        let filter = SCContentFilter(
          display: scDisplay, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.pixelSize.width * downscale)
        config.height = Int(display.pixelSize.height * downscale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 3
        let radiusPixels = radius * Double(display.scale) * downscale
        let box = LayerBox(layer: imageLayer)
        let sink = FrameSink(
          label: display.name, radiusPixels: radiusPixels, brightness: brightness,
          context: ciContext
        ) { image in
          DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            box.layer.contents = image
            CATransaction.commit()
          }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        try stream.addStreamOutput(
          sink, type: .screen,
          sampleHandlerQueue: DispatchQueue(label: "capture.\(display.displayID)"))
        try await stream.startCapture()
        streams.append(stream)
        sinks.append(sink)
        Log.observed(
          "capturing \(display.name) at \(config.width)x\(config.height) px, \(fps) fps max, "
            + "blur sigma \(String(format: "%.1f", radiusPixels)) px (= \(radius) pt)")
      }
      updateMasks()
      Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        MainActor.assumeIsolated { self.updateMasks() }
      }
      Log.manual(
        "compare blur quality and lag vs. Variant A; drag a window and look for ghosting/offset")
      Log.manual("check for the system screen-recording indicator in the menu bar / Control Center")
    } catch {
      Log.observed("capture setup failed: \(error.localizedDescription)")
      runner.finish(code: 1)
    }
  }

  func updateMasks() {
    let windows = WindowList.onScreen().filter { $0.pid != getpid() }
    let focus = focusTracker.resolve(windows: windows)
    let effectIDs = Set(windows.filter { $0.isNormalLevel && $0.id != focus.window?.id }.map(\.id))
    let rects = MaskBuilder.visibleEffectRects(frontToBack: windows, effectIDs: effectIDs).flatMap(
      \.1)
    for (display, mask) in maskLayers {
      let path = CGMutablePath()
      for rect in rects {
        let local = rect.intersection(display.quartzBounds)
        guard !local.isNull, !local.isEmpty else { continue }
        path.addRect(local.offsetBy(dx: -display.quartzBounds.minX, dy: -display.quartzBounds.minY))
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      mask.path = path
      CATransaction.commit()
    }
  }
}

let runner = SpikeRunner()
var variant: VariantB?
runner.run(duration: args.double("duration", default: 8)) { runner in
  variant = VariantB(runner: runner)
  variant?.start()
}
