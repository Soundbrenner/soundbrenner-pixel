import Foundation

struct TeamMember: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

struct TeamSession: Codable, Sendable {
    let token: String
    let member: TeamMember
    let expiresAt: Int64
    let monthlyLimitCents: Int

    var isExpired: Bool {
        Date().timeIntervalSince1970 * 1_000 >= Double(expiresAt)
    }
}

enum GenerationCredential: Sendable {
    case personalOpenAI(String)
    case team(String)
    case gemini(String)

    func openAIRequest(_ path: String, method: String) throws -> URLRequest {
        let base: URL
        let token: String
        switch self {
        case .personalOpenAI(let key):
            base = URL(string: "https://api.openai.com")!
            token = key
        case .team(let session):
            base = TeamAccessService.baseURL
            token = session
        case .gemini:
            throw AppError.missingAPIKey
        }
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

struct TeamAccessError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

final class MediaforgeNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum TeamAccessService {
    static let baseURL: URL = {
#if DEBUG
        if let raw = ProcessInfo.processInfo.environment["MEDIAFORGE_LOCAL_TEAM_URL"],
           let url = URL(string: raw),
           url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
           url.user == nil, url.password == nil, url.query == nil, url.fragment == nil {
            return url
        }
#endif
        return URL(string: "https://mediaforge-api.soundbrenner.workers.dev")!
    }()

    private struct Status: Decodable {
        let member: TeamMember
        let expiresAt: Int64
        let monthlyLimitCents: Int
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    private static let session = URLSession(
        configuration: .ephemeral, delegate: MediaforgeNoRedirectDelegate(), delegateQueue: nil
    )

    static func signIn(email: String, password: String) async throws -> TeamSession {
        let body = try JSONEncoder().encode(["email": email, "password": password])
        return try await send("account/login", method: "POST", body: body)
    }

    static func verify(_ session: TeamSession) async throws -> TeamSession {
        let status: Status = try await send("account/session", token: session.token)
        return TeamSession(
            token: session.token,
            member: status.member,
            expiresAt: status.expiresAt,
            monthlyLimitCents: status.monthlyLimitCents
        )
    }

    static func signOut(_ token: String) async throws {
        struct Confirmation: Decodable { let signedOut: Bool }
        let _: Confirmation = try await send("account/logout", method: "POST", token: token)
    }

    private static func send<T: Decodable>(
        _ path: String,
        method: String = "GET",
        token: String? = nil,
        body: Data? = nil
    ) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 150
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.invalidResponse }
        let decoder = JSONDecoder()
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? decoder.decode(ErrorEnvelope.self, from: data)
            throw TeamAccessError(status: http.statusCode, message: detail?.error.message ?? "Mediaforge team sign-in is unavailable.")
        }
        return try decoder.decode(T.self, from: data)
    }
}
