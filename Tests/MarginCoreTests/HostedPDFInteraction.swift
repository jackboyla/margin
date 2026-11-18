import CryptoKit
import AppKit
import ApplicationServices
import XCTest
@testable import Margin

final class HostedPDFInteraction: XCTestCase {
    @MainActor func testTwoPDFEdits() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["MARGIN_HOSTED_INTERACTION"] == "1")
        let ipc = URL(fileURLWithPath: try XCTUnwrap(env["MARGIN_IPC"]))
        print("API-TRACE trusted", AXIsProcessTrusted())
        let pid=try XCTUnwrap(Int32(env["MARGIN_CHROME_PID"] ?? ""))
        let app=try XCTUnwrap(NSRunningApplication(processIdentifier:pid))
        if !app.isActive {app.activate(options:[]) }
        print("API-TRACE Chrome",app.processIdentifier,app.isActive)
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1.5)
        var value: CFTypeRef?
        let deadline = Date().addingTimeInterval(20)
        while value == nil && Date() < deadline {
            let status = AXUIElementCopyAttributeValue(ax,kAXFocusedWindowAttribute as CFString,&value)
            if status != .success {
                var windows:CFTypeRef?
                let all=AXUIElementCopyAttributeValue(ax,kAXWindowsAttribute as CFString,&windows)
                value=(windows as? [AXUIElement])?.first
                print("AX-DIAG window",status.rawValue,all.rawValue)
                if value == nil { try await Task.sleep(for:.milliseconds(400)) }
            }
        }
        let window = unsafeBitCast(try XCTUnwrap(value), to: AXUIElement.self)
        func exchange(_ fields: [String: Any]) async throws -> String {
            try JSONSerialization.data(withJSONObject: fields).write(to: ipc.appendingPathComponent("request"), options: .atomic)
            let reply=ipc.appendingPathComponent("reply")
            let deadline=Date().addingTimeInterval(20)
            while Date()<deadline {
                if let text=try? String(contentsOf:reply,encoding:.utf8) {
                    try FileManager.default.removeItem(at:reply)
                    return text
                }
                try await Task.sleep(for:.milliseconds(10))
            }
            throw URLError(.timedOut)
        }

        let fields = [kAXRoleAttribute, kAXTitleAttribute, kAXValueAttribute, "AXURL", kAXEnabledAttribute, kAXDescriptionAttribute, kAXChildrenAttribute]
        var queue: [(AXUIElement,Int)] = [(window,0)]
        var idx=0
        var rows:[String]=[]
        let scanDeadline = Date().addingTimeInterval(15)
        while idx < queue.count && idx < 2200 && Date()<scanDeadline {
            let (node,depth)=queue[idx];idx += 1
            var values:CFArray?
            let status=AXUIElementCopyMultipleAttributeValues(node,fields as CFArray,[],&values)
            guard let a=values as? [Any],a.count==7 else{
                rows.append("depth=\(depth) error=\(status.rawValue)");continue
            }
            let row=a.prefix(6).map { item -> String in
                if let u=item as? URL { return u.absoluteString }
                if let n=item as? NSNumber { return n.stringValue }
                if let s=item as? String { return String(s.prefix(150)).replacingOccurrences(of:"\n",with:" ") }
                return "—"
            }.joined(separator:" | ")
            rows.append(String(repeating:" ",count:depth)+row)
            let title = a[1] as? String ?? ""
            if !(title.hasPrefix("Page ") && title != "Page 4"), let kids=a[6] as? [AXUIElement] {
                queue += kids.map { ($0,depth+1) }
            }
        }
        if let tmp = env["RUNNER_TEMP"] { try rows.joined(separator:"\n").write(toFile:tmp+"/margin-evidence/ax-tree-"+(env["MARGIN_AX_ONLY"] ?? "web")+".txt",atomically:true,encoding:.utf8) }
        print("AX-DIAG snapshot",rows.count,rows.filter { $0.contains("AXWebArea") || $0.contains("Page number") || $0.contains("Zoom level") }.prefix(10))
        let before = try XCTUnwrap(PDFReadingPosition.current(in: window))
        print("API-TRACE baseline", before.pageNumber, before.zoomPercent)
        XCTAssertEqual(before.pageNumber, 4)
        if env["MARGIN_AX_ONLY"] == "1" { return }
        let painter=ChromePDFHighlights()
        let paper=try XCTUnwrap(URL(string:"https://arxiv.org/pdf/2506.01844"))
        let first = "the best features for downstream tasks"
        let second = "tradeoff between speed and performance"
        for (step, quotes) in [[first], [first, second], [second], []].enumerated() {
            let result = try await painter.paint(paper:paper, quotes:quotes, isCurrent:{true}, command:exchange, position:{ previous in PDFReadingPosition.current(in:window,excluding:previous) })
            XCTAssertTrue(result)
            let src=try await exchange(["action":"evidence","step":step])
            print("API-TRACE after",step,src.prefix(100))
            XCTAssertTrue(src.hasPrefix("blob:https://arxiv.org/"))
            let position = try XCTUnwrap(PDFReadingPosition.current(in: window))
            let delta = try XCTUnwrap(position.displacement(from: before))
            XCTAssertLessThanOrEqual(abs(delta.width), 1)
            XCTAssertLessThanOrEqual(abs(delta.height), 1)
        }
        print("API-TRACE geometry and four replacements passed")
        let permission = await HostedAutomationConsent.askForChrome()
        print("APPLE-EVENT permission result", permission)
        guard permission == 0 else { return }
        let capture = WindowCapture()
        let target = try await capture.resolve(target: capture.currentTarget())
        XCTAssertEqual(target.bundleID, "com.google.Chrome")
        XCTAssertEqual(target.url?.components(separatedBy:"#").first, paper.absoluteString)
        let painted = try await capture.paintBrowserHighlights(target:target, quotes:[first], isCurrent:{true})
        XCTAssertTrue(painted)
        let src = try await exchange(["action":"evidence","step":"apple-event"])
        XCTAssertTrue(src.hasPrefix("blob:https://arxiv.org/"))
        let active = try await exchange(["action":"status","token":Data(SHA256.hash(data: JSONEncoder().encode([paper.absoluteString,first]))).base64EncodedString()])
        XCTAssertEqual(active,"active")
        print("APPLE-EVENT verified",src)
    }
}
