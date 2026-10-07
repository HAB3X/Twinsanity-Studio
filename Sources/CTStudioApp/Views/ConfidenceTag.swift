import SwiftUI

/// One consistent vocabulary for the short "(experimental, unconfirmed)"-style
/// parenthetical tags this app appends to section headers, toggles, and
/// labeled fields whose semantics haven't been verified against a real
/// reference source. Deliberately separate from the app's other,
/// longer-form caveat sentences (the ones with `.font(.caption2)` captions
/// explaining *why* a field is unconfirmed), those are unique, load-bearing
/// prose per call site and shouldn't be genericized into a fixed vocabulary.
enum ConfidenceTag {
    case experimental
    case unconfirmed
    case experimentalUnconfirmed
    case custom(String)

    var suffix: String {
        switch self {
        case .experimental: return "experimental"
        case .unconfirmed: return "unconfirmed"
        case .experimentalUnconfirmed: return "experimental, unconfirmed"
        case .custom(let detail): return detail
        }
    }
}

extension String {
    /// Appends a `ConfidenceTag` as a parenthetical suffix, e.g.
    /// `"AI Behavior".tagged(.experimentalUnconfirmed)` -> `"AI Behavior (experimental, unconfirmed)"`.
    func tagged(_ tag: ConfidenceTag) -> String {
        "\(self) (\(tag.suffix))"
    }
}
