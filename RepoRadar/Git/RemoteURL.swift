import Foundation

/// Turns a remote's git URL into the web page for the repo
enum RemoteURL {
    static func web(for remote: String) -> URL? {
        var host: String
        var path: String
        let trimmed = remote.trimmingCharacters(in: .whitespaces)

        if let url = URLComponents(string: trimmed), let scheme = url.scheme,
           ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme.lowercased()),
           let urlHost = url.host, !urlHost.isEmpty {
            host = urlHost
            path = url.path
        } else if let colon = trimmed.firstIndex(of: ":"), !trimmed.hasPrefix("/"), !trimmed.contains("://") {
            // scp style: git@github.com:owner/repo.git
            let hostPart = trimmed[..<colon]
            host = String(hostPart.split(separator: "@").last ?? Substring(hostPart))
            path = String(trimmed[trimmed.index(after: colon)...])
        } else {
            return nil    // a local path or file:// remote has no web page
        }

        // An ssh config alias such as "github-work" stands for github.com
        if !host.contains(".") {
            guard host.lowercased().contains("github") else { return nil }
            host = "github.com"
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard !path.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = "/" + path
        return components.url
    }
}
