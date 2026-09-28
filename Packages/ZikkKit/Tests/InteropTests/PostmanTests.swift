import Testing
import Foundation
import APICore
@testable import Interop

@Suite struct PostmanTests {
    func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "postman_v21", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func importsCollection() throws {
        let collection = try PostmanCollection.decode(try fixture())
        #expect(collection.name == "Pet Store")
        #expect(collection.description == "Sample **collection**")
        #expect(collection.auth.type == .bearer)
        #expect(collection.auth.bearer.token == "{{token}}")
        #expect(collection.preRequestScript == "pm.variables.set('ts', Date.now());")
        #expect(collection.testScript.contains("pm.response.to.have.status(200);"))
        #expect(collection.variables.map(\.key) == ["baseUrl", "token"])
        #expect(collection.variables[1].isSecret)
        #expect(collection.items.map(\.name) == ["Pets", "Upload", "Login"])
        #expect(collection.allRequests.count == 5)

        guard case .folder(let pets) = collection.items[0] else { Issue.record("expected folder"); return }
        #expect(pets.description == "Pet operations")
        guard case .request(let list) = pets.items[0] else { Issue.record("expected request"); return }
        #expect(list.spec.url == "{{baseUrl}}/pets?limit=10")
        #expect(list.spec.params.map(\.key) == ["limit", "offset"])
        #expect(list.spec.params[1].isEnabled == false)
        #expect(list.spec.headers[1].isEnabled == false)
        #expect(list.spec.auth.type == .inherit)
        #expect(list.description == "Returns all pets")
        #expect(list.examples.first?.response.statusCode == 200)
        #expect(list.examples.first?.response.bodyText == #"[{"id": 1, "name": "Rex"}]"#)

        guard case .request(let get) = pets.items[1] else { return }
        #expect(get.spec.auth.type == .none)
        #expect(get.spec.pathVariables.first?.value == "42")

        guard case .request(let create) = pets.items[2] else { return }
        #expect(create.spec.method == .post)
        #expect(create.spec.body.mode == .raw)
        #expect(create.spec.body.rawLanguage == .json)
        #expect(create.spec.testScript.contains("created"))

        guard case .request(let upload) = collection.items[1] else { return }
        #expect(upload.spec.auth.type == .apiKey)
        #expect(upload.spec.auth.apiKey.key == "X-API-Key")
        #expect(upload.spec.body.formData.map(\.kind) == [.text, .file])
        #expect(upload.spec.body.formData[1].file?.path == "/tmp/photo.png")

        guard case .request(let login) = collection.items[2] else { return }
        #expect(login.spec.body.mode == .urlEncoded)
        #expect(login.spec.body.urlEncoded.map(\.key) == ["user", "pass"])
    }

    @Test func roundTripsThroughExport() throws {
        let original = try PostmanCollection.decode(try fixture())
        let exported = PostmanCollection.encode(original)
        let reimported = try PostmanCollection.decode(exported)
        // Row ids are regenerated on import, so compare the exported JSON instead.
        #expect(normalized(PostmanCollection.encode(reimported)) == normalized(exported))
        #expect(reimported.allRequests.map(\.spec.url) == original.allRequests.map(\.spec.url))
    }

    @Test func environmentRoundTrip() throws {
        let data = Data(#"{"id":"1","name":"Dev","values":[{"key":"host","value":"localhost","enabled":true},{"key":"pw","value":"x","type":"secret","enabled":false}],"_postman_variable_scope":"environment"}"#.utf8)
        let environment = try PostmanEnvironment.decode(data)
        #expect(environment.name == "Dev")
        #expect(environment.variables.map(\.isSecret) == [false, true])
        #expect(environment.variables[1].isEnabled == false)
        let again = try PostmanEnvironment.decode(PostmanEnvironment.encode(environment))
        #expect(normalized(PostmanEnvironment.encode(again)) == normalized(PostmanEnvironment.encode(environment)))
    }

    /// JSON text with random ids removed.
    func normalized(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).replacing(/"(_postman_id|id)" : "[^"]*"/, with: "")
    }

    @Test func rejectsOtherJSON() {
        #expect(throws: InteropError.self) { try PostmanCollection.decode(Data(#"{"openapi":"3.0.0"}"#.utf8)) }
        #expect(throws: InteropError.invalidJSON) { try PostmanCollection.decode(Data("nope".utf8)) }
    }
}
