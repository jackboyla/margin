import Foundation

public enum SourceIdentity {
    public static func documentID(bundleID: String, title: String, url: String?) -> String {
        if let url, var components = URLComponents(string: url),
           let scheme = components.scheme?.lowercased(), !scheme.isEmpty,
           components.url != nil,
           !["http", "https"].contains(scheme) || components.host?.isEmpty == false {
            components.scheme = scheme
            components.host = components.host?.lowercased()
            if (scheme == "https" && components.port == 443) ||
                (scheme == "http" && components.port == 80) {
                components.port = nil
            }
            if let query = components.percentEncodedQuery {
                let parts = query.split(separator: "&", omittingEmptySubsequences: false)
                let retained = parts.filter { part in
                    let encodedName = String(part.prefix(while: { $0 != "=" }))
                    let name = (encodedName.removingPercentEncoding ?? encodedName).lowercased()
                    return !trackingParameters.contains(name)
                }
                if retained.count != parts.count {
                    components.percentEncodedQuery = retained.isEmpty ? nil : retained.joined(separator: "&")
                }
            }
            canonicalizeArxiv(&components)
            if let normalized = components.string {
                return "url:\(normalized)"
            }
        }

        // Lengths keep app and window names unambiguous even when they contain separators.
        return "window:\(bundleID.utf8.count):\(bundleID)\(title.utf8.count):\(title)"
    }

    private static let trackingParameters: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "utm_source_platform", "utm_creative_format", "utm_marketing_tactic",
        "gclid", "dclid", "fbclid", "msclkid", "mc_cid", "mc_eid",
    ]

    private static func canonicalizeArxiv(_ components: inout URLComponents) {
        guard let host = components.host,
              ["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(host),
              ["http", "https"].contains(components.scheme ?? "") else { return }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, ["abs", "pdf", "html"].contains(String(parts[0])) else { return }
        var identifier = parts.dropFirst().joined(separator: "/")
        if identifier.hasSuffix(".pdf") { identifier.removeLast(4) }
        let pattern = #"^(?:[0-9]{4}\.[0-9]{4,5}|[A-Za-z][A-Za-z0-9.\-]*/[0-9]{7})(?:v[0-9]+)?$"#
        guard identifier.range(of: pattern, options: .regularExpression) != nil else { return }
        components.scheme = "https"
        components.host = "arxiv.org"
        components.path = "/abs/\(identifier)"
    }
}
