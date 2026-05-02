import Foundation

/// Display-only normalization for upstream place titles that arrive in all caps.
///
/// Applies conservative title-casing only when the string looks like inadvertent “shouting”
/// (no lowercase letters present). Tokens of ≤3 letters remain uppercase so common
/// abbreviations (`NYC`, `USA`) stay stable; longer words use `localizedCapitalized`.
enum TimelinePlaceDisplayName {
    private static let minLetterCountForGlobalShouting: Int = 4
    private static let acronymMaxLetterCount: UInt = 3

    /// Formatted string for timeline card titles — does not mutate model data.
    static func timelineDisplay(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        let lettersInFull = trimmed.filter(\.isLetter)
        guard lettersInFull.count >= minLetterCountForGlobalShouting else { return trimmed }
        guard !trimmed.contains(where: { $0.isLetter && $0.isLowercase }) else { return trimmed }

        return trimmed
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { segment in timelineDisplayWhitespaceToken(String(segment)) }
            .joined(separator: " ")
    }

    /// One whitespace-delimited fragment; hyphens subdivide shouting tokens (`FOO-BAR` → two chunks).
    private static func timelineDisplayWhitespaceToken(_ token: String) -> String {
        token.split(separator: "-", omittingEmptySubsequences: false)
            .map { hyphenPart in timelineDisplayHyphenChunk(String(hyphenPart)) }
            .joined(separator: "-")
    }

    private static func timelineDisplayHyphenChunk(_ chunk: String) -> String {
        guard !chunk.isEmpty else { return chunk }
        if chunk.contains(where: \.isNumber) { return chunk }

        let letters = chunk.filter(\.isLetter)
        guard letters.count >= 2 else { return chunk }
        guard letters.allSatisfy(\.isUppercase) else { return chunk }
        guard UInt(letters.count) > acronymMaxLetterCount else { return chunk }

        return chunk.localizedCapitalized
    }
}
