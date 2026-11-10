import Foundation

@main
struct BuddyPairingPayloadTests {
    static func main() throws {
        // Synthetic credentials only. Never include or print a user's QR payload.
        let limits = MacConnection(baseURL: URL(string: "http://test-mac.local:48219")!,
                                   accessToken: "synthetic-token+%/=&")
        let snap = PairingInfo(id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
                               name: "Synthetic Mac & 中文", key: Data(repeating: 7, count: 32),
                               relayURL: URL(string: "https://relay.example.com")!)
        let unified = try BuddyPairingPayload.unifiedURL(limits: limits, snapInsert: snap)
        let decoded = try BuddyPairingPayload(urlString: unified.absoluteString)
        precondition(decoded.isUnified && decoded.limits == limits && decoded.snapInsert == snap)
        precondition(decoded.legacyNotice == nil)
        // An old Buddy build still reads the same original fields.
        precondition(MacConnection(pairingURL: unified) == limits)
        print("PASS: unified round trip preserves both modules and old Buddy compatibility")

        let oldLimits = try BuddyPairingPayload(urlString: limits.pairingURL!.absoluteString)
        let oldSnap = try BuddyPairingPayload(urlString: snap.urlString)
        precondition(oldLimits.limits == limits && oldLimits.snapInsert == nil && oldLimits.legacyNotice != nil)
        precondition(oldSnap.limits == nil && oldSnap.snapInsert == snap && oldSnap.legacyNotice != nil)
        print("PASS: legacy links preserve single-module behavior and provide an upgrade notice")

        var actions: [String] = []
        let rejected = decoded.apply(pairSnapInsert: { _ in actions.append("snap-rejected"); return false },
                                     pairLimits: { _ in actions.append("limits-mutated") })
        precondition(!rejected && actions == ["snap-rejected"])
        actions = []
        let accepted = decoded.apply(pairSnapInsert: { _ in actions.append("snap-saved"); return true },
                                     pairLimits: { _ in actions.append("limits-saved") })
        precondition(accepted && actions == ["snap-saved", "limits-saved"])
        actions = []
        oldLimits.apply(pairSnapInsert: { _ in actions.append("unexpected-snap"); return false },
                        pairLimits: { _ in actions.append("limits-only") })
        precondition(actions == ["limits-only"])
        actions = []
        oldSnap.apply(pairSnapInsert: { _ in actions.append("snap-only"); return true },
                      pairLimits: { _ in actions.append("unexpected-limits") })
        precondition(actions == ["snap-only"])
        print("PASS: a SnapInsert refusal never mutates Limits; successful commits run in order")

        let otherMac = PairingInfo(id: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
                                  name: "Other Mac", key: Data(repeating: 8, count: 32), relayURL: snap.relayURL)
        let newKey = PairingInfo(id: snap.id, name: snap.name, key: otherMac.key, relayURL: snap.relayURL)
        let newRelay = PairingInfo(id: snap.id, name: snap.name, key: snap.key,
                                  relayURL: URL(string: "https://another-relay.example.com")!)
        precondition(BuddyPairingPayload.canReplaceSnapInsert(current: snap, incoming: snap, hasPendingPhotos: true))
        for changed in [otherMac, newKey, newRelay] {
            precondition(!BuddyPairingPayload.canReplaceSnapInsert(current: snap, incoming: changed, hasPendingPhotos: true))
            precondition(BuddyPairingPayload.canReplaceSnapInsert(current: snap, incoming: changed, hasPendingPhotos: false))
        }
        precondition(!BuddyPairingPayload.canReplaceSnapInsert(current: nil, incoming: snap, hasPendingPhotos: true))
        print("PASS: production queue switch policy rejects a different Mac, key or relay while photos are pending")

        func limitsLink(address: String = "http://test-mac.local:48219", token: String = "synthetic",
                        extra: [URLQueryItem] = []) -> String {
            var parts = URLComponents()
            parts.scheme = "codexbuddynew"; parts.host = "pair"
            parts.queryItems = [URLQueryItem(name: "url", value: address), URLQueryItem(name: "token", value: token)] + extra
            return parts.string!
        }
        let invalid = [
            "", "https://example.com/", "codexbuddynew://pair?url=x", "codexbuddynew://pair?url=%GG&token=synthetic",
            limitsLink(extra: [.init(name: "token", value: "other")]),
            limitsLink(extra: [.init(name: "url", value: "https://other.example.com")]),
            limitsLink(extra: [.init(name: "unexpected", value: "x")]),
            limitsLink(extra: [.init(name: "snapinsert", value: snap.urlString), .init(name: "snapinsert", value: snap.urlString)]),
            limitsLink(extra: [.init(name: "snapinsert", value: "")]),
            limitsLink(extra: [.init(name: "snapinsert", value: "snapinsert://pair?v=2")]),
            limitsLink(address: "file:///private/tmp/test"), limitsLink(address: "javascript:alert(1)"),
            limitsLink(address: "http:///"), limitsLink(address: "https://user:password@example.com"),
            limitsLink(address: "https://example.com/?token=not-allowed"),
            limitsLink(address: "http://test-mac.local/path"), limitsLink(address: "http://test-mac.local/#fragment"),
            limitsLink(address: "http://test-mac.local:0"), limitsLink(address: "http://test-mac.local:65536"),
            limitsLink(token: ""), limitsLink(token: "two words"), limitsLink(token: "newline\n"),
            limitsLink(token: String(repeating: "a", count: 513)),
            unified.absoluteString + "#fragment", unified.absoluteString + "&%74oken=duplicate",
            "codexbuddynew://user@pair?url=http%3A%2F%2Ftest-mac.local&token=synthetic",
            "codexbuddynew://pair:443?url=http%3A%2F%2Ftest-mac.local&token=synthetic",
            String(repeating: "a", count: 8193)
        ]
        for input in invalid {
            do {
                _ = try BuddyPairingPayload(urlString: input)
                preconditionFailure("Invalid synthetic pairing payload was accepted")
            } catch {}
        }
        let ipv6 = try BuddyPairingPayload.limitsOnlyURL(address: "https://[::1]:48219/", token: "synthetic")
        let decodedIPv6 = try BuddyPairingPayload(urlString: ipv6.absoluteString)
        precondition(decodedIPv6.limits?.baseURL.host != nil)
        print("PASS: \(invalid.count) malformed, duplicate, oversized and unsafe payloads rejected; IPv6 accepted")
    }
}
