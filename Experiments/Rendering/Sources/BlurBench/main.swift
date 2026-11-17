import AppKit
import CoreImage
import Metal
import SpikeKit

// Offline GPU cost of the Variant B image pipeline (Gaussian blur + dimming)
// on synthetic frames at the real display sizes. Needs no permissions and
// shows no windows. Radius is given in points like the planned slider.
//
// Usage: swift run BlurBench [--iterations 30] [--radii 0,4,8,16,32]
//   [--downscales 1,0.5,0.25]

let args = Args()
let iterations = args.int("iterations", default: 30)
let radii = args.list("radii").compactMap(Double.init).nilIfEmpty ?? [0, 4, 8, 16, 32]
let downscales = args.list("downscales").compactMap(Double.init).nilIfEmpty ?? [1, 0.5, 0.25]

extension Array {
  var nilIfEmpty: Self? { isEmpty ? nil : self }
}

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
  print("no Metal device")
  exit(1)
}
let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
Log.observed("Metal device: \(device.name)")

@MainActor
func sizes() -> [(String, CGSize, CGFloat)] {
  var result = Displays.all().map { ($0.name, $0.pixelSize, $0.scale) }
  result.append(("synthetic 5K", CGSize(width: 5120, height: 2880), 2))
  return result
}

for (name, pixels, scale) in sizes() {
  // High-frequency checkerboard: worst case for blur, no capture needed.
  let checker = CIFilter(
    name: "CICheckerboardGenerator",
    parameters: [
      "inputWidth": 8, "inputColor0": CIColor.white, "inputColor1": CIColor.black,
      "inputCenter": CIVector(x: 0, y: 0),
    ])!.outputImage!
  for downscale in downscales {
    let width = Int(pixels.width * downscale)
    let height = Int(pixels.height * downscale)
    let extent = CGRect(x: 0, y: 0, width: width, height: height)
    let source = checker.cropped(to: extent)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderWrite, .shaderRead]
    descriptor.storageMode = .private
    guard let texture = device.makeTexture(descriptor: descriptor) else { continue }
    var line: [String] = []
    for radius in radii {
      let sigma = radius * scale * downscale
      var image = source
      if sigma > 0 {
        image = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
      }
      image = image.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 0.7, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 0.7, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 0.7, w: 0),
        ])
      let render = {
        guard let buffer = queue.makeCommandBuffer() else { return }
        let destination = CIRenderDestination(
          width: width, height: height, pixelFormat: .bgra8Unorm, commandBuffer: buffer
        ) { texture }
        _ = try? context.startTask(toRender: image, to: destination)
        buffer.commit()
        buffer.waitUntilCompleted()
      }
      render()  // warm-up compiles kernels
      let samples = Samples.measure(iterations, render)
      let mean = samples.values.reduce(0, +) / Double(samples.values.count)
      line.append(String(format: "r%.0fpt=%.2fms", radius, mean))
    }
    Log.observed(
      "\(name) \(width)x\(height)px (downscale \(downscale)): " + line.joined(separator: " "))
  }
}
Log.observed("ms = wall time per frame incl. GPU completion; ×30 for a 30 fps budget estimate")
