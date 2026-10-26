import Foundation

nonisolated struct TransferRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let length: Int
    static let maximumHeader = 16 * 1024
    static func parse(_ data: Data) throws -> TransferRequest {
        guard data.count <= maximumHeader, let text = String(data: data, encoding: .utf8) else { throw LibraryError.invalid("Invalid HTTP header.") }
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, parts[2] == "HTTP/1.1", ["GET", "POST"].contains(String(parts[0])),
              parts[1].hasPrefix("/"), !parts[1].hasPrefix("//") else { throw LibraryError.invalid("Unsupported HTTP request.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw LibraryError.invalid("Invalid header.") }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw LibraryError.invalid("Duplicate header.") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil,
              let host = headers["host"], !host.isEmpty else { throw LibraryError.invalid("Unsupported transfer encoding or host.") }
        if let origin = headers["origin"], origin != "http://" + host { throw LibraryError.invalid("Cross-origin requests are not accepted.") }
        let length: Int
        if let value = headers["content-length"] {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int(value), parsed <= ROMValidation.maximumSize else { throw LibraryError.invalid("Invalid or oversized Content-Length.") }
            length = parsed
        } else { length = 0 }
        if parts[0] == "POST" && length == 0 { throw LibraryError.invalid("A nonempty Content-Length is required.") }
        return TransferRequest(method: String(parts[0]), target: String(parts[1]), headers: headers, length: length)
    }
    func route(token: String) throws -> (path: String, query: [String: String]) {
        guard let components = URLComponents(string: "http://local" + target) else { throw LibraryError.invalid("Invalid URL.") }
        let prefix = "/" + token
        guard components.path == prefix || components.path.hasPrefix(prefix + "/") else { throw LibraryError.invalid("Transfer session expired or incorrect URL.") }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else { throw LibraryError.invalid("Invalid query.") }
            query[item.name] = value
        }
        return (String(components.path.dropFirst(prefix.count)), query)
    }
}
