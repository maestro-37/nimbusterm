import Foundation

public enum Shell {
    /// Splits a user-supplied argument string honouring single/double quotes and backslashes.
    public static func split(_ raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?
        var escape = false

        for ch in raw {
            if escape {
                current.append(ch)
                hasToken = true
                escape = false
                continue
            }
            if ch == "\\" && quote != "'" {
                escape = true
                hasToken = true
                continue
            }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                hasToken = true
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                hasToken = true
                continue
            }
            if ch == " " || ch == "\t" || ch == "\n" {
                if hasToken {
                    result.append(current)
                    current = ""
                    hasToken = false
                }
                continue
            }
            current.append(ch)
            hasToken = true
        }
        if hasToken { result.append(current) }
        return result
    }

    /// POSIX single-quote escaping for building shell snippets.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func substitute(_ template: String, session: Session) -> String {
        template
            .replacingOccurrences(of: "{host}", with: session.host)
            .replacingOccurrences(of: "{user}", with: session.user)
            .replacingOccurrences(of: "{port}", with: String(session.port))
            .replacingOccurrences(of: "{name}", with: session.displayName)
    }
}
