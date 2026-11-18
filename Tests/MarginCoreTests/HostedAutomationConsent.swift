import AppKit
import ApplicationServices
import Carbon

enum HostedAutomationConsent {
    static func askForChrome() async -> OSStatus {
        let helper = Task.detached {
            let deadline = Date().addingTimeInterval(18)
            while !Task.isCancelled && Date() < deadline {
                let apps = NSWorkspace.shared.runningApplications.filter {
                    ["com.apple.SecurityAgent", "com.apple.UserNotificationCenter", "com.apple.CoreServicesUIAgent"].contains($0.bundleIdentifier ?? "")
                }
                for app in apps {
                    let ax = AXUIElementCreateApplication(app.processIdentifier)
                    var queue = (attribute(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
                    var idx=0, text="", buttons:[AXUIElement]=[]
                    while idx < queue.count && idx < 150 {
                        let e=queue[idx];idx+=1
                        let title=attribute(e,kAXTitleAttribute) as? String ?? ""
                        let role=attribute(e,kAXRoleAttribute) as? String ?? ""
                        text += " "+title+" "+(attribute(e,kAXValueAttribute) as? String ?? "")
                        if role == kAXButtonRole && ["Allow","OK"].contains(title) {buttons.append(e)}
                        queue += (attribute(e,kAXChildrenAttribute) as? [AXUIElement]) ?? []
                    }
                    if text.localizedCaseInsensitiveContains("Chrome"),text.localizedCaseInsensitiveContains("control"),buttons.count==1 {
                        print("APPLE-EVENT consent pressed", AXUIElementPerformAction(buttons[0], kAXPressAction as CFString).rawValue)
                        return
                    }
                }
                try? await Task.sleep(for:.milliseconds(350))
            }
        }
        let result=await Task.detached {
            let chrome=NSAppleEventDescriptor(bundleIdentifier:"com.google.Chrome")
            let poll=AEDeterminePermissionToAutomateTarget(chrome.aeDesc,typeWildCard,typeWildCard,false)
            print("APPLE-EVENT permission before request",poll)
            return poll==noErr ? poll : AEDeterminePermissionToAutomateTarget(chrome.aeDesc,typeWildCard,typeWildCard,true)
        }.value
        helper.cancel()
        return result
    }
    private static func attribute(_ e:AXUIElement,_ key:String)->CFTypeRef? {
        var v:CFTypeRef?
        return AXUIElementCopyAttributeValue(e,key as CFString,&v) == .success ? v : nil
    }
}
