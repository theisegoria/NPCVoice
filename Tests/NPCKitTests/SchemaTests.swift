import Foundation
import Testing
import NPCCore
@testable import NPCKit

/// The published JSON Schemas (docs/schema) against the strict core: sample project files
/// validate, real results validate, and schema and core reject the same bad calls.
@Suite struct SchemaTests {
    static let dir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/schema")
    let schemas = SchemaSet(directory: SchemaTests.dir)

    @Test func sampleProjectFilesValidate() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "schema-\(UUID().uuidString).npcproj")
        defer { try? FileManager.default.removeItem(at: root) }
        try NPCProject.writeSample(to: root)
        #expect(try schemas.errors(file: root.appending(path: "project.json"), schema: "project.schema.json") == [])
        #expect(try schemas.errors(file: root.appending(path: "facts.json"), schema: "facts.schema.json") == [])
        #expect(try schemas.errors(file: root.appending(path: "commands.json"), schema: "commands.schema.json") == [])
        let characters = try FileManager.default.contentsOfDirectory(at: root.appending(path: "characters"), includingPropertiesForKeys: nil)
        #expect(characters.count == 4)
        for c in characters { #expect(try schemas.errors(file: c, schema: "character.schema.json") == [], "\(c.lastPathComponent)") }
    }

    @Test func callsAgreeWithTheCore() throws {
        let handle = try ProjectHandle(project: try NPCProject.sample())
        let good = [
            #"{"character":"marta","playerUtterance":"A room, please."}"#,
            #"{"character":"rhys","trigger":"The player draws a knife.","flags":["earned_tamsin_trust"],"location":"east gate","perception":["rain",{"text":"a crowd","salience":0.8}],"exchanges":[{"speaker":"character","text":"Halt."}],"budget":{"deadlineMs":1500},"sampling":{"greedy":false,"temperature":0.9,"seed":7},"priority":2,"allowCache":false}"#,
        ]
        let bad = [
            #"{"character":"marta","playerUtterance":"Hi","colour":"red"}"#,      // unknown field
            #"{"character":"marta"}"#,                                            // no utterance or trigger
            #"{"character":"marta","playerUtterance":""}"#,                       // empty utterance
            #"{"character":"marta","playerUtterance":"Hi","flags":"one"}"#,       // wrong type
            #"{"character":"marta","playerUtterance":"Hi","exchanges":[{"speaker":"narrator","text":"x"}]}"#,
        ]
        for call in good {
            #expect(try schemas.errors(json: call, schema: "call.schema.json") == [], "\(call)")
            #expect(coreAccepts(handle, call), "core should accept \(call)")
        }
        for call in bad {
            #expect(try !schemas.errors(json: call, schema: "call.schema.json").isEmpty, "schema should reject \(call)")
            #expect(!coreAccepts(handle, call), "core should reject \(call)")
        }
    }

    @Test func serviceResultsValidate() throws {
        let handle = try ProjectHandle(project: try NPCProject.sample())
        let request = try #require(requestJSON(handle, #"{"character":"marta","playerUtterance":"A room, please."}"#))
        for config in [#"{"fixedResponse":"{\"text\":\"Three marks, love.\",\"emotion\":\"happy\",\"intent\":\"inform\",\"commands\":[{\"kind\":\"give_item\",\"target\":\"room_key\"}]}"}"#,
                       #"{"available":false}"#] {
            let backend = try #require(npc_backend_create_stub(config, nil))
            let service = try #require(npc_service_create(backend, nil, nil))
            defer { npc_service_destroy(service); npc_backend_release(backend) }
            let ticket = npc_service_submit(service, request, nil)
            let raw = try #require(npc_service_wait(service, ticket, 2000))
            defer { npc_string_free(raw) }
            #expect(try schemas.errors(json: String(cString: raw), schema: "result.schema.json") == [], "\(String(cString: raw))")
        }
    }

    /// Real SDK output captured by Samples/c-sample (regenerate the fixtures if the format changes).
    @Test func speechInfoFixturesValidate() throws {
        let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
        #expect(try schemas.errors(file: fixtures.appending(path: "speech-info.json"), schema: "speech-info.schema.json") == [])
        #expect(try schemas.errors(file: fixtures.appending(path: "speech-chunk-info.json"), schema: "speech-chunk-info.schema.json") == [])
    }

    @Test func documentedConfigsValidate() throws {
        #expect(try schemas.errors(json: #"{"queueCapacity":16,"cacheCapacity":256,"cancelGraceMs":300,"guardrails":{"extraMetaPhrases":["as an AI"]}}"#,
                                   schema: "service-config.schema.json") == [])
        #expect(try schemas.errors(json: #"{"modelDir":null,"cacheMB":256,"warmUp":true}"#, schema: "mlx-config.schema.json") == [])
        #expect(try !schemas.errors(json: #"{"queueCapacity":0}"#, schema: "service-config.schema.json").isEmpty)
    }

    private func requestJSON(_ h: ProjectHandle, _ call: String) -> String? {
        guard let r = npc_project_request(h.raw, call, nil) else { return nil }
        defer { npc_string_free(r) }
        return String(cString: r)
    }
    private func coreAccepts(_ h: ProjectHandle, _ call: String) -> Bool { requestJSON(h, call) != nil }
}

/// Minimal JSON Schema (2020-12) validator for the keywords docs/schema uses: $ref (to
/// #/$defs or another file), type, enum, const, properties, required,
/// additionalProperties: false, items, anyOf, minimum, maximum, minLength.
struct SchemaSet {
    let directory: URL

    func errors(file: URL, schema: String) throws -> [String] {
        try errors(value: JSONSerialization.jsonObject(with: Data(contentsOf: file), options: [.fragmentsAllowed]), schema: schema)
    }
    func errors(json: String, schema: String) throws -> [String] {
        try errors(value: JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]), schema: schema)
    }
    func errors(value: Any, schema name: String) throws -> [String] {
        var out: [String] = []
        try check(value, try load(name), file: name, path: "$", into: &out)
        return out
    }

    private func load(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: name))) as! [String: Any]
    }

    private func resolve(_ ref: String, from file: String) throws -> ([String: Any], String) {
        let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let target = parts[0].isEmpty ? file : String(parts[0])
        var node: Any = try load(target)
        if parts.count > 1 {
            for key in parts[1].split(separator: "/") { node = (node as! [String: Any])[String(key)]! }
        }
        return (node as! [String: Any], target)
    }

    private func check(_ v: Any, _ s: [String: Any], file: String, path: String, into out: inout [String]) throws {
        if let ref = s["$ref"] as? String {
            let (target, f) = try resolve(ref, from: file)
            try check(v, target, file: f, path: path, into: &out)
        }
        if let types = s["type"] {
            let allowed = (types as? [String]) ?? [types as! String]
            if !allowed.contains(where: { Self.isType(v, $0) }) { out.append("\(path): expected \(allowed)"); return }
        }
        if let options = s["enum"] as? [Any], !options.contains(where: { Self.equal($0, v) }) { out.append("\(path): not in enum") }
        if let c = s["const"], !Self.equal(c, v) { out.append("\(path): expected const \(c)") }
        if let n = v as? NSNumber, !Self.isBool(v) {
            if let m = s["minimum"] as? NSNumber, n.doubleValue < m.doubleValue { out.append("\(path): below minimum") }
            if let m = s["maximum"] as? NSNumber, n.doubleValue > m.doubleValue { out.append("\(path): above maximum") }
        }
        if let str = v as? String, let m = s["minLength"] as? Int, str.count < m { out.append("\(path): shorter than \(m)") }
        if let obj = v as? [String: Any] {
            let props = s["properties"] as? [String: Any] ?? [:]
            for r in s["required"] as? [String] ?? [] where obj[r] == nil { out.append("\(path): missing \(r)") }
            for (k, value) in obj {
                if let p = props[k] as? [String: Any] { try check(value, p, file: file, path: "\(path).\(k)", into: &out) }
                else if (s["additionalProperties"] as? Bool) == false { out.append("\(path): unexpected \(k)") }
            }
        }
        if let arr = v as? [Any], let items = s["items"] as? [String: Any] {
            for (i, item) in arr.enumerated() { try check(item, items, file: file, path: "\(path)[\(i)]", into: &out) }
        }
        if let any = s["anyOf"] as? [[String: Any]] {
            var passed = false
            for branch in any {
                var e: [String] = []
                try check(v, branch, file: file, path: path, into: &e)
                if e.isEmpty { passed = true; break }
            }
            if !passed { out.append("\(path): matches none of anyOf") }
        }
    }

    static func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    static func isType(_ v: Any, _ t: String) -> Bool {
        switch t {
        case "object": v is [String: Any]
        case "array": v is [Any]
        case "string": v is String
        case "boolean": isBool(v)
        case "number": v is NSNumber && !isBool(v)
        case "integer": (v as? NSNumber).map { !isBool(v) && $0.doubleValue.rounded() == $0.doubleValue } ?? false
        case "null": v is NSNull
        default: false
        }
    }
    static func equal(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? String, let b = b as? String { return a == b }
        if let a = a as? NSNumber, let b = b as? NSNumber { return isBool(a) == isBool(b) && a == b }
        return false
    }
}
