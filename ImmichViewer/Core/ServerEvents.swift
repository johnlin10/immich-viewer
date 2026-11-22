import Foundation

/// One socket.io packet (Engine.IO v4), as Immich sends them: one per WebSocket message.
enum SocketPacket: Equatable {
    case open                // "0{...}": answer with "40"
    case connected           // "40{...}"
    case ping                // "2": answer with "3"
    case event(String, Data) // "42[name, arg]": the first argument as JSON (Data, so it stays Equatable and Sendable)
    case closed              // "1", "41", "44{...}", or 42["error", ...]: the server refused us (the namespace is accepted before the key is checked)
    case other

    init(_ text: String) {
        switch (text.first, text.dropFirst().first) {
        case ("0", _): self = .open
        case ("1", _), ("4", "1"), ("4", "4"): self = .closed
        case ("2", nil): self = .ping
        case ("4", "0"): self = .connected
        case ("4", "2"):
            guard let list = try? JSONSerialization.jsonObject(with: Data(text.dropFirst(2).utf8)) as? [Any], let name = list.first as? String,
                  let arg = try? JSONSerialization.data(withJSONObject: list.dropFirst().first ?? NSNull(), options: .fragmentsAllowed)
            else { self = .other; return }
            self = name == "error" ? .closed : .event(name, arg)
        default: self = .other
        }
    }
}

/// What a live event means for the local lists.
enum ServerEvent: Sendable {
    case connected                // the key was accepted (the server greets with its version); a second one means events may have been missed
    case removed([String])        // trashed, hidden
    case deleted([String])        // gone for good: the thumbnail too
    case changed(AssetItem)       // favorite, archive, date, description…
    case added                    // uploaded, restored: reload the list

    /// Nil for events the app doesn't use.
    static func from(name: String, json: Data) -> ServerEvent? {
        let value = try? JSONSerialization.jsonObject(with: json, options: .fragmentsAllowed)
        switch name {
        case "on_asset_trash", "on_asset_hidden": return .removed((value as? [String]) ?? (value as? String).map { [$0] } ?? [])
        case "on_asset_delete": return (value as? String).map { .deleted([$0]) }
        case "on_asset_update": return (try? JSONDecoder().decode(AssetItem.self, from: json)).map { .changed($0) }
        case "on_server_version": return .connected // only sent after the key checked out; "40" comes before that
        case "on_upload_success", "on_asset_restore": return .added
        default: return nil
        }
    }
}

extension ImmichAPI {
    private struct SocketClosed: LocalizedError {
        var errorDescription: String? { "The server closed the live connection" }
    }

    /// One live connection to the server's socket.io, as long as the stream is read. It ends (throws) when the connection does:
    /// the caller reconnects.
    func events() -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { out in
            var url = URLComponents(url: server.appending(path: "api/socket.io/"), resolvingAgainstBaseURL: false)!
            url.scheme = url.scheme == "https" ? "wss" : "ws"
            url.queryItems = [URLQueryItem(name: "EIO", value: "4"), URLQueryItem(name: "transport", value: "websocket")]
            var request = URLRequest(url: url.url!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            let socket = URLSession.shared.webSocketTask(with: request)
            socket.resume()
            let reader = Task {
                do {
                    while true {
                        guard case .string(let text) = try await socket.receive() else { continue }
                        switch SocketPacket(text) {
                        case .open: try await socket.send(.string("40"))
                        case .connected: break
                        case .ping: try await socket.send(.string("3")) // at once, or the server drops us after ~45 s
                        case .event(let name, let json): if let event = ServerEvent.from(name: name, json: json) { out.yield(event) }
                        case .closed: throw SocketClosed()
                        case .other: break
                        }
                    }
                } catch {
                    out.finish(throwing: error)
                }
            }
            out.onTermination = { _ in
                reader.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
