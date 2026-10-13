// Helpers for calling the C ABI (npc_core.h): owned strings, errors, JSON coding.
import Foundation
import NPCCore

public enum NPCError: Error, Equatable, CustomStringConvertible {
    /// The core rejected input (message starts with the JSON path or file).
    case invalid(String)
    case io(String)
    case timedOut
    public var description: String {
        switch self {
        case .invalid(let m): m
        case .io(let m): m
        case .timedOut: "timed out waiting for the dialogue service"
        }
    }
}

enum Core {
    /// Takes ownership of a string returned by the core.
    static func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { npc_string_free(p) }
        return String(cString: p)
    }

    /// Calls a core function that reports failure through `char** error`.
    static func call<T>(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T?) throws -> T {
        var error: UnsafeMutablePointer<CChar>?
        let value = body(&error)
        if let message = take(error) { throw NPCError.invalid(message) }
        guard let value else { throw NPCError.invalid("the dialogue core returned no value") }
        return value
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }()

    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(json.utf8)) }
        catch { throw NPCError.invalid("cannot decode \(T.self): \(error)") }
    }
}

/// ABI version of the linked dialogue core.
public var npcCoreABIVersion: Int { Int(npc_core_abi_version()) }
