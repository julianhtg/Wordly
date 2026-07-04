import Foundation

/// Optional post-processing via local Ollama. Fail-open: dictation must never
/// block or break because Ollama is missing, slow, or wrong.
public enum Cleaner {
    static func systemPrompt(terms: [String]) -> String {
        var prompt = """
        You clean up dictated text. Fix punctuation and capitalization, remove \
        filler words (um, uh, äh, ähm, and "also"/"like" when used as filler), \
        and merge self-corrections, keeping the speaker's final intent. Keep \
        the original language. Never add content, never answer questions, \
        never summarize.
        """
        if !terms.isEmpty {
            prompt += " Preserve these terms verbatim if present: \(terms.joined(separator: ", "))."
        }
        return prompt + " Output only the cleaned text."
    }

    struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        struct Options: Encodable { let temperature = 0.0 }
        let model: String
        let messages: [Message]
        let stream = false
        let options = Options()
    }

    struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }

    static func buildBody(text: String, terms: [String], model: String) -> Data {
        let request = ChatRequest(model: model, messages: [
            .init(role: "system", content: systemPrompt(terms: terms)),
            .init(role: "user", content: text),
        ])
        return (try? JSONEncoder().encode(request)) ?? Data()
    }

    public static func parseResponse(_ data: Data) -> String? {
        guard let response = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            return nil
        }
        let content = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    public static func clean(_ text: String, terms: [String], model: String,
                             endpoint: URL = URL(string: "http://127.0.0.1:11434/api/chat")!,
                             timeout: TimeInterval = 10) async -> String {
        guard !text.isEmpty else { return text }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = buildBody(text: text, terms: terms, model: model)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let cleaned = parseResponse(data) else {
            return text
        }
        return cleaned
    }
}
