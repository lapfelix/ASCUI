import Foundation
import SwiftJWT

struct AppStoreConnectClient {
    let apiKeyID: String
    let apiKey: String
    let issuerID: String

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

    // MARK: - Apps

    func fetchApps() async throws -> [ASCApp] {
        let request = try authorizedRequest(url: URL(string: "https://api.appstoreconnect.apple.com/v1/apps")!)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(AppsResponse.self, from: data).data
    }

    // MARK: - Users (paginated)

    func fetchAllUsers() async throws -> [User] {
        var allUsers: [User] = []
        var nextURL: URL? = URL(string: "https://api.appstoreconnect.apple.com/v1/users?limit=200")

        while let url = nextURL {
            let request = try authorizedRequest(url: url)
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(UsersResponse.self, from: data)
            allUsers.append(contentsOf: response.data)
            nextURL = response.links?.next.flatMap(URL.init(string:))
        }

        return allUsers.sorted { ($0.attributes.firstName ?? "") < ($1.attributes.firstName ?? "") }
    }

    // MARK: - Beta Groups

    func fetchBetaGroups(for app: ASCApp) async throws -> [BetaGroup] {
        let url = URL(string: "https://api.appstoreconnect.apple.com/v1/apps/\(app.id)/betaGroups")!
        let request = try authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: request)
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
        let _ = try await URLSession.shared.data(for: request)
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

    var errorDescription: String? {
        switch self {
        case .emptyPrivateKey:
            return "Private key is empty"
        case .betaGroupNotFound(let appName):
            return "Beta group 'App Store Connect Users' not found for \(appName)"
        }
    }
}
