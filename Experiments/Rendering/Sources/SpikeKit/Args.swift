import Foundation

/// Minimal `--key value` / `--flag` parser; spikes need no dependency.
public struct Args: Sendable {
  private var values: [String: String] = [:]
  private var flags: Set<String> = []

  public init(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      guard argument.hasPrefix("--") else {
        index += 1
        continue
      }
      let key = String(argument.dropFirst(2))
      if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
        values[key] = arguments[index + 1]
        index += 2
      } else {
        flags.insert(key)
        index += 1
      }
    }
  }

  public func flag(_ key: String) -> Bool { flags.contains(key) }

  public func string(_ key: String) -> String? { values[key] }

  public func string(_ key: String, default fallback: String) -> String {
    values[key] ?? fallback
  }

  public func double(_ key: String, default fallback: Double) -> Double {
    values[key].flatMap(Double.init) ?? fallback
  }

  public func int(_ key: String, default fallback: Int) -> Int {
    values[key].flatMap(Int.init) ?? fallback
  }

  public func list(_ key: String) -> [String] {
    values[key]?.split(separator: ",").map(String.init) ?? []
  }
}
