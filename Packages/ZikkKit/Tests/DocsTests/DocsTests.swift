import Testing
import Foundation
import APICore
import Interop
@testable import Docs

@Suite struct DocsTests {
    @Test func markdownRendersAndEscapesRawHTML() {
        let html = MarkdownRenderer.html("# Title\n\nSome **bold** `code`\n\n- a\n- b\n\n<script>alert(1)</script>\n\n| h | i |\n|---|---|\n| 1 | 2 |")
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<li>a</li>"))
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("<table>"))

        let hostile = MarkdownRenderer.html("[x](javascript:alert(1)) a < b & c ![i](data:image/png;base64,AA)")
        #expect(hostile.contains(##"<a href="#">x</a>"##))
        #expect(hostile.contains("a &lt; b &amp; c"))
        #expect(!hostile.contains("<img"))
    }

    @Test func documentationPage() {
        var bearer = AuthConfig(type: .bearer)
        bearer.bearer.token = "{{token}}"
        let collection = InteropCollection(
            name: "Shop <API>", description: "Welcome to the **shop**.", auth: bearer,
            variables: [Variable(key: "baseUrl", value: "https://shop.test"), Variable(key: "token", value: "secret", isSecret: true)],
            items: [
                .folder(InteropFolder(name: "Orders", description: "Order endpoints", items: [
                    .request(InteropRequest(name: "Create order", description: "Creates an order.",
                                            spec: RequestSpec(method: .post, url: "{{baseUrl}}/orders", params: [KeyValue(key: "dry", value: "1", isEnabled: false)],
                                                              body: RequestBody(mode: .raw, raw: #"{"sku":"A1"}"#, rawLanguage: .json)),
                                            examples: [InteropExample(name: "Created", request: RequestSpec(), response: ResponseSnapshot(statusCode: 201, body: Data(#"{"id":7}"#.utf8)))])),
                ])),
                .request(InteropRequest(name: "Health", spec: RequestSpec(url: "{{baseUrl}}/health", auth: .none))),
            ]
        )
        let html = DocumentationGenerator(resolver: VariableResolver(scopes: [["baseUrl": "https://shop.test", "token": "t0k"]])).html(for: collection)
        #expect(html.contains("<title>Shop &lt;API&gt; – API Documentation</title>"))
        #expect(html.contains("<strong>shop</strong>"))
        #expect(html.contains(##"<a href="#endpoint-1"><span class="method POST">POST</span>Create order</a>"##))
        #expect(html.contains("Authorization: Bearer Token (inherited)"))
        #expect(html.contains(#"<tr class="disabled"><td><code>dry</code>"#))
        #expect(html.contains("&quot;sku&quot;: &quot;A1&quot;"))
        #expect(html.contains("curl --location --request POST &#39;https://shop.test/orders&#39;"))
        #expect(html.contains("Authorization: Bearer t0k"))
        #expect(html.contains("<span class=\"status s2\">201</span>"))
        #expect(html.contains("••••••"))
        #expect(!html.contains(">secret<"))
    }
}
