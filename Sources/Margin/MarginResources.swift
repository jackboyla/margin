import Foundation

enum MarginResources {
    private static let bundle: Bundle? = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.url(forResource: "Margin_Margin", withExtension: "bundle").flatMap(Bundle.init(url:))
        }
        return Bundle.module
    }()

    static func script(_ name: String, in subdirectory: String? = nil) -> String? {
        guard let url = bundle?.url(forResource: name, withExtension: "js", subdirectory: subdirectory) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
