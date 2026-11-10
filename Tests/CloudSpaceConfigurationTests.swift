import Foundation

@main
struct CloudSpaceConfigurationTests {
    static func main() throws {
        let accepted = [
            " https://gateway.example.ts.net ": "https://gateway.example.ts.net/",
            "https://GATEWAY.EXAMPLE.ts.net/folder/": "https://gateway.example.ts.net/folder/",
            "http://127.0.0.1:8080/": "http://127.0.0.1:8080/",
            "https://gateway.example.ts.net:443/": "https://gateway.example.ts.net:443/"
        ]
        for (address, expected) in accepted {
            let url = try CloudSpaceConfiguration.gatewayURL(from: address)
            precondition(url.absoluteString == expected, "Gateway addresses must normalize without changing the path")
        }

        let rejected = [
            "", "gateway.example.ts.net", "file:///private/tmp/a", "javascript:alert(1)",
            "https:///", "https://user:secret@gateway.example.ts.net/",
            "https://gateway.example.ts.net/?token=secret", "https://gateway.example.ts.net/#secret",
            "https://gateway.example.ts.net/white space", "https://gateway.example.ts.net:0/",
            "https://gateway.example.ts.net:65536/", "https://gateway.example.ts.net/\\x"
        ]
        for address in rejected {
            do {
                _ = try CloudSpaceConfiguration.gatewayURL(from: address)
                preconditionFailure("Unsafe or invalid gateway address was accepted")
            } catch {}
        }
        print("PASS: CloudSpace gateway URL validation (\(accepted.count) accepted, \(rejected.count) rejected)")
    }
}
