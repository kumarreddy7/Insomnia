import Foundation

/// Opt-in status ping. While a session runs and `Config.statusWebhookURL`
/// holds an https URL, a small JSON status is POSTed there every
/// `interval`. Nothing is sent with the URL empty, which is the default.
@MainActor
final class StatusWebhook {
    struct Snapshot: Codable, Equatable, Sendable {
        var secondsLeft: Int
        var batteryPercent: Int?
        var charging: Bool
        var thermal: String
        var lidClosed: Bool
    }

    typealias Sender = @Sendable (URL, Data) async -> Void

    private let interval: Duration
    private let send: Sender
    private var task: Task<Void, Never>?

    /// `interval` and `send` are injection points for tests; the defaults
    /// ping every 30 minutes through an ephemeral URLSession.
    init(interval: Duration = .seconds(30 * 60), send: @escaping Sender = { await StatusWebhook.post($0, $1) }) {
        self.interval = interval
        self.send = send
    }

    /// The URL to ping, or nil for text that is not an https URL with a
    /// host. Plain http is refused so a status never travels in the clear.
    static func endpoint(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// `current` is read at every tick, so a change to the URL in
    /// config.json or the session ending takes effect on the next one.
    /// It returns nil when there is nothing to send.
    func start(current: @escaping @MainActor () -> (url: URL, snapshot: Snapshot)?) {
        stop()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !Task.isCancelled, let (url, snapshot) = current(), let body = try? JSONEncoder().encode(snapshot) {
                    await self.send(url, body)
                }
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    static func post(_ url: URL, _ body: Data) async {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Log.error("status webhook: server answered \(http.statusCode)")
            }
        } catch {
            // The address is not logged: a webhook URL can carry a secret.
            Log.error("status webhook: ping failed")
        }
    }
}
