import Foundation
import NIO

@propertyWrapper
public struct UUIDHexadecimalEncoded {
    public init(wrappedValue: UUID) {
        self.wrappedValue = wrappedValue
    }
    public let wrappedValue: UUID
}

extension UUIDHexadecimalEncoded: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let id = UUID(fromHexadecimalEncodedString: try container.decode(String.self)) else {
            throw DecodingError.typeMismatch(
                UUIDHexadecimalEncoded.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected UUID in hexadecimal format"))
        }
        self.wrappedValue = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.wrappedValue.hexadecimalEncoded)
    }
}

extension UUID {
    /// Hexadecimal encoded 32-characters encoded uuid without dashes. E.g. `ecce513737d441b78b66c84ace35a281`
    var hexadecimalEncoded: String {
        uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    init?(fromHexadecimalEncodedString string: String) {
        var a = string.uppercased()
        a.insert("-", at: a.index(a.startIndex, offsetBy: 20))
        a.insert("-", at: a.index(a.startIndex, offsetBy: 16))
        a.insert("-", at: a.index(a.startIndex, offsetBy: 12))
        a.insert("-", at: a.index(a.startIndex, offsetBy: 8))
        self.init(uuidString: a)
    }
}

extension ByteBuffer {
    mutating func getUUIDHexadecimalEncoded() -> UUID? {
        guard let string = readString(length: readableBytes) else {
            return nil
        }
        return UUID(fromHexadecimalEncodedString: string)
    }
}
