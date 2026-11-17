import XCTest

@testable import SpikeKit

final class CrossBlurTests: XCTestCase {
  func testBackgroundBehindBothPanelsStaysConstant() {
    let radius: CGFloat = 24
    let dim: CGFloat = 0.3
    for progress in stride(from: 0.0, through: 1.0, by: 0.05) {
      let incoming = CrossBlur.incomingRadius(radius, progress: progress)
      let outgoing = CrossBlur.outgoingRadius(radius, progress: progress)
      // Gaussian radii compose in quadrature.
      XCTAssertEqual(sqrt(incoming * incoming + outgoing * outgoing), radius, accuracy: 1e-9)
      let transmission =
        (1 - CrossBlur.incomingDim(dim, progress: progress))
        * (1 - CrossBlur.outgoingDim(dim, progress: progress))
      XCTAssertEqual(transmission, 1 - dim, accuracy: 1e-9)
    }
  }

  func testOldFocusBlursInFromZeroAndOutgoingEndsEmpty() {
    XCTAssertEqual(CrossBlur.incomingRadius(24, progress: 0), 0)
    XCTAssertEqual(CrossBlur.incomingRadius(24, progress: 1), 24)
    XCTAssertEqual(CrossBlur.outgoingRadius(24, progress: 1), 0)
    XCTAssertEqual(CrossBlur.outgoingDim(0.3, progress: 0), 0.3, accuracy: 1e-9)
    XCTAssertEqual(CrossBlur.outgoingDim(0.3, progress: 1), 0, accuracy: 1e-9)
    XCTAssertEqual(CrossBlur.outgoingDim(1, progress: 1), 0)
    let samples = CrossBlur.samples(24)
    XCTAssertEqual(samples.first, 0)
    XCTAssertEqual(samples.last, 1)
    XCTAssertEqual(samples, samples.sorted())
  }
}
