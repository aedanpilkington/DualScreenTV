import Foundation
@main struct CompanionTransferAddressTests {
    static func main() {
        assert(CompanionTransferAddress.parse("Apple-TV.local")?.absoluteString == "http://apple-tv.local:8765/")
        assert(CompanionTransferAddress.parse("http://Apple-TV.local.:8765/secret?code=123456#library")?.absoluteString == "http://apple-tv.local:8765/")
        for host in ["10.0.0.2", "172.16.1.4", "172.31.255.1", "192.168.0.83", "169.254.10.2"] {
            assert(CompanionTransferAddress.parse(host)?.host == host)
        }
        for input in ["", "https://apple-tv.local", "https://example.com", "http://192.168.1.2@evil.com", "http://user:pass@apple-tv.local", "172.32.0.1", "172.15.0.1", "8.8.8.8", "192.168.0.999", "file:///tmp/test", "javascript:alert(1)", "apple-tv.local.evil.com", "apple-tv.local:0", "apple-tv.local:65536"] {
            assert(CompanionTransferAddress.parse(input) == nil, input)
        }
        print("Companion transfer addresses: local hosts, private IPs, port bounds, credentials and session stripping passed")
    }
}
