import Foundation

// MARK: - App Store Connect App

struct ASCApp: Identifiable, Codable, Hashable {
    let id: String
    let attributes: AppAttributes
}

struct AppAttributes: Codable, Hashable {
    let name: String
    let bundleId: String
}

struct AppsResponse: Codable {
    let data: [ASCApp]
}

// MARK: - Beta Group

struct BetaGroup: Identifiable, Codable, Hashable {
    let id: String
    let attributes: BetaGroupAttributes
}

struct BetaGroupAttributes: Codable, Hashable {
    let name: String
}

struct BetaGroupsResponse: Codable {
    let data: [BetaGroup]
}

// MARK: - User

struct User: Identifiable, Codable, Hashable {
    let id: String
    let attributes: UserAttributes
}

struct UserAttributes: Codable, Hashable {
    let username: String
    let firstName: String?
    let lastName: String?
}

struct UsersResponse: Codable {
    let data: [User]
    let links: PagedDocumentLinks?
    let meta: PagingInformation?
}

// MARK: - Pagination

struct PagedDocumentLinks: Codable {
    let selfLink: String
    let next: String?

    enum CodingKeys: String, CodingKey {
        case selfLink = "self"
        case next
    }
}

struct PagingInformation: Codable {
    let paging: Paging

    struct Paging: Codable {
        let total: Int?
        let limit: Int?
    }
}

// MARK: - Beta Tester Request

struct BetaTesterRequest: Codable {
    let data: Data

    struct Data: Codable {
        let type = "betaTesters"
        let attributes: Attributes
        let relationships: Relationships
    }

    struct Attributes: Codable {
        let email: String
        let firstName: String?
        let lastName: String?
    }

    struct Relationships: Codable {
        let betaGroups: BetaGroups
    }

    struct BetaGroups: Codable {
        let data: [BetaGroupData]
    }

    struct BetaGroupData: Codable {
        let type: String
        let id: String
    }
}
