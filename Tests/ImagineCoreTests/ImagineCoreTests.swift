import XCTest
@testable import ImagineCore

final class AspectTests: XCTestCase {
    func testSizesKeepRatioAndMultiple() {
        for a in AspectRatio.allCases {
            let s = a.size(pixels: 1024 * 1024, multiple: 32)
            XCTAssertEqual(s.width % 32, 0); XCTAssertEqual(s.height % 32, 0)
            XCTAssertEqual(Double(s.width) / Double(s.height), a.ratio, accuracy: 0.08, a.rawValue)
            XCTAssertLessThan(abs(Double(s.width * s.height) - 1_048_576) / 1_048_576, 0.12, a.rawValue)
        }
        let sq = AspectRatio.square.size()
        XCTAssertEqual(sq.width, 1024); XCTAssertEqual(sq.height, 1024)
    }

    func testZImageResolutionMatchesRatio() {
        for a in AspectRatio.allCases {
            let r = a.zImageResolution
            XCTAssertTrue(r.contains("( \(a.rawValue) )"), r)
            let dims = r.split(separator: " ")[0].split(separator: "x").compactMap { Double($0) }
            XCTAssertEqual(dims[0] / dims[1], a.ratio, accuracy: 0.03)
        }
    }

    func testVideoSizeSmall() {
        let s = HFSpaceProvider.videoSize(.tall)
        XCTAssertLessThan(s.width, s.height)
        XCTAssertLessThanOrEqual(s.width * s.height, 400_000)
        XCTAssertEqual(s.width % 32, 0)
    }
}

final class SSETests: XCTestCase {
    func testParsesGradioStream() {
        let text = "event: heartbeat\ndata: null\n\nevent: complete\ndata: [{\"url\": \"https://x.hf.space/gradio_api/file=/tmp/a.webp\"}, 5]\n\n"
        let ev = SSEParser.parse(text)
        XCTAssertEqual(ev.count, 2)
        XCTAssertEqual(ev[1].event, "complete")
        let d = try! GradioClient.handle(ev[1], status: nil)
        XCTAssertEqual(d?.count, 2)
    }

    func testErrorEvents() {
        XCTAssertThrowsError(try GradioClient.handle(SSEEvent(event: "error", data: "null"), status: nil)) { e in
            guard case GenError.server = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try GradioClient.handle(SSEEvent(event: "error", data: "\"You have exceeded your ZeroGPU quota\""), status: nil)) { e in
            guard case GenError.rateLimited = e else { return XCTFail("\(e)") }
        }
    }

    func testQueueStatus() {
        final class Box: @unchecked Sendable { var s: GenStatus? }
        let box = Box()
        _ = try? GradioClient.handle(SSEEvent(event: "generating", data: "{\"msg\":\"estimation\",\"rank\":2,\"rank_eta\":9.5}"), status: { box.s = $0 })
        XCTAssertEqual(box.s, .queued(position: 3, eta: 9.5))
    }
}

final class GradioResultTests: XCTestCase {
    let host = URL(string: "https://h.hf.space")!

    func testZImageGallery() throws {
        let json = #"[[{"image": {"path": "/tmp/gradio/x/image.png", "url": "https://h.hf.space/gradio_api/file=/tmp/gradio/x/image.png", "meta": {"_type": "gradio.FileData"}}, "caption": null}], "214231", 214231]"#
        let arr = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [Any]
        XCTAssertEqual(GradioClient.firstFileURL(in: arr, host: host, prefix: "/gradio_api")?.absoluteString, "https://h.hf.space/gradio_api/file=/tmp/gradio/x/image.png")
    }

    func testVideoResultAndPathOnly() throws {
        let json = #"[{"video": {"path": "/tmp/v.mp4", "url": null, "meta": {"_type": "gradio.FileData"}}, "subtitles": null}, 3]"#
        let arr = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [Any]
        XCTAssertEqual(GradioClient.firstFileURL(in: arr, host: host, prefix: "/gradio_api")?.absoluteString, "https://h.hf.space/gradio_api/file=/tmp/v.mp4")
    }

    func testPayloads() {
        var r = GenRequest(prompt: "a fox"); r.seed = 7; r.aspect = .tall
        let z = HFSpaceProvider(.zImageTurbo).payload(r, file: nil)
        XCTAssertEqual(z.api, "generate"); XCTAssertEqual(z.data.count, 7)
        XCTAssertEqual(z.data[1] as? String, "720x1280 ( 9:16 )"); XCTAssertEqual(z.data[2] as? Int, 7)
        XCTAssertEqual(z.data[5] as? Bool, false)
        let f = HFSpaceProvider(.fluxSchnell).payload(r, file: nil)
        XCTAssertEqual(f.data.count, 6); XCTAssertEqual(f.api, "infer")
        let v = HFSpaceProvider(.ltx23).payload(r, file: nil)
        XCTAssertEqual(v.data.count, 8); XCTAssertTrue(v.data[0] is NSNull)
        XCTAssertEqual(v.data[6] as? Int, HFSpaceProvider.videoSize(.tall).height)
        let l = HFSpaceProvider(.ltxVideo).payload(r, file: nil)
        XCTAssertEqual(l.data.count, 13); XCTAssertEqual(l.data[6] as? String, "text-to-video")
        // Payloads must be JSON-serializable.
        for p in [z, f, v, l] { XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["data": p.data])) }
    }

    func testSupports() {
        let s = ProviderSettings()
        var r = GenRequest(prompt: "x")
        XCTAssertTrue(HFSpaceProvider(.zImageTurbo).supports(r, settings: s))
        XCTAssertFalse(HFSpaceProvider(.fluxKontext).supports(r, settings: s))
        r.inputImage = Data([1, 2, 3])
        XCTAssertFalse(HFSpaceProvider(.zImageTurbo).supports(r, settings: s))
        XCTAssertTrue(HFSpaceProvider(.fluxKontext).supports(r, settings: s))
        XCTAssertTrue(HFSpaceProvider(.ltx23).supports(r, settings: s))
        XCTAssertFalse(A1111Provider().supports(r, settings: s))
    }
}

final class PollinationsTests: XCTestCase {
    func testClassicAndKeyedURLs() {
        var r = GenRequest(prompt: "red fox & snow?"); r.seed = 3
        let c = PollinationsProvider.url(for: r, key: "")
        XCTAssertTrue(c.absoluteString.hasPrefix("https://image.pollinations.ai/prompt/red%20fox%20%26%20snow%3F?"))
        XCTAssertTrue(c.absoluteString.contains("seed=3"))
        let k = PollinationsProvider.url(for: r, key: " sk_abc ")
        XCTAssertTrue(k.absoluteString.hasPrefix("https://gen.pollinations.ai/image/"))
        XCTAssertTrue(k.absoluteString.contains("model=zimage"))
        XCTAssertFalse(k.absoluteString.contains("sk_abc"), "key goes in the header, not the URL")
    }
}

final class ServerTests: XCTestCase {
    func testComfyFillTypedAndText() throws {
        let g = try ComfyUI.fill(ComfyUI.defaultImageWorkflow, values: ["SEED": 42, "STEPS": 4, "CFG": 1.0, "WIDTH": 768, "HEIGHT": 1344, "PROMPT": "a \"quoted\" fox", "NEGATIVE": "", "CHECKPOINT": "flux.safetensors"])
        let ks = (g["3"] as! [String: Any])["inputs"] as! [String: Any]
        XCTAssertEqual(ks["seed"] as? Int, 42)
        XCTAssertEqual(((g["5"] as! [String: Any])["inputs"] as! [String: Any])["height"] as? Int, 1344)
        XCTAssertEqual(((g["6"] as! [String: Any])["inputs"] as! [String: Any])["text"] as? String, "a \"quoted\" fox")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: g))
        let inline = try ComfyUI.fill(#"{"1":{"inputs":{"text":"style: {{PROMPT}}, 4k"}}}"#, values: ["PROMPT": "cat"])
        XCTAssertEqual(((inline["1"] as! [String: Any])["inputs"] as! [String: Any])["text"] as? String, "style: cat, 4k")
        XCTAssertThrowsError(try ComfyUI.fill("not json", values: [:]))
    }

    func testComfyFirstOutputPrefersVideo() {
        let h: [String: Any] = ["outputs": ["9": ["images": [["filename": "a.png", "subfolder": "", "type": "output"]]],
                                            "12": ["gifs": [["filename": "v.mp4", "subfolder": "", "type": "output"]]]]]
        XCTAssertEqual(ComfyUI.firstOutput(h)?.filename, "v.mp4")
        XCTAssertNil(ComfyUI.firstOutput([:]))
    }

    func testA1111Body() {
        var r = GenRequest(prompt: "p"); r.aspect = .wide
        let b = A1111Provider.body(r, initB64: "abc")
        XCTAssertEqual(b["init_images"] as? [String], ["abc"])
        XCTAssertGreaterThan(b["width"] as! Int, b["height"] as! Int)
    }

    func testHordeBody() {
        var r = GenRequest(prompt: "p"); r.negative = "blurry"
        let b = HordeProvider.body(r, sourceB64: nil)
        XCTAssertEqual(b["prompt"] as? String, "p ### blurry")
        XCTAssertEqual(b["censor_nsfw"] as? Bool, false)
        let p = b["params"] as! [String: Any]
        XCTAssertEqual((p["width"] as! Int) % 64, 0)
        for a in AspectRatio.allCases {
            let q = HordeProvider.body({ var x = r; x.aspect = a; return x }(), sourceB64: nil)["params"] as! [String: Any]
            XCTAssertLessThanOrEqual((q["width"] as! Int) * (q["height"] as! Int), 576 * 576, a.rawValue)
        }
    }

    func testNormalizedBase() {
        XCTAssertEqual(normalizedBase("1.2.3.4:8188/")?.absoluteString, "http://1.2.3.4:8188")
        XCTAssertNil(normalizedBase("  "))
    }
}

struct FakeProvider: MediaProvider {
    var id: String
    var name: String { id }
    var kind: MediaKind = .image
    var usesHFQuota: Bool = false
    var error: GenError?
    var log: Log
    final class Log: @unchecked Sendable { var calls: [String] = [] }
    func supports(_ req: GenRequest, settings: ProviderSettings) -> Bool { true }
    func run(_ req: GenRequest, settings: ProviderSettings, status: StatusHandler?) async throws -> GenOutput {
        log.calls.append(id)
        if let error { throw error }
        return GenOutput(data: Data([1]), fileExtension: "png", seed: 1, provider: id)
    }
}

final class FallbackTests: XCTestCase {
    func testFallsThroughAndSkipsHFAfterQuota() async throws {
        let log = FakeProvider.Log()
        let list: [MediaProvider] = [
            FakeProvider(id: "hf1", usesHFQuota: true, error: .rateLimited("quota"), log: log),
            FakeProvider(id: "hf2", usesHFQuota: true, log: log),
            FakeProvider(id: "poll", error: .http(503, "busy"), log: log),
            FakeProvider(id: "horde", log: log)
        ]
        let r = try await Fallback.run(list, request: GenRequest(prompt: "x"), settings: ProviderSettings(), status: nil)
        XCTAssertEqual(r.output.provider, "horde")
        XCTAssertEqual(log.calls, ["hf1", "poll", "horde"])
        XCTAssertEqual(r.failures.count, 2)
    }

    func testAllFail() async {
        let log = FakeProvider.Log()
        do {
            _ = try await Fallback.run([FakeProvider(id: "a", error: .server("x"), log: log)], request: GenRequest(prompt: "x"), settings: ProviderSettings(), status: nil)
            XCTFail("should throw")
        } catch { XCTAssertTrue(error.localizedDescription.contains("a: x")) }
    }

    func testChains() {
        var s = ProviderSettings()
        XCTAssertEqual(Catalog.imageChain(.auto, settings: s, editing: false).first?.id, "hf.zImageTurbo")
        XCTAssertEqual(Catalog.imageChain(.fluxDev, settings: s, editing: false).first?.id, "hf.fluxDev")
        XCTAssertEqual(Catalog.imageChain(.auto, settings: s, editing: true).first?.id, "hf.fluxKontext")
        XCTAssertEqual(Catalog.videoChain(.auto, settings: s, hasImage: false).map(\.id), ["hf.ltx23", "hf.ltxVideo"])
        XCTAssertEqual(Catalog.videoChain(.auto, settings: s, hasImage: true).map(\.id), ["hf.ltx23"])
        s.a1111URL = "10.0.0.2:7860"
        XCTAssertEqual(Catalog.imageChain(.server, settings: s, editing: false).first?.id, "server.a1111")
        XCTAssertEqual(Catalog.imageChain(.auto, settings: s, editing: false).last?.id, "server.a1111")
        let ids = Catalog.imageChain(.zImage, settings: s, editing: false).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testSniff() {
        XCTAssertEqual(HTTP.sniffExtension(Data([0xFF, 0xD8, 0xFF]), fallback: "x"), "jpg")
        XCTAssertEqual(HTTP.sniffExtension(Data([0x89, 0x50, 0x4E, 0x47]), fallback: "x"), "png")
        XCTAssertEqual(HTTP.sniffExtension(Data("RIFF\0\0\0\0WEBP".utf8), fallback: "x"), "webp")
        XCTAssertEqual(HTTP.sniffExtension(Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70]), fallback: "x"), "mp4")
    }
}
