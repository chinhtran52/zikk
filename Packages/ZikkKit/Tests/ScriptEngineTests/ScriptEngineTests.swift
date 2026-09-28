import Testing
import Foundation
import APICore
@testable import ScriptEngine

@Suite struct ScriptEngineTests {
    let jsonResponse = ResponseSnapshot(
        statusCode: 200,
        headers: [KeyValue(key: "Content-Type", value: "application/json; charset=utf-8"), KeyValue(key: "Set-Cookie", value: "sid=xyz; Path=/")],
        body: Data(#"{"id": 7, "name": "Rex", "tags": ["a", "b"], "owner": {"email": "a@b.c"}}"#.utf8),
        url: "https://api.test/pets/7",
        timings: ResponseTimings(total: 123)
    )

    func run(_ script: String, phase: ScriptPhase = .test, input modify: (inout ScriptInput) -> Void = { _ in }, handler: ScriptRequestHandler? = nil) async -> ScriptOutput {
        var input = ScriptInput(phase: phase, environment: [("host", "api.test")], request: RequestSpec(url: "https://{{host}}/pets/7"),
                                response: phase == .test ? jsonResponse : nil, requestName: "Get pet")
        modify(&input)
        return await ScriptEngine(timeout: .seconds(5), requestHandler: handler).run(script, input: input)
    }

    @Test func typicalPostmanTests() async {
        let output = await run("""
        pm.test("Status code is 200", function () {
            pm.response.to.have.status(200);
        });
        pm.test("Has JSON body", () => {
            const json = pm.response.json();
            pm.expect(json.name).to.eql("Rex");
            pm.expect(json.tags).to.have.lengthOf(2).and.include("a");
            pm.expect(json).to.have.nested.property("owner.email", "a@b.c");
        });
        pm.test("Content-Type is JSON", () => pm.response.to.be.json);
        pm.test("Header present", () => pm.response.to.have.header("Content-Type"));
        pm.test("Fast", () => pm.expect(pm.response.responseTime).to.be.below(500));
        pm.test("Deliberately failing", () => pm.expect(pm.response.code).to.equal(404));
        pm.test.skip("Skipped test", () => {});
        """)
        #expect(output.error == nil)
        #expect(output.tests.map(\.name) == ["Status code is 200", "Has JSON body", "Content-Type is JSON", "Header present", "Fast", "Deliberately failing", "Skipped test"])
        #expect(output.tests.map(\.passed) == [true, true, true, true, true, false, true])
        #expect(output.tests[5].error == "expected 200 to equal 404")
        #expect(output.tests[6].skipped)
    }

    @Test func variablesAcrossScopes() async {
        let output = await run("""
        const json = pm.response.json();
        pm.environment.set("petId", json.id);
        pm.globals.set("token", "t-" + json.name);
        pm.collectionVariables.set("obj", { a: 1 });
        pm.variables.set("local", "yes");
        pm.environment.unset("host");
        console.log("resolved", pm.variables.replaceIn("{{petId}}-{{token}}-{{local}}"));
        """)
        #expect(output.error == nil)
        #expect(output.environment.map(\.key) == ["petId"])
        #expect(output.environment.first?.value == "7")
        #expect(output.globals.first?.value == "t-Rex")
        #expect(output.collection.first?.value == #"{"a":1}"#)
        #expect(output.local.first?.value == "yes")
        #expect(output.logs.first?.message == "resolved 7-t-Rex-yes")
    }

    @Test func variablePrecedence() async {
        let output = await run("console.log(pm.variables.get('x'), pm.iterationData.get('row'), pm.variables.get('missing'))", input: {
            $0.globals = [("x", "g")]
            $0.environment = [("x", "e")]
            $0.data = [("row", "1"), ("x", "d")]
        })
        #expect(output.logs.first?.message == "d 1 undefined")
    }

    @Test func preRequestMutatesRequest() async {
        let output = await run("""
        pm.request.headers.add({ key: "X-Signature", value: CryptoJS.HmacSHA256("msg", "key").toString() });
        pm.request.headers.upsert({ key: "Accept", value: "application/xml" });
        pm.request.url.query.add({ key: "ts", value: "1" });
        pm.request.method = "POST";
        pm.request.body.update(JSON.stringify({ hello: _.upperCase("world") }));
        """, phase: .preRequest, input: { $0.request.headers = [KeyValue(key: "Accept", value: "*/*")] })
        #expect(output.error == nil, "\(output.error ?? "")")
        #expect(output.request.method == .post)
        #expect(output.request.url == "https://{{host}}/pets/7?ts=1")
        #expect(output.request.params.map(\.key) == ["ts"])
        #expect(output.request.headers.map(\.key) == ["Accept", "X-Signature"])
        #expect(output.request.headers[0].value == "application/xml")
        #expect(output.request.headers[1].value == "2d93cbc1be167bcb1637a4a23cbff01a7878f0c50ee833954ea5221bb1b8c628")
        #expect(output.request.body.mode == .raw)
        #expect(output.request.body.raw == #"{"hello":"WORLD"}"#)
    }

    @Test func requireModules() async {
        let output = await run("""
        const moment = require('moment');
        const uuid = require('uuid');
        const CryptoJS = require('crypto-js');
        console.log(moment.utc(0).format('YYYY-MM-DD'), uuid.v4().length, CryptoJS.MD5('a').toString(), btoa('hi'), atob('aGk='));
        """)
        #expect(output.error == nil, "\(output.error ?? "")")
        #expect(output.logs.first?.message == "1970-01-01 36 0cc175b9c0f1b6a831c399e269772661 aGk= hi")
    }

    @Test func sendRequestWithCallbackAndAwait() async {
        let handler: ScriptRequestHandler = { spec in
            ResponseSnapshot(statusCode: 201, headers: [KeyValue(key: "Content-Type", value: "application/json")],
                             body: Data(#"{"token":"abc","method":"\#(spec.method.rawValue)","header":"\#(spec.headers.first?.value ?? "")"}"#.utf8))
        }
        let output = await run("""
        pm.sendRequest({ url: "https://auth.test/token", method: "POST", header: { "X-Key": "k1" }, body: { mode: "raw", raw: "{}" } }, (err, res) => {
            pm.environment.set("token", res.json().token);
            console.log("callback", res.code, res.json().method, res.json().header);
        });
        const res = await pm.sendRequest("https://auth.test/second");
        console.log("await", res.code);
        """, phase: .preRequest, handler: handler)
        #expect(output.error == nil, "\(output.error ?? "")")
        #expect(output.environment.first { $0.key == "token" }?.value == "abc")
        #expect(Set(output.logs.map(\.message)) == ["callback 201 POST k1", "await 201"])
    }

    @Test func timersAndAsyncTests() async {
        let output = await run("""
        setTimeout(() => console.log("later"), 20);
        console.log("first");
        pm.test("async", async () => {
            await new Promise(r => setTimeout(r, 10));
            pm.expect(1).to.equal(2);
        });
        """)
        #expect(output.logs.map(\.message) == ["first", "later"])
        #expect(output.tests.first?.passed == false)
        #expect(output.tests.first?.error == "expected 1 to equal 2")
    }

    @Test func legacyAPIsAndSetNextRequest() async {
        let output = await run("""
        tests["Body contains Rex"] = responseBody.indexOf("Rex") !== -1;
        tests["Is 404"] = responseCode.code === 404;
        postman.setEnvironmentVariable("legacy", "1");
        postman.setNextRequest("Delete pet");
        """)
        #expect(output.tests.map(\.passed) == [true, false])
        #expect(output.environment.contains { $0.key == "legacy" })
        #expect(output.nextRequest == .named("Delete pet"))

        let stop = await run("postman.setNextRequest(null); pm.execution.skipRequest();", phase: .preRequest)
        #expect(stop.nextRequest == .stop)
        #expect(stop.skipRequest)
    }

    @Test func reportsErrorsWithoutLosingState() async {
        let output = await run("""
        pm.environment.set("before", "1");
        console.log("about to fail");
        undefinedFunction();
        """)
        #expect(output.error?.contains("ReferenceError") == true)
        #expect(output.environment.contains { $0.key == "before" })
        #expect(output.logs.map(\.message) == ["about to fail"])
    }

    @Test func cookiesAndInfo() async {
        let output = await run("console.log(pm.response.cookies.get('sid'), pm.info.eventName, pm.info.requestName, pm.cookies.has('a'))",
                               input: { $0.cookies = [("a", "1")] })
        #expect(output.logs.first?.message == "xyz test Get pet true")
    }

    @Test func infiniteAsyncWorkTimesOut() async {
        let output = await ScriptEngine(timeout: .milliseconds(300)).run("setInterval(() => {}, 10);", input: ScriptInput(phase: .test, request: RequestSpec()))
        #expect(output.error?.contains("timed out") == true)
    }
}
