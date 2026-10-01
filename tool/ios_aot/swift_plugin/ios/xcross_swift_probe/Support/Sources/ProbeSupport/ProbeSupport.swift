import Foundation
public enum ProbeSupport {
    public static func sumSquares(_ n: Int) -> Int { (1...n).reduce(0) { $0 + $1 * $1 } }
    public static func resource() -> String {
        guard let url = Bundle.module.url(forResource: "marker", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "MISSING" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
