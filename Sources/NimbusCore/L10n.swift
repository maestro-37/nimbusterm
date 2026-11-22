import Foundation

public enum L10n {
    public static func t(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    public static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
    }
}
