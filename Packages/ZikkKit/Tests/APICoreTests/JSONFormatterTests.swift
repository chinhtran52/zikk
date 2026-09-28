import Testing
@testable import APICore

@Suite struct JSONFormatterTests {
    @Test func preservesKeyOrderAndStrings() {
        let pretty = JSONFormatter.prettyPrinted(#"{"z":1,"a":[1,{"s":"x, {y}: \"q\""}],"e":{},"l":[]}"#)
        #expect(pretty == """
        {
          "z": 1,
          "a": [
            1,
            {
              "s": "x, {y}: \\"q\\""
            }
          ],
          "e": {},
          "l": []
        }
        """)
    }

    @Test func rejectsInvalid() {
        #expect(JSONFormatter.prettyPrinted("{nope") == nil)
        #expect(JSONFormatter.minified("{ \"a\" : [ 1 , 2 ] }") == #"{"a":[1,2]}"#)
    }
}
