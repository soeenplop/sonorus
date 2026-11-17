import Contracts
import XCTest

@testable import Geometry

final class ScreenRegionTests: XCTestCase {
  func testIntersectionOfOverlappingRectsIncludesNegativeCoordinates() {
    let a = ScreenRect(x: -100, y: -50, width: 200, height: 100)
    let b = ScreenRect(x: -20, y: -80, width: 50, height: 60)
    XCTAssertEqual(a.intersection(b), ScreenRect(x: -20, y: -50, width: 50, height: 30))
  }

  func testTouchingOrDisjointRectsDoNotIntersect() {
    let a = ScreenRect(x: 0, y: 0, width: 10, height: 10)
    XCTAssertNil(a.intersection(ScreenRect(x: 10, y: 0, width: 10, height: 10)))
    XCTAssertNil(a.intersection(ScreenRect(x: 50, y: 50, width: 10, height: 10)))
    XCTAssertNil(a.intersection(ScreenRect(x: .nan, y: 0, width: 10, height: 10)))
  }

  func testSubtractingCenterLeavesFourDisjointPiecesWithExactArea() {
    let outer = ScreenRect(x: -10, y: -10, width: 30, height: 30)
    let hole = ScreenRect(x: 0, y: 0, width: 10, height: 10)
    let pieces = outer.subtracting(hole)
    XCTAssertEqual(pieces.count, 4)
    XCTAssertEqual(pieces.reduce(0) { $0 + $1.area }, 800)
    assertDisjoint(pieces)
    XCTAssertFalse(pieces.contains { $0.intersects(hole) })
  }

  func testSubtractingCoveringRectLeavesNothing() {
    let inner = ScreenRect(x: 5, y: 5, width: 5, height: 5)
    XCTAssertEqual(inner.subtracting(ScreenRect(x: 0, y: 0, width: 20, height: 20)), [])
    XCTAssertEqual(inner.subtracting(ScreenRect(x: 50, y: 0, width: 20, height: 20)), [inner])
  }

  func testSnappingRoundsEdgesToExactGrid() throws {
    let rect = ScreenRect(x: -0.1, y: 1.0 / 3, width: 532.8, height: 0.3)
    let snapped = try XCTUnwrap(rect.snapped())
    for edge in [snapped.minX, snapped.minY, snapped.maxX, snapped.maxY] {
      XCTAssertEqual(edge * 256, (edge * 256).rounded())
    }
    XCTAssertEqual(snapped.minX, rect.minX, accuracy: ScreenRect.exactGrid)
    XCTAssertEqual(snapped.maxY, rect.maxY, accuracy: ScreenRect.exactGrid)
    XCTAssertNil(ScreenRect(x: 0, y: 0, width: 0.001, height: 10).snapped())
    XCTAssertNil(ScreenRect(x: .nan, y: 0, width: 1, height: 1).snapped())
  }

  func testOperationsOnSnappedFractionalRectsShareExactEdges() throws {
    let base = try XCTUnwrap(
      ScreenRect(x: -1366.3, y: -0.7, width: 1000.1, height: 777.7).snapped())
    let holes = try [
      ScreenRect(x: -1000.0 / 3, y: 100.0 / 7, width: 200.0 / 3, height: 50.9),
      ScreenRect(x: -1200.11, y: 0.01, width: 333.333, height: 444.444),
    ].map { try XCTUnwrap($0.snapped()) }
    let region = ScreenRegion(base).subtracting(ScreenRegion(unioning: holes))
    assertDisjoint(region.rectangles)
    let expected = base.area - ScreenRegion(unioning: holes).intersection(base).area
    XCTAssertEqual(region.area, expected)
    XCTAssertEqual(region.coalesced().area, expected)
  }

  func testUnionOfOverlappingRectsHasNoDoubleCoverage() {
    let rects = [
      ScreenRect(x: 0, y: 0, width: 100, height: 100),
      ScreenRect(x: 50, y: 50, width: 100, height: 100),
      ScreenRect(x: 25, y: 25, width: 50, height: 50),
      ScreenRect(x: 0, y: 0, width: 100, height: 100),
    ]
    let region = ScreenRegion(unioning: rects)
    XCTAssertEqual(region.area, 10000 + 10000 - 2500)
    assertDisjoint(region.rectangles)
    assertCoverage(region, matches: rects, in: ScreenRect(x: -10, y: -10, width: 170, height: 170))
  }

  func testUnionIgnoresInvalidRects() {
    let region = ScreenRegion(unioning: [
      ScreenRect(x: 0, y: 0, width: 0, height: 10),
      ScreenRect(x: 0, y: 0, width: .infinity, height: 10),
      ScreenRect(x: 0, y: 0, width: -5, height: 10),
    ])
    XCTAssertTrue(region.isEmpty)
  }

  func testRegionSubtractionAndIntersection() {
    let region = ScreenRegion(unioning: [
      ScreenRect(x: -200, y: 0, width: 200, height: 100),
      ScreenRect(x: 0, y: 0, width: 200, height: 100),
    ])
    let cut = ScreenRegion(ScreenRect(x: -50, y: 25, width: 100, height: 50))
    let remaining = region.subtracting(cut)
    XCTAssertEqual(remaining.area, 40000 - 5000)
    assertDisjoint(remaining.rectangles)
    XCTAssertFalse(remaining.intersects(ScreenRect(x: -50, y: 25, width: 100, height: 50)))

    let common = region.intersection(cut)
    XCTAssertEqual(common.area, 5000)
    XCTAssertTrue(remaining.union(common).area == region.area)
  }

  func testCoalescingKeepsAreaAndMergesNeighbors() {
    let full = ScreenRect(x: -30, y: -30, width: 60, height: 60)
    let fragmented = ScreenRegion(full).subtracting(
      ScreenRect(x: -10, y: -10, width: 20, height: 20)
    )
    .union(ScreenRegion(ScreenRect(x: -10, y: -10, width: 20, height: 20)))
    XCTAssertGreaterThan(fragmented.rectangles.count, 1)
    let merged = fragmented.coalesced()
    XCTAssertEqual(merged.area, full.area)
    XCTAssertEqual(merged.rectangles, [full])
  }

  func testCoalescingProducesDeterministicOrder() {
    let a = ScreenRegion(unioning: [
      ScreenRect(x: 0, y: 50, width: 10, height: 10), ScreenRect(x: 0, y: 0, width: 10, height: 10),
    ])
    let b = ScreenRegion(unioning: [
      ScreenRect(x: 0, y: 0, width: 10, height: 10), ScreenRect(x: 0, y: 50, width: 10, height: 10),
    ])
    XCTAssertEqual(a.coalesced(), b.coalesced())
    XCTAssertEqual(a.coalesced().rectangles.first?.y, 0)
  }

  func testRandomizedOperationsPreserveDisjointnessAndCoverage() {
    var generator = SplitMix64(seed: 0x5EED)
    for _ in 0..<40 {
      let rects = (0..<6).map { _ in randomRect(&generator) }
      let holes = (0..<3).map { _ in randomRect(&generator) }
      let region = ScreenRegion(unioning: rects).subtracting(ScreenRegion(unioning: holes))
      assertDisjoint(region.rectangles)
      let bounds = ScreenRect(x: -60, y: -60, width: 120, height: 120)
      for px in stride(from: -59.5, to: 60, by: 3) {
        for py in stride(from: -59.5, to: 60, by: 3) {
          let point = ScreenPoint(x: px, y: py)
          let expected =
            rects.contains { contains($0, point) } && !holes.contains { contains($0, point) }
          XCTAssertEqual(region.contains(point), expected, "\(point)")
        }
      }
      XCTAssertTrue(region.rectangles.allSatisfy { bounds.contains($0) })
    }
  }

  // MARK: - Helpers

  private func randomRect(_ generator: inout SplitMix64) -> ScreenRect {
    let x = Double(Int(generator.next() % 100)) - 60
    let y = Double(Int(generator.next() % 100)) - 60
    let width = Double(Int(generator.next() % 40) + 1)
    let height = Double(Int(generator.next() % 40) + 1)
    return ScreenRect(x: x, y: y, width: min(width, 60 - x), height: min(height, 60 - y))
  }

  private func contains(_ rect: ScreenRect, _ point: ScreenPoint) -> Bool {
    point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY && point.y < rect.maxY
  }

  private func assertCoverage(
    _ region: ScreenRegion, matches rects: [ScreenRect], in bounds: ScreenRect,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    for px in stride(from: bounds.minX + 0.5, to: bounds.maxX, by: 5) {
      for py in stride(from: bounds.minY + 0.5, to: bounds.maxY, by: 5) {
        let point = ScreenPoint(x: px, y: py)
        let covering = region.rectangles.filter { contains($0, point) }.count
        let expected = rects.contains { contains($0, point) } ? 1 : 0
        XCTAssertEqual(covering, expected, "\(point)", file: file, line: line)
      }
    }
  }
}

func assertDisjoint(_ rects: [ScreenRect], file: StaticString = #filePath, line: UInt = #line) {
  for (index, rect) in rects.enumerated() {
    XCTAssertTrue(rect.isUsable, file: file, line: line)
    for other in rects[(index + 1)...] {
      XCTAssertNil(rect.intersection(other), "\(rect) overlaps \(other)", file: file, line: line)
    }
  }
}

struct SplitMix64 {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
