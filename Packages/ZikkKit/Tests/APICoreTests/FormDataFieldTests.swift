import Testing
import Foundation
@testable import APICore

@Suite struct FormDataFieldTests {
    @Test func decodesStoredFieldsWithoutNotes() throws {
        let stored = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","key":"file","kind":"file","value":"","contentType":"image/png","isEnabled":false}"#
        let field = try JSONDecoder().decode(FormDataField.self, from: Data(stored.utf8))
        #expect(field.key == "file" && field.kind == .file && field.contentType == "image/png" && !field.isEnabled)
        #expect(field.notes == "")
    }

    @Test func notesRoundTrip() throws {
        let field = FormDataField(key: "utters", value: "hello", notes: "One utterance per line")
        let decoded = try JSONDecoder().decode(FormDataField.self, from: try JSONEncoder().encode(field))
        #expect(decoded == field)
    }
}
