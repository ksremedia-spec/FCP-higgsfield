import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HiggsfieldKit

/// Records requests and answers from a list of scripted routes.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Route {
        var method: String
        var pathContains: String
        var responses: [(Int, String)]
    }

    struct Recorded {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data?
        var uploadedFile: URL?

        var bodyJSON: JSONValue? {
            body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        }

        var bodyString: String { body.map { String(decoding: $0, as: UTF8.self) } ?? "" }
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private(set) var requests: [Recorded] = []
    var downloadBody = Data("FAKE-MEDIA".utf8)

    func on(_ method: String, _ pathContains: String, status: Int = 200, json: String) {
        on(method, pathContains, responses: [(status, json)])
    }

    /// Successive calls consume responses in order; the last one repeats.
    func on(_ method: String, _ pathContains: String, responses: [(Int, String)]) {
        lock.lock(); defer { lock.unlock() }
        routes.append(Route(method: method, pathContains: pathContains, responses: responses))
    }

    func requests(_ method: String, _ pathContains: String) -> [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.method == method && $0.url.absoluteString.contains(pathContains) }
    }

    private func respond(_ request: URLRequest, uploadedFile: URL? = nil) throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        // Header names are case-insensitive (and Foundation on Linux re-cases them).
        let headers = Dictionary((request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        requests.append(Recorded(method: method, url: url, headers: headers,
                                 body: request.httpBody, uploadedFile: uploadedFile))
        guard let index = routes.lastIndex(where: { $0.method == method && url.absoluteString.contains($0.pathContains) }) else {
            return (Data("{\"detail\":\"no mock for \(method) \(url.path)\"}".utf8),
                    HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        var route = routes[index]
        let (status, body) = route.responses.first!
        if route.responses.count > 1 { route.responses.removeFirst() }
        routes[index] = route
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try respond(request)
    }

    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        try respond(request, uploadedFile: fileURL)
    }

    func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        let (_, response) = try respond(request)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try downloadBody.write(to: destination)
        return response
    }
}

final class CountingTokenProvider: AccessTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [Bool] = []
    var tokens: [String]

    init(tokens: [String] = ["TOKEN"]) {
        self.tokens = tokens
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        calls.append(forceRefresh)
        return forceRefresh && tokens.count > 1 ? tokens[1] : tokens[0]
    }
}

func makeClient(_ transport: MockTransport, tokens: CountingTokenProvider = CountingTokenProvider(), workspace: String? = "11111111-1111-4111-8111-111111111111") -> HiggsfieldClient {
    HiggsfieldClient(
        configuration: HiggsfieldConfiguration(mediaConfirmAttempts: 3, mediaConfirmDelay: 0),
        tokenProvider: tokens, transport: transport, workspaceID: workspace, sleeper: { _ in }
    )
}

func temporaryFile(named name: String, contents: String = "data") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hfkit-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
}

func json(_ string: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
}
