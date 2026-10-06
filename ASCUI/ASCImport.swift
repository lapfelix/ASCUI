import Foundation

/// Credentials produced by the `asc` terminal command and pasted back into the app.
struct ASCImportPayload: Decodable {
    let name: String
    let keyId: String
    let issuerId: String
    let privateKey: String

    enum ImportError: LocalizedError {
        case empty
        case notJSON
        case incomplete

        var errorDescription: String? {
            switch self {
            case .empty: "The clipboard is empty."
            case .notJSON: "The clipboard doesn't contain asc credentials. Copy the output of the terminal command first."
            case .incomplete: "The pasted credentials are missing a key ID, issuer ID, or private key."
            }
        }
    }

    static func parse(_ text: String?) throws -> ASCImportPayload {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw ImportError.empty
        }
        guard let payload = try? JSONDecoder().decode(ASCImportPayload.self, from: Data(text.utf8)) else {
            throw ImportError.notJSON
        }
        guard !payload.keyId.isEmpty, !payload.issuerId.isEmpty,
              payload.privateKey.contains("-----BEGIN PRIVATE KEY-----") else {
            throw ImportError.incomplete
        }
        return payload
    }

    /// Shell command that exports `asc` credentials to a throwaway config, copies the chosen
    /// profile as JSON to the clipboard, and deletes the export. `~/.asc` is left untouched.
    /// An empty profile name means asc's default profile.
    static func terminalCommand(profile: String) -> String {
        let python = """
        import json,sys
        c=json.load(open(sys.argv[1]))
        n=sys.argv[2] or c.get("default_key_name")
        k=next(x for x in c["keys"] if x["name"]==n)
        print(json.dumps({"name":n,"keyId":k["key_id"],"issuerId":k["issuer_id"],"privateKey":open(k["private_key_path"]).read()}))
        """
        .split(separator: "\n").joined(separator: ";")

        return "T=$(mktemp -d) && asc auth export-to-config --confirm --config \"$T/c.json\" --private-key-dir \"$T/k\" >/dev/null"
            + " && python3 -c \(shellQuote(python)) \"$T/c.json\" \(shellQuote(profile)) | pbcopy; rm -rf \"$T\""
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
