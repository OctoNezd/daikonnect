import Foundation

/// Finds a one-time-code-looking number in a message.
///
/// Deliberately dumb, on purpose: it does not try to decide whether a message
/// *is* an OTP — no keywords, no context — it simply looks for a run of digits
/// of a plausible length. That means it will occasionally offer something that
/// isn't a code, which is the behaviour that was asked for.
enum OTPCodeFinder {
    /// Digit runs outside `min...max` aren't codes (a year is 4, a phone number
    /// is longer). Runs that sit inside a longer number are ignored, so a
    /// 14-digit order number doesn't yield a "code" from its middle.
    private static let minDigits = 4
    private static let maxDigits = 8

    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "(?<![0-9])([0-9]{\(minDigits),\(maxDigits)})(?![0-9])")
    }()

    /// The most code-like number in `text`, or nil if there is none.
    static func find(in text: String) -> String? {
        guard let regex, !text.isEmpty else { return nil }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let candidates: [String] = matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        guard !candidates.isEmpty else { return nil }

        // Six digits is the commonest length; prefer the first of those, else
        // the first candidate of any accepted length.
        return candidates.first { $0.count == 6 } ?? candidates.first
    }

    /// Looks across several fields (a notification's title and body, say).
    static func find(in texts: [String]) -> String? {
        for text in texts {
            if let code = find(in: text) { return code }
        }
        return nil
    }
}
