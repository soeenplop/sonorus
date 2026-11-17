import Foundation

/// Timestamped stdout logging. Lines prefixed `VERIFIED`, `OBSERVED` or
/// `MANUAL` are meant to be copied into the experiment report as-is.
public enum Log {
  private static let start = DispatchTime.now()

  public static func info(_ message: String) {
    emit("info", message)
  }

  /// Programmatically checked fact (assertion with a pass/fail result).
  public static func verified(_ message: String, passed: Bool) {
    emit(passed ? "VERIFIED pass" : "VERIFIED FAIL", message)
  }

  /// Measured value or API result without a pass/fail expectation.
  public static func observed(_ message: String) {
    emit("OBSERVED", message)
  }

  /// Something only a human looking at the screen can judge.
  public static func manual(_ message: String) {
    emit("MANUAL", message)
  }

  public static func elapsedMilliseconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
  }

  private static func emit(_ tag: String, _ message: String) {
    let seconds = elapsedMilliseconds(since: start) / 1000
    print(String(format: "[%7.3fs] %@: %@", seconds, tag, message))
    fflush(stdout)
  }
}

/// Summary statistics for latency samples in milliseconds.
public struct Samples: Sendable {
  public private(set) var values: [Double] = []

  public init() {}

  public mutating func add(_ value: Double) { values.append(value) }

  public var summary: String {
    guard !values.isEmpty else { return "n=0" }
    let sorted = values.sorted()
    let mean = sorted.reduce(0, +) / Double(sorted.count)
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    return String(
      format: "n=%d mean=%.3fms p50=%.3fms p95=%.3fms max=%.3fms", sorted.count, mean,
      sorted[sorted.count / 2], p95, sorted.last!)
  }

  public static func measure(_ iterations: Int, _ body: () -> Void) -> Samples {
    var samples = Samples()
    for _ in 0..<iterations {
      let start = DispatchTime.now()
      body()
      samples.add(Log.elapsedMilliseconds(since: start))
    }
    return samples
  }
}
