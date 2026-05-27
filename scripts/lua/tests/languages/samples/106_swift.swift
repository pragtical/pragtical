import Foundation

enum RenderError: Error {
  case empty
}

protocol Renderer {
  associatedtype Item
  func render(_ items: [Item]) async throws -> String
}

@propertyWrapper
struct Trimmed {
  private var value: String = ""
  var wrappedValue: String {
    get { value }
    set { value = newValue.trimmingCharacters(in: .whitespaces) }
  }
}

actor Counter {
  private var value = 0
  func next() -> Int {
    defer { value += 1 }
    return value
  }
}

final class Widget: Renderer {
  @Trimmed var name: String

  init(name: String) {
    self.name = name
  }

  func render(_ items: [String]) async throws -> String {
    guard !items.isEmpty else { throw RenderError.empty }
    return items.map { "\(name):\($0)" }.joined(separator: ", ")
  }
}

extension Widget: CustomStringConvertible {
  var description: String { "Widget(\(name))" }
}
