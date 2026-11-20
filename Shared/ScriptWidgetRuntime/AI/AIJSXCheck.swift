//
//  AIJSXCheck.swift
//  ScriptWidget
//
//  Finds tags and attributes in generated code that ScriptWidget does not
//  have. The Kotlin port, AiJsxCheck, must report the same problems for the
//  same code.
//
//  The runtime ignores an unknown attribute, and a value outside a closed
//  list, without an error: the widget runs and shows something else. The
//  repair loop can only fix what it is told, so this check tells it.
//
//  It reads the code loosely, not as a parser would, and is built to stay
//  silent when unsure: a tag whose name starts with a capital letter is taken
//  for the script's own component, and anything that is not plainly a tag is
//  skipped. It grants nothing and blocks nothing at run time; the runtime's own
//  switch stays the authority.
//

import Foundation

enum AIJSXCheck {
    /// Attribute name to its closed list of values, or nil when any value goes.
    struct Surface {
        let globals: [String: Set<String>?]
        let tags: [String: [String: Set<String>?]]
        /// Tags that draw no tag written inside them.
        let leaves: Set<String>
        /// Names in the order of the generated list, for messages.
        let globalNames: [String]
        let tagNames: [String]
        let attributeNames: [String: [String]]
    }

    static let maxProblems = 5

    /// The tags of the Apple systems: the shared ones only.
    static let apple = parseSurface(AIJSXSurfaceData.text, system: nil)

    /// Reads the generated list; `system` chooses which system-only tags count.
    static func parseSurface(_ text: String, system: String?) -> Surface {
        var globals: [String: Set<String>?] = [:]
        var tags: [String: [String: Set<String>?]] = [:]
        var globalNames: [String] = []
        var tagNames: [String] = []
        var attributeNames: [String: [String]] = [:]
        var leaves: Set<String> = []
        func attribute(_ word: Substring) -> (String, Set<String>?) {
            guard let at = word.firstIndex(of: "=") else { return (String(word), nil) }
            let values = word[word.index(after: at)...].split(separator: "|").map(String.init)
            return (String(word[..<at]), Set(values))
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ")
            guard words.count >= 2 else { continue }
            if words[0] == "leaf" {
                leaves.formUnion(words.dropFirst().map(String.init))
            } else if words[0] == "global" {
                let (name, values) = attribute(words[1])
                globals[name] = values
                globalNames.append(name)
            } else if words[0] == "tag" || (system != nil && words[0] == "tag@\(system ?? "")") {
                var own: [String: Set<String>?] = [:]
                var names: [String] = []
                for word in words.dropFirst(2) {
                    let (name, values) = attribute(word)
                    own[name] = values
                    names.append(name)
                }
                let tag = String(words[1])
                tags[tag] = own
                tagNames.append(tag)
                attributeNames[tag] = names
            }
        }
        return Surface(globals: globals, tags: tags, leaves: leaves, globalNames: globalNames, tagNames: tagNames, attributeNames: attributeNames)
    }

    /// What is wrong with `source`, at most `maxProblems` sentences; empty when nothing is.
    static func problems(in source: String, surface: Surface = apple) -> [String] {
        var found: [String] = []
        func add(_ text: String) { if !found.contains(text) { found.append(text) } }
        let scalars = Array(source.unicodeScalars)
        for tag in tags(in: source) {
            if found.count >= maxProblems { break }
            // A capital letter marks the script's own component, even one named like a tag; a dotted name is a member.
            guard let first = tag.name.unicodeScalars.first, ("a"..."z").contains(first), !tag.name.contains(".") else { continue }
            let name = tag.name
            guard let own = surface.tags[name] else {
                add("<\(name)> is not a ScriptWidget tag. The tags are: \(surface.tagNames.joined(separator: ", ")).")
                continue
            }
            if surface.leaves.contains(name), !tag.selfClosing, let inner = firstTagInside(scalars, from: tag.end) {
                add("<\(name)> takes no tags inside it, so the <\(inner)> in it is not shown. Put it next to the <\(name)>, not in it.")
            }
            for attribute in tag.attributes {
                if found.count >= maxProblems { break }
                let ownValues = own[attribute.name]
                let globalValues = surface.globals[attribute.name]
                if ownValues == nil && globalValues == nil {
                    let names = ((surface.attributeNames[name] ?? []) + surface.globalNames).joined(separator: ", ")
                    add("<\(name)> has no attribute \"\(attribute.name)\"; it would be ignored. Its attributes are: \(names).")
                    continue
                }
                if attribute.name == "frame", let value = attribute.literal, !frameIsRead(value) {
                    add("frame=\"\(value)\" on <\(name)> is not a frame ScriptWidget reads; it would be ignored or centered. \(frameHelp)")
                    continue
                }
                // The tag's own list wins over the general one, as in the Kotlin port.
                guard let allowed = (ownValues ?? nil) ?? (globalValues ?? nil), let value = attribute.literal else { continue }
                if !allowed.contains(value) {
                    let values = orderedValues(name: name, attribute: attribute.name)
                    add("\(attribute.name)=\"\(value)\" on <\(name)> is not one of its values; it would be ignored. Use one of: \(values.joined(separator: ", ")).")
                }
            }
        }
        return found
    }

    static let frameAlignments: Set<String> = [
        "center", "leading", "trailing", "top", "bottom", "topLeading", "topTrailing", "bottomLeading", "bottomTrailing",
    ]

    static let frameHelp = "Write it without spaces as one of: \"max\", \"max,leading\", \"60\", \"60,40\", \"60,40,leading\", "
        + "\"max,40\", \"max,40,leading\", \"60,max\", \"60,max,leading\". The alignments are: center, leading, trailing, top, bottom, "
        + "topLeading, topTrailing, bottomLeading, bottomTrailing. There is no \"auto\": for a row as wide as the widget "
        + "and as tall as its content, put a <spacer/> inside an <hstack>."

    /// Whether the runtime reads `value` as written. Follows
    /// ScriptWidgetAttributeFrameModifier: a value it drops, and an alignment
    /// it does not know and replaces with center, are both "not read".
    static func frameIsRead(_ value: String) -> Bool {
        let parts = value.split(separator: ",").map(String.init)
        func number(_ text: String) -> Bool { frameNumber(text) != nil }
        func alignment(_ text: String) -> Bool { frameAlignments.contains(text) }
        switch parts.count {
        case 1:
            if value == "max" { return true }
            guard parts[0] == value, let side = frameNumber(value) else { return false }
            return side >= 0
        case 2:
            let (a, b) = (parts[0], parts[1])
            if number(a) { return number(b) || b == "max" }
            return a == "max" && (number(b) || b == "max" || alignment(b))
        case 3:
            let (a, b, c) = (parts[0], parts[1], parts[2])
            guard alignment(c) else { return false }
            return (number(a) && (number(b) || b == "max")) || (a == "max" && number(b))
        default:
            return false
        }
    }

    /// A plain decimal such as 60, -4 or 12.5; nothing else, and no spaces.
    private static func frameNumber(_ text: String) -> Double? {
        var digits = 0
        var dots = 0
        for (index, scalar) in text.unicodeScalars.enumerated() {
            if isDigit(scalar) { digits += 1 } else if scalar == "." { dots += 1 } else if !(index == 0 && (scalar == "-" || scalar == "+")) { return nil }
        }
        guard digits > 0, dots <= 1 else { return nil }
        return Double(text)
    }

    /// One text for the model, or nil when `source` has no problem.
    static func summary(of source: String, surface: Surface = apple) -> String? {
        let problems = problems(in: source, surface: surface)
        guard !problems.isEmpty else { return nil }
        return "The code uses tags or attributes that ScriptWidget does not have:\n" + problems.map { "- \($0)" }.joined(separator: "\n")
    }

    /// The values of a closed list in the order they were generated in.
    private static func orderedValues(name: String, attribute: String) -> [String] {
        for line in AIJSXSurfaceData.text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ")
            guard words.count >= 2 else { continue }
            let candidates: ArraySlice<Substring>
            if words[0] == "global" { candidates = words[1...] } else if words[1] == name { candidates = words.dropFirst(2) } else { continue }
            for word in candidates where word.hasPrefix(attribute + "=") {
                return word.dropFirst(attribute.count + 1).split(separator: "|").map(String.init)
            }
        }
        return []
    }

    struct Attribute: Equatable {
        let name: String
        /// The value when it is written as a plain string.
        let literal: String?
    }

    struct Tag: Equatable {
        let name: String
        let attributes: [Attribute]
        /// The index, in Unicode scalars, after the tag's `>`.
        var end = 0
        var selfClosing = false
    }

    private static let tagBeforeKeywords: Set<String> = [
        "return", "yield", "case", "default", "await", "else", "do", "in", "of", "typeof", "void", "delete", "new", "throw",
    ]

    /// The opening tags of `source`, read loosely.
    static func tags(in source: String) -> [Tag] {
        let text = Array(source.unicodeScalars)
        let length = text.count
        var result: [Tag] = []
        var index = 0
        while index < length {
            let character = text[index]
            if character == "/", index + 1 < length, text[index + 1] == "/" {
                while index < length, text[index] != "\n" { index += 1 }
            } else if character == "/", index + 1 < length, text[index + 1] == "*" {
                index += 2
                while index < length, !(text[index] == "*" && index + 1 < length && text[index + 1] == "/") { index += 1 }
                index = min(length, index + 2)
            } else if character == "\"" || character == "'" {
                index = skipQuoted(text, from: index, sameLineOnly: true)
            } else if character == "`" {
                index = skipQuoted(text, from: index, sameLineOnly: false)
            } else if character == "<", index + 1 < length, isLetter(text[index + 1]), startsTag(text, at: index) {
                if let (tag, next) = readTag(text, from: index + 1) {
                    result.append(tag)
                    index = next
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return result
    }

    /// Whether the `<` at `at` can open a tag: after an operator or a keyword, not after a value.
    private static func startsTag(_ text: [Unicode.Scalar], at: Int) -> Bool {
        var before = at - 1
        while before >= 0, isSpace(text[before]) { before -= 1 }
        guard before >= 0 else { return true }
        let character = text[before]
        if character == ")" || character == "]" { return false }
        guard isWord(character) else { return true }
        var start = before
        while start >= 0, isWord(text[start]) { start -= 1 }
        return tagBeforeKeywords.contains(string(text, start + 1, before + 1))
    }

    /// Reads a tag whose name starts at `from`; the tag and the index after its `>`, or nil when it is not one.
    private static func readTag(_ text: [Unicode.Scalar], from: Int) -> (Tag, Int)? {
        let length = text.count
        var index = from
        while index < length, isLetter(text[index]) || isDigit(text[index]) || text[index] == "." || text[index] == "_" { index += 1 }
        let name = string(text, from, index)
        var attributes: [Attribute] = []
        while true {
            while index < length, isSpace(text[index]) { index += 1 }
            guard index < length else { return nil }
            let character = text[index]
            if character == ">" { return (Tag(name: name, attributes: attributes, end: index + 1, selfClosing: false), index + 1) }
            if character == "/" {
                guard index + 1 < length, text[index + 1] == ">" else { return nil }
                return (Tag(name: name, attributes: attributes, end: index + 2, selfClosing: true), index + 2)
            }
            if character == "{" {
                // {...spread}
                guard let end = skipBraces(text, from: index) else { return nil }
                index = end
                continue
            }
            guard isLetter(character) || character == "_" else { return nil }
            let start = index
            while index < length, isLetter(text[index]) || isDigit(text[index]) || text[index] == "_" || text[index] == "-" || text[index] == ":" { index += 1 }
            let attributeName = string(text, start, index)
            while index < length, isSpace(text[index]) { index += 1 }
            guard index < length, text[index] == "=" else {
                attributes.append(Attribute(name: attributeName, literal: nil))
                continue
            }
            index += 1
            while index < length, isSpace(text[index]) { index += 1 }
            guard index < length else { return nil }
            let opener = text[index]
            if opener == "\"" || opener == "'" {
                var end = index + 1
                while end < length, text[end] != opener { end += 1 }
                guard end < length else { return nil }
                attributes.append(Attribute(name: attributeName, literal: string(text, index + 1, end)))
                index = end + 1
            } else if opener == "{" {
                guard let end = skipBraces(text, from: index) else { return nil }
                let inner = string(text, index + 1, end - 1).trimmingCharacters(in: .whitespacesAndNewlines)
                let scalars = Array(inner.unicodeScalars)
                // {"value"} is as plain as "value".
                var literal: String?
                if scalars.count >= 2, let quote = scalars.first, quote == "\"" || quote == "'", scalars.last == quote,
                   !scalars[1..<(scalars.count - 1)].contains(quote), !scalars.contains("\\") {
                    literal = string(scalars, 1, scalars.count - 1)
                }
                attributes.append(Attribute(name: attributeName, literal: literal))
                index = end
            } else {
                return nil
            }
        }
    }

    /// The name of a tag written directly inside the tag whose `>` ends at
    /// `from`, before that tag closes; nil when there is none. What stands in
    /// `{...}` is passed over: it is computed, and not judged.
    private static func firstTagInside(_ text: [Unicode.Scalar], from: Int) -> String? {
        var index = from
        while index < text.count {
            let character = text[index]
            if character == "{" {
                guard let end = skipBraces(text, from: index) else { return nil }
                index = end
            } else if character == "<" {
                guard index + 1 < text.count, isLetter(text[index + 1]) else { return nil }
                var end = index + 1
                while end < text.count, isLetter(text[end]) || isDigit(text[end]) || text[end] == "." || text[end] == "_" { end += 1 }
                return string(text, index + 1, end)
            } else {
                index += 1
            }
        }
        return nil
    }

    /// The index after the `}` that closes the `{` at `from`, or nil when it is not closed.
    private static func skipBraces(_ text: [Unicode.Scalar], from: Int) -> Int? {
        var depth = 0
        var index = from
        while index < text.count {
            let character = text[index]
            if character == "{" {
                depth += 1
                index += 1
            } else if character == "}" {
                depth -= 1
                index += 1
                if depth == 0 { return index }
            } else if character == "\"" || character == "'" {
                index = skipQuoted(text, from: index, sameLineOnly: true)
            } else if character == "`" {
                index = skipQuoted(text, from: index, sameLineOnly: false)
            } else {
                index += 1
            }
        }
        return nil
    }

    /// The index after the quoted text that starts at `from`. A quote that is
    /// not closed on its line, an apostrophe in a sentence for one, is passed
    /// over as a single character.
    private static func skipQuoted(_ text: [Unicode.Scalar], from: Int, sameLineOnly: Bool) -> Int {
        let quote = text[from]
        var index = from + 1
        while index < text.count {
            let character = text[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == quote { return index + 1 }
            if sameLineOnly, character == "\n" { return from + 1 }
            index += 1
        }
        return from + 1
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }

    private static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        isLetter(scalar) || isDigit(scalar) || scalar == "_" || scalar == "$"
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }

    private static func string(_ text: [Unicode.Scalar], _ from: Int, _ to: Int) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: text[from..<to])
        return String(view)
    }
}
