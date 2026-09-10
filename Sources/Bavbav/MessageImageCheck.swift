import AppKit
import SwiftUI
import BavbavCore
import ImageIO

private final class ImageCheckProtocol: URLProtocol {
    static var payload = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mime = request.url!.path == "/bad" ? "text/html" : "image/png"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
enum MessageImageCheck {
    static func run() async -> Bool {
        var failures: [String] = []; var count = 0
        func expect(_ value: Bool, _ label: String) { count += 1; if !value { failures.append(label) } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bavbav-image-check-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("test image.png")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 900, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor(calibratedRed: 0.03, green: 0.12, blue: 0.18, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 1600, height: 900).fill()
            NSColor(calibratedRed: 0.18, green: 0.82, blue: 0.66, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 300, y: 220, width: 460, height: 460)).fill()
            NSColor(calibratedRed: 0.34, green: 0.42, blue: 0.9, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 850, y: 220, width: 440, height: 460), xRadius: 70, yRadius: 70).fill()
            NSGraphicsContext.restoreGraphicsState()
            let png = bitmap.representation(using: .png, properties: [:])!
            try png.write(to: file)
            let dataURL = "data:image/png;base64," + png.base64EncodedString()
            let encoded = MessageImagePayload.images(in: ["type": "imageGeneration", "result": png.base64EncodedString()], directory: directory)
            expect(encoded.count == 1 && !encoded[0].source.contains("base64"), "encoded result becomes lightweight local reference")
            let again = MessageImagePayload.persist(dataURL: dataURL, directory: directory)
            expect(again?.path == encoded.first?.source, "content-addressed payload deduplication")
            expect(MessageImagePayload.persist(dataURL: "data:image/svg+xml;base64,AAAA", directory: directory) == nil, "active/vector payload rejected")
            expect(MessageImagePayload.persist(dataURL: "data:image/png;base64,???", directory: directory) == nil, "invalid base64 rejected")
            for type in ["dynamicToolCall", "functionCallOutput", "mcpToolCall"] {
                let part: [String: Any] = ["type": "inputImage", "imageUrl": file.path]
                let parsed = MessageImagePayload.images(in: ["type": type, "contentItems": [part], "output": [part], "result": ["content": [part]]], directory: directory)
                expect(parsed.first?.source == file.path, "typed tool image: \(type)")
            }
            let markdown = "Önizleme:\n\n![Renkler](<\(file.path)>)"
            expect(MessageImageReferences.markdown(markdown).first?.source == file.path, "Markdown spaces and alt text")
            expect(MessageImageReferences.markdown("`![not](x.png)`\n```\n![not](x.png)\n```").isEmpty, "code examples never become image IO")
            expect(MessageImageReferences.markdown("[normal](https://example.com/photo.png)").isEmpty, "ordinary links remain links")
            expect(MessageImageReferences.localURL("test%20image.png", directory: directory.path) == file, "project-relative image resolution")
            expect(MessageImageReferences.localURL("sandbox:/mnt/data/test.png", directory: directory.path) == nil, "cloud artifact is not invented locally")
            expect(MessageImageReferences.remoteURL("https://example.com/x.png") != nil, "HTTPS remote image accepted")
            expect(MessageImageReferences.remoteURL("http://example.com/x.png") == nil, "cleartext remote refused")
            expect(MessageImageReferences.remoteURL("https://user:secret@example.com/x.png") == nil, "credential-bearing URL refused")
            let loader = MessageImageLoader()
            let image = await loader.load(source: file.path, directory: nil)
            expect(image != nil && image!.width <= 1200 && image!.height <= 1200, "local photo decoded off-main and downsampled")
            expect(await loader.load(source: "missing.png", directory: directory.path) == nil, "missing file has fallback")
            expect(MessageImageLoader.decode(Data("not an image".utf8)) == nil, "invalid raster is rejected")
            expect(MessageImageLoader.decode(Data(count: MessageImagePayload.maximumBytes + 1)) == nil, "encoded-byte limit")
            ImageCheckProtocol.payload = png
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ImageCheckProtocol.self]
            let downloaded = await RemoteMessageImage.fetch(URL(string: "https://fixture.invalid/ok")!, configuration: config)
            expect(downloaded == png, "remote load uses bounded native transport (offline URLProtocol)")
            let rejected = await RemoteMessageImage.fetch(URL(string: "https://fixture.invalid/bad")!, configuration: config)
            expect(rejected == nil, "non-image response rejected")
            let old = Data(#"{"id":"old","role":"agent","text":"hello","kind":"agent"}"#.utf8)
            expect(try JSONDecoder().decode(CodexMessage.self, from: old).images == nil, "old history remains decodable")
            let message = CodexMessage(id: "photo", role: .agent, text: markdown, images: nil)
            expect(try JSONDecoder().decode(CodexMessage.self, from: JSONEncoder().encode(message)) == message, "message storage round trip")
            let tool = CodexMessage(id: "tool", role: .agent, text: "JSON", kind: .mcpTool, images: encoded)
            expect(tool.isChatVisible && CodexMessageKind.image.isChatVisible, "images survive commands-off filtering")
            expect(ChatTimeline.visible(activity: [tool], conversation: [], commandsVisible: false) == [tool],
                   "timeline retains image-bearing tools with commands off")

            if ProcessInfo.processInfo.environment["BAVBAV_CODEX_BIN"]?.hasSuffix("BavbavFakeCodex") == true {
                setenv("BAVBAV_IMAGE_FIXTURE_PATH", file.path, 1)
                let client = CodexAppServer()
                do {
                    let history = try await client.readThreadActivity(id: "image-fixture")
                    expect(history.count == 4 && history.prefix(3).allSatisfy { $0.images?.first?.source == file.path },
                           "real app-server parsing retains viewed, generated, and tool images")
                    expect(history.allSatisfy(\.isChatVisible), "history image rows remain chat visible")
                } catch { failures.append("protocol: \(error)") }
                await client.shutdown()
                unsetenv("BAVBAV_IMAGE_FIXTURE_PATH")
            } else { failures.append("image check requires fake app server") }

            let host = NSHostingView(rootView: MessageBlock(message: message).padding(16)
                .background(BavbavTheme.background).frame(width: 640))
            let window = OverlayPanel(kind: .detail, contentRect: NSRect(x: 0, y: 0, width: 640, height: 380))
            window.contentView = host
            defer { window.close() }
            for _ in 0..<35 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(nanoseconds: 20_000_000) }
            expect(!window.isVisible, "QA does not bring a window to the foreground")
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let screenshot = directory.appendingPathComponent("message-image-ui.png")
                try rep.representation(using: .png, properties: [:])!.write(to: screenshot)
                var cyanPixels = 0
                for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                    for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                        if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                           color.greenComponent > color.redComponent + 0.15,
                           color.greenComponent > color.blueComponent + 0.03 { cyanPixels += 1 }
                    }
                }
                expect(cyanPixels > 100, "native message screenshot contains actual decoded image pixels (\(cyanPixels))")
                print("IMAGE UI ARTIFACT: \(screenshot.path)")
            } else { failures.append("native snapshot unavailable") }
        } catch { failures.append("\(error)") }
        if failures.isEmpty { print("BAVBAV IMAGE CHECK PASSED: \(count) checks; payloads, Markdown, downsampling, native UI and offline transport") }
        else { failures.forEach { print("BAVBAV IMAGE CHECK FAILED: \($0)") } }
        return failures.isEmpty
    }
}
