//
//  MenuAPI.swift
//  MixBot
//

import Foundation

// Client for the mixbot-api Cloudflare Worker (see mixbot-api/README.md).
// Editing always works against the live server version: fetch the menu with
// its version token, edit, then save with If-Match so two controllers can
// never silently overwrite each other.

enum MenuAPIError: LocalizedError {
    case badResponse(String)
    case unauthorized
    case conflict(currentUpdatedAt: String)
    case rejected(problems: [String])

    var errorDescription: String? {
        switch self {
        case .badResponse(let detail):
            return detail
        case .unauthorized:
            return "The server rejected the app's access token."
        case .conflict:
            return "The menu was changed from another device."
        case .rejected(let problems):
            return "The server rejected the menu:\n• " + problems.joined(separator: "\n• ")
        }
    }
}

struct MenuAPI {
    static let endpoint = URL(string: "https://mixbot-api.kixlobo.workers.dev/menu")!
    private static let token = "Q1V9H/0fvtF/X4jsRGxK4QeJzwpBgjqq"

    // Gates the in-app menu editor UI only (hardcoded for now); the real
    // write protection is the server's bearer token. 4 digits, entered on
    // the numeric keypad sheet.
    static let editorPasscode = "1010"

    /// Fetches the live menu plus its version token (X-Updated-At), which a
    /// later save must present as If-Match.
    static func fetchLive() async throws -> (menu: DrinkMenu, updatedAt: String) {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw MenuAPIError.badResponse("Unexpected response from the menu server")
        }
        guard http.statusCode == 200 else {
            throw MenuAPIError.badResponse("Menu server returned status \(http.statusCode)")
        }
        guard let updatedAt = http.value(forHTTPHeaderField: "X-Updated-At") else {
            throw MenuAPIError.badResponse("Menu server response is missing its version token")
        }

        let menu = try JSONDecoder().decode(DrinkMenu.self, from: data)
        return (menu, updatedAt)
    }

    /// Saves the menu and returns the new version token. On success the local
    /// cache is refreshed too, so offline fallback matches what was saved.
    static func save(_ menu: DrinkMenu, ifMatch: String) async throws -> String {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(ifMatch, forHTTPHeaderField: "If-Match")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let body = try encoder.encode(menu)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MenuAPIError.badResponse("Unexpected response from the menu server")
        }

        struct SaveResponse: Decodable { let updatedAt: String }
        struct ConflictResponse: Decodable { let currentUpdatedAt: String }
        struct RejectedResponse: Decodable { let problems: [String] }

        switch http.statusCode {
        case 200:
            let saved = try JSONDecoder().decode(SaveResponse.self, from: data)
            saveDataToCache(data: body)
            return saved.updatedAt
        case 401:
            throw MenuAPIError.unauthorized
        case 409:
            let conflict = try? JSONDecoder().decode(ConflictResponse.self, from: data)
            throw MenuAPIError.conflict(currentUpdatedAt: conflict?.currentUpdatedAt ?? "unknown")
        case 422:
            let rejected = try? JSONDecoder().decode(RejectedResponse.self, from: data)
            throw MenuAPIError.rejected(problems: rejected?.problems ?? ["Unknown validation problem"])
        default:
            throw MenuAPIError.badResponse("Menu server returned status \(http.statusCode)")
        }
    }
}
