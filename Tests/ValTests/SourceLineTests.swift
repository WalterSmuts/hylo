import Core
import XCTest

final class SourceLineTests: XCTestCase {

  func testText() {
    let source: SourceFile = """
      import Greetings

      public fun main() {
        print("Hello, World!")
      }
      """
    XCTAssertEqual(source.line(at: 1).text, "import Greetings\n")
    XCTAssertEqual(source.line(at: 2).text, "\n")
    XCTAssertEqual(source.line(at: 3).text, "public fun main() {\n")
    XCTAssertEqual(source.line(at: 4).text, "  print(\"Hello, World!\")\n")
    XCTAssertEqual(source.line(at: 5).text, "}")
  }

  func testDescription() {
    let source: SourceFile = "Hello,\nWorld!"
    let p = source.url.relativePath
    XCTAssertEqual("\(source.line(containing: source.text.startIndex))", "\(p):1")
    XCTAssertEqual("\(source.line(containing: source.text.endIndex))", "\(p):2")
  }

}
