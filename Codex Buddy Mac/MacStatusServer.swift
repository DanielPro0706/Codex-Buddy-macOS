import Foundation
import Network

final class MacStatusServer: @unchecked Sendable {
    static let port: NWEndpoint.Port = 48_219

    private let queue = DispatchQueue(label: "com.danieldev.codexbuddynew.server")
    private let token: String
    private let snapshotProvider: @MainActor @Sendable () -> CodexStatusSnapshot?
    private var listener: NWListener?

    init(token: String, snapshotProvider: @escaping @MainActor @Sendable () -> CodexStatusSnapshot?) {
        self.token = token
        self.snapshotProvider = snapshotProvider
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: Self.port)
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "Codex Buddy New",
            type: "_codexbuddynew._tcp"
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            Task {
                let response = await self.response(for: request)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func response(for request: String) async -> Data {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return httpResponse(status: 400, body: Data()) }
        let requestParts = firstLine.split(separator: " ")
        guard requestParts.count >= 2, requestParts[0] == "GET" else {
            return httpResponse(status: 405, body: Data())
        }

        let path = String(requestParts[1]).split(separator: "?").first.map(String.init) ?? "/"
        if path == "/health" {
            return httpResponse(status: 200, body: Data("{\"status\":\"ok\"}".utf8))
        }

        let authHeader = lines.first { $0.lowercased().hasPrefix("authorization:") }
        let suppliedToken = authHeader?.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
        guard suppliedToken == "Bearer \(token)" else {
            return httpResponse(status: 401, body: Data("{\"error\":\"unauthorized\"}".utf8))
        }
        guard path == "/v1/status" else { return httpResponse(status: 404, body: Data()) }
        guard let snapshot = snapshotProvider(),
              let body = try? CodexStatusCache.encoder.encode(snapshot) else {
            return httpResponse(status: 503, body: Data("{\"error\":\"unavailable\"}".utf8))
        }
        return httpResponse(status: 200, body: body)
    }

    private func httpResponse(status: Int, body: Data) -> Data {
        let reason = switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Service Unavailable"
        }
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        return response
    }
}
