import Foundation
@testable import MyBuddyCore

/// Locates the repository root (contains `protocol/`) from this source file.
enum Repo {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("protocol/schema/events.v1.json").path) {
                return url
            }
        }
        fatalError("repository root not found above \(#filePath)")
    }()

    static func data(_ relative: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(relative))
    }

    static func json(_ relative: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data(relative)) as! [String: Any]
    }
}

/// MBH1 test vectors from protocol/vectors/mbh1-v1.json.
struct Vectors {
    let inputs: [String: Any]
    let expected: [String: Any]
    let connect: [String: Any]

    static func load() throws -> Vectors {
        let v = try Repo.json("protocol/vectors/mbh1-v1.json")
        return Vectors(inputs: v["inputs"] as! [String: Any], expected: v["expected"] as! [String: Any], connect: v["connect"] as! [String: Any])
    }

    func input(_ key: String) -> String { inputs[key] as! String }
    func expect(_ key: String) -> String { expected[key] as! String }
    func b64(_ key: String) -> Data { Base64URL.decode(input(key))! }
    func hex(_ key: String) -> Data { Hex.decode(input(key))! }
}
