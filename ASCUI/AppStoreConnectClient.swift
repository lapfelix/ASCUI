import Foundation
import SwiftJWT

struct AppStoreConnectClient {
    let apiKeyID: String
    let apiKey: String
    let issuerID: String

    private struct AppStoreConnectErrorResponse: Decodable {
        let errors: [Entry]?

        struct Entry: Decodable {
            let status: String?
            let code: String?
            let title: String?
            let detail: String?
        }
    }

    // MARK: - JWT

    private func generateJWT() throws -> String {
        struct MyClaims: Claims {
            let iss: String
            let exp: Int
            let aud: String
        }

        guard let privateKeyData = apiKey.data(using: .utf8), !privateKeyData.isEmpty else {
            throw ASCError.emptyPrivateKey
        }

        let header = Header(kid: apiKeyID)
        let claims = MyClaims(
            iss: issuerID,
            exp: Int(Date().addingTimeInterval(20 * 60).timeIntervalSince1970),
            aud: "appstoreconnect-v1"
        )

        var jwt = JWT(header: header, claims: claims)
        let signer = JWTSigner.es256(privateKey: privateKeyData)
        return try jwt.sign(using: signer)
    }

    private func authorizedRequest(url: URL) throws -> URLRequest {
        let token = try generateJWT()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let method = request.httpMethod ?? "GET"
        let urlString = request.url?.absoluteString ?? "<unknown url>"

        guard let httpResponse = response as? HTTPURLResponse else {
            fputs("ASC API \(method) \(urlString) -> non-HTTP response (\(data.count) bytes)\n", stderr)
            return data
        }

        fputs("ASC API \(method) \(urlString) -> \(httpResponse.statusCode) (\(data.count) bytes)\n", stderr)

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = apiErrorMessage(from: data, statusCode: httpResponse.statusCode)
            fputs("ASC API error \(httpResponse.statusCode): \(message)\n", stderr)
            throw ASCError.apiError(statusCode: httpResponse.statusCode, message: message)
        }
        return data
    }

    private func apiErrorMessage(from data: Data, statusCode: Int) -> String {
        if let decoded = try? JSONDecoder().decode(AppStoreConnectErrorResponse.self, from: data),
           let firstError = decoded.errors?.first {
            let parts = [firstError.code, firstError.title, firstError.detail].compactMap { $0 }
            if !parts.isEmpty {
                return parts.joined(separator: " - ")
            }
        }
        if let body = String(data: data, encoding: .utf8),
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body
        }
        return "HTTP \(statusCode)"
    }

    // MARK: - Apps

    func fetchApps() async throws -> [ASCApp] {
        let request = try authorizedRequest(url: URL(string: "https://api.appstoreconnect.apple.com/v1/apps")!)
        let data = try await responseData(for: request)
        return try JSONDecoder().decode(AppsResponse.self, from: data).data
    }

    // MARK: - Users (paginated)

    func fetchAllUsers() async throws -> [User] {
        var allUsers: [User] = []
        var nextURL: URL? = URL(string: "https://api.appstoreconnect.apple.com/v1/users?limit=200")

        while let url = nextURL {
            let request = try authorizedRequest(url: url)
            let data = try await responseData(for: request)
            let response = try JSONDecoder().decode(UsersResponse.self, from: data)
            allUsers.append(contentsOf: response.data)
            nextURL = response.links?.next.flatMap(URL.init(string:))
        }

        return allUsers.sorted { ($0.attributes.firstName ?? "") < ($1.attributes.firstName ?? "") }
    }

    // MARK: - Merchant IDs

    func fetchAllMerchantIDs() async throws -> [MerchantID] {
        var allMerchantIDs: [MerchantID] = []
        var nextURL: URL? = URL(string: "https://api.appstoreconnect.apple.com/v1/merchantIds?limit=200&sort=identifier")

        while let url = nextURL {
            let request = try authorizedRequest(url: url)
            let data = try await responseData(for: request)
            let response = try JSONDecoder().decode(MerchantIDsResponse.self, from: data)
            allMerchantIDs.append(contentsOf: response.data)
            nextURL = response.links?.next.flatMap(URL.init(string:))
        }

        return allMerchantIDs.sorted { $0.attributes.identifier < $1.attributes.identifier }
    }

    func fetchMerchantCertificates(for merchantID: String) async throws -> [ASCCertificate] {
        var allCertificates: [ASCCertificate] = []

        var components = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/merchantIds/\(merchantID)/certificates")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "200")
        ]

        var nextURL: URL? = components.url

        while let url = nextURL {
            let request = try authorizedRequest(url: url)
            let data = try await responseData(for: request)
            let response = try JSONDecoder().decode(CertificatesResponse.self, from: data)
            allCertificates.append(contentsOf: response.data)
            nextURL = response.links?.next.flatMap(URL.init(string:))
        }

        // Fetch each certificate individually — the list endpoint omits `activated`
        var detailedCertificates: [ASCCertificate] = []
        for cert in allCertificates {
            guard let selfLink = cert.links?.`self`, let detailURL = URL(string: selfLink) else {
                detailedCertificates.append(cert)
                continue
            }
            let detailRequest = try authorizedRequest(url: detailURL)
            let detailData = try await responseData(for: detailRequest)
            let detail = try JSONDecoder().decode(CertificateResponse.self, from: detailData)
            detailedCertificates.append(detail.data)
        }

        return detailedCertificates
    }

    // MARK: - Activate Certificate

    func activateCertificate(id: String) async throws {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/certificates/\(id)")!
        var request = try authorizedRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "data": [
                "type": "certificates",
                "id": id,
                "attributes": [
                    "activated": true
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await responseData(for: request)
    }

    // MARK: - Beta Groups

    func fetchBetaGroups(for app: ASCApp) async throws -> [BetaGroup] {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/apps/\(app.id)/betaGroups")!
        let request = try authorizedRequest(url: url)
        let data = try await responseData(for: request)
        return try JSONDecoder().decode(BetaGroupsResponse.self, from: data).data
    }

    // MARK: - Add Tester

    func addTester(email: String, toBetaGroup betaGroupID: String) async throws {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/betaTesters")!
        var request = try authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = BetaTesterRequest(
            data: .init(
                attributes: .init(email: email, firstName: nil, lastName: nil),
                relationships: .init(
                    betaGroups: .init(data: [.init(type: "betaGroups", id: betaGroupID)])
                )
            )
        )
        request.httpBody = try JSONEncoder().encode(body)
        _ = try await responseData(for: request)
    }

    // MARK: - Add Users to TestFlight

    func addUsersToTestFlight(users: [User], apps: [ASCApp]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for app in apps {
                group.addTask {
                    let betaGroups = try await fetchBetaGroups(for: app)
                    guard let betaGroup = betaGroups.first(where: { $0.attributes.name == "App Store Connect Users" }) else {
                        throw ASCError.betaGroupNotFound(appName: app.attributes.name)
                    }
                    for user in users {
                        try await addTester(email: user.attributes.username, toBetaGroup: betaGroup.id)
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}

// MARK: - Errors

enum ASCError: LocalizedError {
    case emptyPrivateKey
    case betaGroupNotFound(appName: String)
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .emptyPrivateKey:
            return "Private key is empty"
        case .betaGroupNotFound(let appName):
            return "Beta group 'App Store Connect Users' not found for \(appName)"
        case .apiError(let statusCode, let message):
            return "App Store Connect API error (\(statusCode)): \(message)"
        }
    }
}
