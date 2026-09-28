import Testing
import Foundation
import APICore
import Interop
@testable import SpecKit

func fixture(_ name: String, _ ext: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct SpecParsingTests {
    @Test func parsesWithLinesAndResolvesRefs() throws {
        let document = try SpecDocument(text: try fixture("petstore", "yaml"))
        #expect(document.version == .openAPI30)
        #expect(document.title == "Petstore")
        #expect(document.baseURL == "https://api.petstore.test/v1")
        #expect(document.operations.map { "\($0.method) \($0.path)" } == ["get /pets", "post /pets", "get /pets/{petId}", "delete /pets/{petId}", "post /login"])
        #expect(document.operations[0].line == 18)
        let pet = try #require(document.node(at: "#/components/schemas/Pet"))
        #expect(pet["allOf"]?.items.count == 2)
        let parameters = document.parameters(of: document.operations[0])
        #expect(parameters.map { $0["name"]?.string } == ["limit", "X-Trace-Id"])
        #expect(document.parameters(of: document.operations[2]).first?["name"]?.string == "petId")
    }

    @Test func swagger2() throws {
        let document = try SpecDocument(text: try fixture("swagger2", "json"))
        #expect(document.version == .swagger2)
        #expect(document.baseURL == "https://legacy.test/api")
    }

    @Test func syntaxErrorsCarryLines() {
        let diagnostics = SpecValidator.validate("openapi: 3.0.0\ninfo:\n  title: [unclosed\n")
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message.hasPrefix("Syntax error") == true)
        #expect((diagnostics.first?.line ?? 0) >= 3)
    }

    @Test func schemaExamples() throws {
        let document = try SpecDocument(text: try fixture("petstore", "yaml"))
        let example = SchemaExample.generate(document.node(at: "#/components/schemas/Pet"), in: document) as? [String: Any]
        #expect(example?["name"] as? String == "Rex")
        #expect(example?["id"] as? String == "3fa85f64-5717-4562-b3fc-2c963f66afa6")
    }
}

@Suite struct SpecValidatorTests {
    @Test func validFixtureHasNoErrors() throws {
        let diagnostics = SpecValidator.validate(try fixture("petstore", "yaml"))
        #expect(diagnostics.filter { $0.severity == .error }.isEmpty, "\(diagnostics)")
    }

    @Test func reportsProblemsOnTheirLines() {
        let text = """
        openapi: 3.0.0
        info:
          title: Broken
        paths:
          pets:
            get:
              operationId: a
              responses:
                '200':
                  description: ok
          /pets/{id}:
            get:
              operationId: a
              parameters:
                - name: other
                  in: path
                  required: true
                - name: q
                  in: body
              responses:
                '999':
                  description: bad
                '200':
                  $ref: '#/components/responses/Missing'
        """
        let diagnostics = SpecValidator.validate(text)
        func line(_ fragment: String) -> Int? { diagnostics.first { $0.message.contains(fragment) }?.line }
        #expect(line("info.version") == 2)
        #expect(line("must begin with `/`") == 5)
        #expect(line("Duplicate operationId") == 13)
        #expect(line("`other` does not appear") == 15)
        #expect(line("Invalid parameter location `body`") == 19)
        #expect(line("`{id}` is not declared") == 12)
        #expect(line("Invalid response status `999`") == 21)
        #expect(line("cannot be resolved") == 24)
    }

    @Test func outline() throws {
        let outline = SpecOutline(try SpecDocument(text: try fixture("petstore", "yaml")))
        #expect(outline.items.map(\.title) == ["Info", "Servers", "Paths", "Schemas", "Tags"])
        let paths = try #require(outline.items.first { $0.title == "Paths" })
        #expect(paths.children?.map(\.title) == ["/pets", "/pets/{petId}", "/login"])
        #expect(paths.children?.first?.children?.map(\.title) == ["GET", "POST"])
    }
}

@Suite struct OpenAPIImportTests {
    @Test func importsPetstore() throws {
        let collection = OpenAPIImporter.collection(from: try SpecDocument(text: try fixture("petstore", "yaml")))
        #expect(collection.name == "Petstore")
        #expect(collection.variables.first?.value == "https://api.petstore.test/v1")
        #expect(collection.auth.type == .bearer)
        // Untagged operations stay at the collection root.
        #expect(collection.items.map(\.name) == ["pets", "Delete pet", "Login"])
        guard case .folder(let pets) = collection.items[0] else { Issue.record("expected folder"); return }
        #expect(pets.items.map(\.name) == ["List pets", "Create pet", "Get pet"])
        let requests = collection.allRequests
        let list = requests[0]
        #expect(list.spec.url == "{{baseUrl}}/pets")
        #expect(list.spec.params.map(\.key) == ["limit"])
        #expect(list.spec.params.first?.value == "20")
        #expect(list.spec.params.first?.isEnabled == false)
        #expect(list.spec.headers.map(\.key) == ["X-Trace-Id"])
        let create = requests[1]
        #expect(create.spec.body.mode == .raw)
        let body = try #require(try JSONSerialization.jsonObject(with: Data(create.spec.body.raw.utf8)) as? [String: Any])
        #expect(body["name"] as? String == "Rex")
        #expect(create.examples.map(\.response.statusCode) == [201, 500])
        let get = requests[2]
        #expect(get.spec.url == "{{baseUrl}}/pets/:petId")
        #expect(get.spec.pathVariables.first?.value == "3fa85f64-5717-4562-b3fc-2c963f66afa6" || get.spec.pathVariables.first?.value == "")
        #expect(get.examples.first?.response.bodyText?.contains("Rex") == true)
        #expect(requests[3].spec.auth.type == .none)
        let login = requests[4]
        #expect(login.spec.body.mode == .urlEncoded)
        #expect(login.spec.body.urlEncoded.map(\.key) == ["username", "password"])
        #expect(login.spec.body.urlEncoded.map(\.isEnabled) == [true, false])
    }

    @Test func importsSwagger2() throws {
        let collection = OpenAPIImporter.collection(from: try SpecDocument(text: try fixture("swagger2", "json")))
        #expect(collection.auth.type == .apiKey)
        #expect(collection.auth.apiKey.key == "X-Key")
        let requests = collection.allRequests
        #expect(requests.map(\.spec.url) == ["{{baseUrl}}/users/:id", "{{baseUrl}}/users/:id"])
        #expect(requests[0].spec.params.first?.value == "all")
        #expect(requests[1].spec.body.mode == .raw)
        #expect(requests[1].spec.body.raw.contains("user@example.com"))
    }
}

@Suite struct ContractTests {
    let json = [KeyValue(key: "Content-Type", value: "application/json")]

    func validate(_ method: String, _ url: String, _ status: Int, _ body: String, headers: [KeyValue]? = nil) throws -> ContractValidator.Result {
        let document = try SpecDocument(text: try fixture("petstore", "yaml"))
        return ContractValidator(document: document).validate(method: method, url: url, response: ResponseSnapshot(statusCode: status, headers: headers ?? json + [KeyValue(key: "X-Total", value: "1")], body: Data(body.utf8)))
    }

    @Test func passingResponse() throws {
        let result = try validate("GET", "https://api.petstore.test/v1/pets", 200, #"[{"id": "3fa85f64-5717-4562-b3fc-2c963f66afa6", "name": "Rex", "tag": null}]"#)
        #expect(result.operation == "GET /pets")
        #expect(result.issues.isEmpty, "\(result.issues)")
    }

    @Test func schemaViolations() throws {
        let result = try validate("GET", "https://api.petstore.test/v1/pets", 200, #"[{"name": "", "tag": 5}]"#, headers: json)
        #expect(Set(result.issues) == [
            "Missing required response header `X-Total`",
            "$[0]: missing required property `id`",
            "$[0].name: must be at least 1 characters",
            "$[0].tag: expected string but found integer",
        ])
    }

    @Test func templatedPathAndDefaultResponse() throws {
        let error = try validate("POST", "https://api.petstore.test/v1/pets", 400, #"{"code": 5, "message": "bad"}"#)
        #expect(error.operation == "POST /pets")
        #expect(error.issues == ["$.code: must be >= 100"])
        let get = try validate("GET", "https://api.petstore.test/v1/pets/abc", 200, #"{"id": "not-a-uuid", "name": "x"}"#)
        #expect(get.operation == "GET /pets/{petId}")
        #expect(get.issues == ["$.id: is not a valid uuid"])
    }

    @Test func undocumented() throws {
        #expect(try validate("PATCH", "https://api.petstore.test/v1/pets", 200, "{}").operation == nil)
        #expect(try validate("DELETE", "https://api.petstore.test/v1/pets/1", 200, "").issues.first?.contains("Status 200 is not documented") == true)
        #expect(try validate("GET", "https://api.petstore.test/v1/pets/1", 200, "<html>", headers: [KeyValue(key: "Content-Type", value: "text/html")]).issues.first?.contains("Content-Type `text/html` is not documented") == true)
    }
}

@Suite struct ExportAndSyncTests {
    @Test func exportRoundTrip() throws {
        let original = OpenAPIImporter.collection(from: try SpecDocument(text: try fixture("petstore", "yaml")))
        let yaml = OpenAPIExporter.yaml(from: original)
        let diagnostics = SpecValidator.validate(yaml)
        #expect(diagnostics.filter { $0.severity == .error }.isEmpty, "\(diagnostics)\n\(yaml)")
        let reimported = OpenAPIImporter.collection(from: try SpecDocument(text: yaml))
        #expect(reimported.allRequests.map { SpecSync.key(method: $0.spec.method, url: $0.spec.url) }
                == original.allRequests.map { SpecSync.key(method: $0.spec.method, url: $0.spec.url) })
        #expect(reimported.auth.type == .bearer)
        #expect(SpecSync.diff(spec: reimported, collection: original).filter { $0.kind != .modified }.isEmpty)
    }

    @Test func diffAndMerge() throws {
        let spec = OpenAPIImporter.collection(from: try SpecDocument(text: try fixture("petstore", "yaml")))
        var existing = spec
        // Remove "Login", add a stale endpoint, and edit a request.
        existing.items.removeLast()
        guard case .folder(var pets) = existing.items[0], case .request(var list) = pets.items[0] else { Issue.record("fixture"); return }
        list.spec.params = [KeyValue(key: "page", value: "1")]
        list.spec.url = "https://custom.host/v1/pets?page=1"
        list.spec.testScript = "pm.test('keep')"
        pets.items[0] = .request(list)
        pets.items.append(.request(InteropRequest(name: "Old", spec: RequestSpec(method: .get, url: "{{baseUrl}}/old"))))
        existing.items[0] = .folder(pets)

        let changes = SpecSync.diff(spec: spec, collection: existing)
        #expect(changes.map(\.kind) == [.added, .modified, .removed])
        #expect(changes[0].key == "POST /login")
        #expect(changes[1].details == ["Query params: +limit −page"])
        #expect(changes[2].key == "GET /old")

        let merged = SpecSync.merge(list.spec, with: try #require(changes[1].request).spec, basePath: SpecSync.basePath(of: spec))
        #expect(merged.params.map(\.key) == ["limit"])
        #expect(merged.url == "https://custom.host/v1/pets")
        #expect(merged.testScript == "pm.test('keep')")
    }
}

@Suite struct OpenAPIFormDataNotesTests {
    @Test func formDataNotesBecomePropertyDescriptions() throws {
        let body = RequestBody(mode: .formData, formData: [FormDataField(key: "utters", value: "hi", notes: "One utterance per line"),
                                                            FormDataField(key: "file", kind: .file, notes: "CSV export")])
        let collection = InteropCollection(name: "Bot", items: [.request(InteropRequest(name: "Upload utters", spec: RequestSpec(method: .post, url: "https://x/upload", body: body)))])
        let yaml = OpenAPIExporter.yaml(from: collection)
        let fields = try #require(OpenAPIImporter.collection(from: try SpecDocument(text: yaml)).allRequests.first?.spec.body.formData)
        #expect(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.notes) }) == ["utters": "One utterance per line", "file": "CSV export"])
    }
}
