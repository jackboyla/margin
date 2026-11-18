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
        guard env["MARGIN_AX_ONLY"] != "1" else { return }
        let permission = await HostedAutomationConsent.askForChrome()
        print("APPLE-EVENT permission result",permission)
        XCTAssertEqual(permission,0)
        guard permission == 0 else {return}
        _ = try await exchange(["action":"reset"])
        let capture = WindowCapture()
        let target = try await capture.resolve(target: capture.currentTarget())
        XCTAssertEqual(target.bundleID,"com.google.Chrome")
        XCTAssertEqual(target.url?.components(separatedBy:"#").first,"https://arxiv.org/pdf/2506.01844")
        let first = "Faster inference through layer skipping"
        let second = "tradeoff between speed and performance"
        if let tmp=env["RUNNER_TEMP"] {
            let bytes=try Data(contentsOf:URL(fileURLWithPath:tmp+"/smolvla.pdf"))
            try PDFHighlightDocument.annotated(bytes,quotes:[first])?.write(to:URL(fileURLWithPath:tmp+"/margin-native-annotated.pdf"))
        }
        var initial:PDFReadingPosition?
        var previous=""
        for (step,quotes) in [[first],[first,second],[second],[]].enumerated() {
            _ = try await exchange(["action":"interaction","step":step])
            var pos:PDFReadingPosition?
            let deadline=Date().addingTimeInterval(8)
            while pos==nil && Date()<deadline {
                pos=PDFReadingPosition.current(in:window)
                if pos==nil {try await Task.sleep(for:.milliseconds(170))}
            }
            let baseline=try XCTUnwrap(pos)
            XCTAssertEqual(baseline.pageNumber,4)
            XCTAssertEqual(baseline.zoomPercent,150)
            if step==0 {initial=baseline}
            if step==1 {
                let travelled=try XCTUnwrap(baseline.displacement(from:try XCTUnwrap(initial)))
                XCTAssertGreaterThan(abs(travelled.height),30)
                print("API-TRACE physical wheel",travelled)
            }
            let painted=try await capture.paintBrowserHighlights(target:target,quotes:quotes,isCurrent:{true})
            XCTAssertTrue(painted)
            let src=try await exchange(["action":"evidence","step":step])
            guard src.hasPrefix("blob:https://arxiv.org/"),src != previous else {
                XCTFail("Chrome did not commit a fresh annotated frame at step \(step)");return
            }
            previous=src
            let observed=try XCTUnwrap(PDFReadingPosition.current(in:window))
            let delta=try XCTUnwrap(observed.displacement(from:baseline))
            XCTAssertLessThanOrEqual(abs(delta.width),1)
            XCTAssertLessThanOrEqual(abs(delta.height),1)
            print("API-TRACE verified actual AppleEvent",step,observed.pageNumber,observed.zoomPercent,delta,src.prefix(90))
        }
    }
}
