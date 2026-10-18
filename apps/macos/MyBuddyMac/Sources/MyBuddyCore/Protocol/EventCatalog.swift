import Foundation

/// The v1 event catalog (`protocol/schema/events.v1.json`), embedded at build time.
public struct EventCatalog: Sendable, Decodable {
    public let version: Int
    public let limits: [String: Int]
    public let capabilities: [String]
    public let keyCodes: [String]
    public let events: [String: EventSpec]

    /// The catalog compiled into this binary.
    public static let shared: EventCatalog = {
        do {
            return try JSONDecoder().decode(EventCatalog.self, from: Data(EventCatalogData.json.utf8))
        } catch {
            fatalError("Embedded event catalog is invalid: \(error)")
        }
    }()

    /// The raw embedded JSON (used by drift tests).
    public static var embeddedJSON: String { EventCatalogData.json }

    public var maxEnvelopeBytes: Int { limits.values.max() ?? 65536 }
}

public struct EventSpec: Sendable, Decodable {
    public let dir: String
    public let channel: String
    public let capability: String?
    public let core: Bool?
    public let payload: [String: FieldSpec]?
    public let payloadP2M: [String: FieldSpec]?
    public let payloadM2P: [String: FieldSpec]?
}

public indirect enum ItemSpec: Sendable, Decodable {
    case named(String)  // "capability" | "string" | "integer"
    case spec(FieldSpec)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .named(s)
        } else {
            self = .spec(try c.decode(FieldSpec.self))
        }
    }
}

public enum EnumValues: Sendable, Decodable {
    case list([String])
    case reference(String)  // e.g. "$keyCodes"

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .reference(s)
        } else {
            self = .list(try c.decode([String].self))
        }
    }
}

public struct FieldSpec: Sendable, Decodable {
    public let type: String
    public let min: Double?
    public let max: Double?
    public let optional: Bool?
    public let values: EnumValues?
    public let pattern: String?
    public let unit: String?
    public let noNul: Bool?
    public let fileName: Bool?
    public let noControlExcept: [String]?
    public let maxBytes: Int?
    public let items: ItemSpec?
    public let fields: [String: FieldSpec]?
    public let totalTextBytesMax: Int?
}

/// Which side is decoding a message. The Mac receives phone→Mac (`P2M`) types.
public enum ProtocolRole: String, Sendable {
    case mac
    case phone
}

/// Validates payload objects against catalog field specs.
struct PayloadValidator {
    let catalog: EventCatalog

    func validate(_ payload: [String: JSONValue], against spec: [String: FieldSpec]) -> String? {
        for (name, field) in spec.sorted(by: { $0.key < $1.key }) {
            let value = payload[name]
            if value == nil || value == .null {
                if field.optional == true { continue }
                return "missing field '\(name)'"
            }
            if let problem = validate(value!, field: field) {
                return "'\(name)': \(problem)"
            }
        }
        return nil
    }

    func validate(_ value: JSONValue, field: FieldSpec) -> String? {
        switch field.type {
        case "string":
            guard case .string(let s) = value else { return "expected string" }
            return validateString(s, field: field)
        case "enum":
            guard case .string(let s) = value else { return "expected string" }
            return allowedValues(field.values).contains(s) ? nil : "value not allowed"
        case "number":
            guard let n = value.numberValue, n.isFinite else { return "expected number" }
            if let min = field.min, n < min { return "below minimum" }
            if let max = field.max, n > max { return "above maximum" }
            return nil
        case "integer":
            guard case .int(let i) = value else { return "expected integer" }
            if i > 9_007_199_254_740_991 || i < -9_007_199_254_740_991 { return "integer out of safe range" }
            if let min = field.min, Double(i) < min { return "below minimum" }
            if let max = field.max, Double(i) > max { return "above maximum" }
            return nil
        case "bool":
            guard case .bool = value else { return "expected boolean" }
            return nil
        case "uuid":
            guard case .string(let s) = value, UUID(uuidString: s) != nil, s.count == 36 else { return "expected UUID" }
            return nil
        case "hex64":
            guard case .string(let s) = value, s.count == 64,
                  s.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
            else { return "expected 64 lowercase hex characters" }
            return nil
        case "b64u":
            guard case .string(let s) = value, let data = Base64URL.decode(s) else { return "expected base64url" }
            if let maxBytes = field.maxBytes, data.count > maxBytes { return "decoded data too large" }
            return nil
        case "array":
            guard case .array(let items) = value else { return "expected array" }
            if let min = field.min, Double(items.count) < min { return "too few items" }
            if let max = field.max, Double(items.count) > max { return "too many items" }
            if let itemSpec = field.items {
                for item in items {
                    if let problem = validateItem(item, spec: itemSpec) { return "item \(problem)" }
                }
            }
            if let limit = field.totalTextBytesMax {
                let total = items.reduce(0) { $0 + ($1["text"]?.stringValue?.utf8.count ?? 0) }
                if total > limit { return "total text too large" }
            }
            return nil
        case "object":
            guard case .object(let object) = value else { return "expected object" }
            if let fields = field.fields { return validate(object, against: fields) }
            return nil
        default:
            return "unknown field type \(field.type)"
        }
    }

    private func validateItem(_ value: JSONValue, spec: ItemSpec) -> String? {
        switch spec {
        case .named("capability"):
            guard case .string(let s) = value, catalog.capabilities.contains(s) else { return "unknown capability" }
            return nil
        case .named("string"):
            guard case .string(let s) = value, s.unicodeScalars.count <= 128 else { return "expected short string" }
            return nil
        case .named("integer"):
            guard case .int = value else { return "expected integer" }
            return nil
        case .named(let other):
            return "unknown item type \(other)"
        case .spec(let field):
            return validate(value, field: field)
        }
    }

    private func allowedValues(_ values: EnumValues?) -> [String] {
        switch values {
        case .list(let list): list
        case .reference("$keyCodes"): catalog.keyCodes
        default: []
        }
    }

    private func validateString(_ s: String, field: FieldSpec) -> String? {
        let length = field.unit == "utf8Bytes" ? s.utf8.count : s.unicodeScalars.count
        if let min = field.min, Double(length) < min { return "too short" }
        if let max = field.max, Double(length) > max { return "too long" }
        if field.noNul == true, s.unicodeScalars.contains("\u{0}") { return "contains NUL" }
        if let allowed = field.noControlExcept {
            let allowedScalars = Set(allowed.flatMap { $0.unicodeScalars })
            if s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && !allowedScalars.contains($0) }) {
                return "contains control characters"
            }
        }
        if field.fileName == true, !FileNameRules.isSafe(s) { return "not a safe file name" }
        if let pattern = field.pattern {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return "bad pattern" }
            let range = NSRange(s.startIndex..., in: s)
            guard let match = regex.firstMatch(in: s, range: range), match.range == range else { return "does not match pattern" }
        }
        return nil
    }
}

/// File names received from a peer (transfers) must be a single, harmless path component.
public enum FileNameRules {
    public static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != ".." else { return false }
        if name.contains("/") || name.contains("\\") || name.contains(":") { return false }
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return false }
        if name.hasPrefix(" ") || name.hasSuffix(" ") || name.hasSuffix(".") { return false }
        return true
    }
}
