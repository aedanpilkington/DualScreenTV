import Foundation

/// Only local HTTP addresses; session tokens are never saved in preferences.
nonisolated enum CompanionTransferAddress {
    static func parse(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text.contains("://") ? text : "http://" + text),
              parts.scheme == "http", parts.user == nil, parts.password == nil,
              let host = parts.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty else { return nil }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        let privateIPv4 = octets.count == 4 && octets.allSatisfy { (0...255).contains($0) }
            && (octets[0] == 10 || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 169 && octets[1] == 254))
        guard host.hasSuffix(".local") || privateIPv4 else { return nil }
        parts.host = host; parts.port = parts.port ?? 8765
        guard let port = parts.port, (1...65535).contains(port) else { return nil }
        parts.path = "/"; parts.query = nil; parts.fragment = nil
        return parts.url
    }
}
