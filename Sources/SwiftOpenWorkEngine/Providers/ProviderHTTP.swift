import Foundation

/// A provider said the model cannot take a `tools` array at all.
struct ProviderToolsUnsupported: Error {
    let detail: String
}

/// Opening a streaming HTTP request to a model provider, with the parts every provider shared and
/// none did: the reason a request was refused, and a retry for the failures that pass.
///
/// A refusal used to surface as "returned HTTP status 400" with the body thrown away, so a
/// malformed tool name, an over-long prompt and a bad key all read the same. And a 429 or an
/// overloaded 529 ended the turn on the spot, though they are the ones worth a second try.
enum ProviderHTTP {

    /// Statuses that are worth trying again: rate limit, overload, and gateway hiccups. Not a
    /// plain 500: a local server that fails the same way every time would only make the user wait.
    static func isRetryable(_ status: Int) -> Bool {
        [429, 502, 503, 504, 529].contains(status)
    }

    /// How long to wait before attempt `attempt + 1`. Honours `Retry-After` (seconds), capped so a
    /// long one does not freeze the turn, and otherwise backs off 1s, then 3s.
    static func delay(afterAttempt attempt: Int, retryAfter: String?) -> TimeInterval {
        if let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return min(seconds, 20)
        }
        return attempt <= 1 ? 1 : 3
    }

    /// The message a provider's error body carries, or its start if it is not JSON.
    static func message(fromBody data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let object = json as? [String: Any] {
                if let error = object["error"] as? [String: Any], let text = error["message"] as? String { return text }
                if let text = object["error"] as? String { return text }
                if let text = object["message"] as? String { return text }
            }
            if let array = json as? [[String: Any]],
               let error = array.first?["error"] as? [String: Any], let text = error["message"] as? String { return text }
        }
        return String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a refusal means "this model cannot use tools", as opposed to a bad request.
    static func looksLikeToolsUnsupported(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("does not support tools")
            || lower.contains("does not support function")
            || lower.contains("tools are not supported")
            || lower.contains("tool use is not supported")
            || lower.contains("tool calling is not supported")
            || lower.contains("--jinja")
    }

    /// Open the stream. Retries retryable statuses up to `maxAttempts`; otherwise throws an error
    /// that carries the provider's own message. Throws `ProviderToolsUnsupported` when asked to
    /// (`detectToolsUnsupported`) and the refusal says so.
    static func open(
        _ request: URLRequest,
        session: URLSession,
        domain: String,
        label: String,
        detectToolsUnsupported: Bool = false,
        maxAttempts: Int = 3
    ) async throws -> URLSession.AsyncBytes {
        var attempt = 0
        while true {
            attempt += 1
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: domain, code: 500, userInfo: [NSLocalizedDescriptionKey: "\(label) sent no HTTP response"])
            }
            if (200...299).contains(http.statusCode) { return bytes }

            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= 4000 { break }
                }
            } catch {}
            let detail = message(fromBody: body)

            if detectToolsUnsupported, (400...500).contains(http.statusCode), looksLikeToolsUnsupported(detail) {
                throw ProviderToolsUnsupported(detail: detail)
            }
            if isRetryable(http.statusCode), attempt < maxAttempts {
                let wait = delay(afterAttempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            throw NSError(domain: domain, code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "\(label) returned HTTP \(http.statusCode)" + (detail.isEmpty ? "" : ": \(detail)")
            ])
        }
    }
}
