import Foundation

enum SmartNotebookAge: Int64, CaseIterable {
    case any = 0
    case day = 1
    case week = 7
    case month = 30
    case year = 365

    var label: String {
        switch self {
        case .any: "Any time"
        case .day: "Last 24 hours"
        case .week: "Last week"
        case .month: "Last month"
        case .year: "Last year"
        }
    }
}

/// Which of a doc's two timestamps a date rule reads.
enum SmartDateField: String, CaseIterable {
    case modified
    case created

    var label: String { self == .modified ? "Modified" : "Created" }
}

enum SmartDateOp: String, CaseIterable {
    case within
    case before
    case after

    var label: String {
        switch self {
        case .within: "within"
        case .before: "before"
        case .after: "after"
        }
    }

    var wantsDay: Bool { self != .within }
}

/// What a text rule reads. `anything` is the search index — title and body and
/// whatever else was indexed with them; the other two are read straight off the
/// doc's index entry.
enum SmartTextField: String, CaseIterable {
    case anything
    case title
    case tag

    var label: String {
        switch self {
        case .anything: "Note"
        case .title: "Title"
        case .tag: "Tag"
        }
    }

    /// The index takes a query, so only whole-field tests on the fields Lush
    /// holds locally can ask "is".
    var canBeWhole: Bool { self != .anything }
}

/// How a text rule tests. Whole-field and exactness are two flags on the rule
/// body; the editor offers them as one list, the way a mail rule does.
enum SmartTextOp: String, CaseIterable {
    case contains
    case containsExactly
    case whole
    case wholeExactly

    init(whole: Bool, exact: Bool) {
        switch (whole, exact) {
        case (false, false): self = .contains
        case (false, true): self = .containsExactly
        case (true, false): self = .whole
        case (true, true): self = .wholeExactly
        }
    }

    var isWhole: Bool { self == .whole || self == .wholeExactly }
    var isExact: Bool { self == .containsExactly || self == .wholeExactly }

    var label: String {
        switch self {
        case .contains: "contains"
        case .containsExactly: "contains exactly"
        case .whole: "is"
        case .wholeExactly: "is exactly"
        }
    }
}

/// A rule tree. Groups nest; leaves are the things a saved search can ask
/// about. The whole tree is stored on the notebook as JSON.
struct SmartRule: Identifiable, Equatable {
    enum Op: String, CaseIterable {
        case all
        case any

        var label: String { self == .all ? "all" : "any" }
    }

    indirect enum Body: Equatable {
        case group(Op, [SmartRule])
        /// `whole` is "is" rather than "contains"; `exact` is "exactly" rather
        /// than "like".
        case text(SmartTextField, whole: Bool, exact: Bool, String)
        case kind(SmartNotebookKind)
        case folder(String)
        /// `within` reads the age and ignores the day; `before` and `after`
        /// read the day and ignore the age. An empty day asks nothing, the
        /// way empty text does.
        case date(SmartDateField, SmartDateOp, age: SmartNotebookAge, day: String)
    }

    var id = UUID()
    var body: Body

    init(id: UUID = UUID(), _ body: Body) {
        self.id = id
        self.body = body
    }

    static func group(_ op: Op, _ rules: [SmartRule]) -> SmartRule {
        SmartRule(.group(op, rules))
    }

    static func text(_ value: String = "", field: SmartTextField = .anything) -> SmartRule {
        SmartRule(.text(field, whole: false, exact: false, value))
    }

    var children: [SmartRule] {
        get {
            if case let .group(_, rules) = body { return rules }
            return []
        }
        set {
            if case let .group(op, _) = body { body = .group(op, newValue) }
        }
    }

    var op: Op {
        get {
            if case let .group(op, _) = body { return op }
            return .all
        }
        set {
            if case let .group(_, rules) = body { body = .group(newValue, rules) }
        }
    }

    var isGroup: Bool {
        if case .group = body { return true }
        return false
    }
}

/// Tree edits the editor's drag and drop needs. A leaf's `children` setter is
/// a no-op, so these walk leaves harmlessly.
extension SmartRule {
    func node(_ id: UUID) -> SmartRule? {
        if self.id == id { return self }
        for child in children {
            if let hit = child.node(id) { return hit }
        }
        return nil
    }

    /// The group holding `id`, and where in it.
    func parent(of id: UUID) -> (group: UUID, index: Int)? {
        if let index = children.firstIndex(where: { $0.id == id }) { return (self.id, index) }
        for child in children {
            if let hit = child.parent(of: id) { return hit }
        }
        return nil
    }

    mutating func drop(_ id: UUID) {
        var rules = children
        rules.removeAll { $0.id == id }
        for index in rules.indices { rules[index].drop(id) }
        children = rules
    }

    mutating func insert(_ rule: SmartRule, into group: UUID, at index: Int) {
        var rules = children
        if self.id == group {
            rules.insert(rule, at: min(max(index, 0), rules.count))
        } else {
            for slot in rules.indices { rules[slot].insert(rule, into: group, at: index) }
        }
        children = rules
    }
}

extension SmartRule: Codable {
    private enum Key: String, CodingKey {
        case op, rules, type, field, whole, exact, text, kind, folder, days, on, day
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        if let op = try container.decodeIfPresent(String.self, forKey: .op) {
            let rules = try container.decodeIfPresent([SmartRule].self, forKey: .rules) ?? []
            body = .group(Op(rawValue: op) ?? .all, rules)
            return
        }
        switch try container.decodeIfPresent(String.self, forKey: .type) {
        case "kind":
            let raw = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
            body = .kind(SmartNotebookKind(rawValue: raw) ?? .any)
        case "in":
            body = .folder(try container.decodeIfPresent(String.self, forKey: .folder) ?? "")
        case "modified", "date":
            let days = try container.decodeIfPresent(Int64.self, forKey: .days) ?? 0
            let field = try container.decodeIfPresent(String.self, forKey: .on) ?? ""
            let op = try container.decodeIfPresent(String.self, forKey: .field) ?? ""
            body = .date(
                SmartDateField(rawValue: field) ?? .modified,
                SmartDateOp(rawValue: op) ?? .within,
                age: SmartNotebookAge(rawValue: days) ?? .any,
                day: try container.decodeIfPresent(String.self, forKey: .day) ?? ""
            )
        default:
            let field = try container.decodeIfPresent(String.self, forKey: .field) ?? ""
            body = .text(
                SmartTextField(rawValue: field) ?? .anything,
                whole: try container.decodeIfPresent(Bool.self, forKey: .whole) ?? false,
                exact: try container.decodeIfPresent(Bool.self, forKey: .exact) ?? false,
                try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch body {
        case let .group(op, rules):
            try container.encode(op.rawValue, forKey: .op)
            try container.encode(rules, forKey: .rules)
        case let .text(field, whole, exact, text):
            try container.encode("text", forKey: .type)
            try container.encode(field.rawValue, forKey: .field)
            try container.encode(whole, forKey: .whole)
            try container.encode(exact, forKey: .exact)
            try container.encode(text, forKey: .text)
        case let .kind(kind):
            try container.encode("kind", forKey: .type)
            try container.encode(kind.rawValue, forKey: .kind)
        case let .folder(url):
            try container.encode("in", forKey: .type)
            try container.encode(url, forKey: .folder)
        case let .date(on, op, age, day):
            try container.encode("date", forKey: .type)
            try container.encode(on.rawValue, forKey: .on)
            try container.encode(op.rawValue, forKey: .field)
            try container.encode(age.rawValue, forKey: .days)
            try container.encode(day, forKey: .day)
        }
    }
}

extension SmartNotebook {
    /// The tree as saved, or the one the old flat fields describe. A notebook
    /// written before rules existed still has to search for the same thing.
    var rootRule: SmartRule {
        if let data = rules.data(using: .utf8),
           let rule = try? JSONDecoder().decode(SmartRule.self, from: data) {
            return rule
        }
        var leaves: [SmartRule] = []
        let exact = isQuotedPhrase(query)
        let text = exact ? String(query.dropFirst().dropLast()) : query
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            leaves.append(SmartRule(.text(.anything, whole: false, exact: exact, text)))
        }
        if let kind = SmartNotebookKind(rawValue: kind), kind != .any {
            leaves.append(SmartRule(.kind(kind)))
        }
        if !scope.isEmpty {
            leaves.append(SmartRule(.folder(scope)))
        }
        if let age = SmartNotebookAge(rawValue: withinDays), age != .any {
            leaves.append(SmartRule(.date(.modified, .within, age: age, day: "")))
        }
        return .group(.all, leaves)
    }
}

func encodeSmartRules(_ rule: SmartRule) -> String {
    guard let data = try? JSONEncoder().encode(rule) else { return "" }
    return String(decoding: data, as: UTF8.self)
}

/// What a client that only knows the flat fields should see. A tree that is one
/// `all` of plain leaves projects exactly; anything richer keeps whichever
/// top-level leaves it does have and drops the rest.
func smartNotebookProjection(
    _ rule: SmartRule
) -> (query: String, kind: String, scope: String, withinDays: Int64) {
    var query = ""
    var kind = ""
    var scope = ""
    var days: Int64 = 0
    guard case let .group(.all, rules) = rule.body else { return (query, kind, scope, days) }
    for child in rules {
        switch child.body {
        case let .text(.anything, false, exact, text) where query.isEmpty:
            query = searchQuery(text, exact: exact)
        case let .kind(value) where kind.isEmpty:
            kind = value.rawValue
        case let .folder(url) where scope.isEmpty:
            scope = url
        case let .date(.modified, .within, age, _) where days == 0:
            days = age.rawValue
        default:
            break
        }
    }
    return (query, kind, scope, days)
}

/// Local midnight on a `YYYY-MM-DD` day, which is what "before" and "after"
/// are measured against. An unparseable day has no boundary.
func smartRuleDayStart(_ day: String) -> Date? {
    let parts = day.split(separator: "-").map { Int($0) ?? 0 }
    guard parts.count == 3 else { return nil }
    var components = DateComponents()
    components.year = parts[0]
    components.month = parts[1]
    components.day = parts[2]
    return Calendar.current.date(from: components)
}

func smartRuleDay(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

/// The index takes exactness as quoting, which is also how the old single-query
/// notebooks stored it.
func searchQuery(_ text: String, exact: Bool) -> String {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard exact, !text.isEmpty else { return text }
    return "\"" + text.replacingOccurrences(of: "\"", with: "") + "\""
}

/// The whole query is one quoted phrase, which is how a text rule stores
/// "match this exact text".
func isQuotedPhrase(_ query: String) -> Bool {
    query.count > 1 && query.hasPrefix("\"") && query.hasSuffix("\"")
        && !query.dropFirst().dropLast().contains("\"")
}
