//
//  AISourceEdits.swift
//  ScriptWidget
//
//  A reply that changes part of the current code instead of sending all of
//  it. The Kotlin port, AiSourceEdits, must read and apply the same replies
//  in the same way.
//
//  The model writes one block per place:
//
//      <<<<<<< SEARCH
//      lines copied from the current code
//      =======
//      the lines that replace them
//      >>>>>>> REPLACE
//
//  Nothing is guessed. The searched text has to be in the code exactly once;
//  otherwise the whole reply is refused and the model is asked again. What
//  comes out is run and checked like any other candidate.
//

import Foundation

/// One change to a widget's source: `search` is replaced by `replace`.
struct AISourceEdit: Equatable {
    let search: String
    let replace: String
}

enum AISourceEdits {
    static let searchMarker = "<<<<<<< SEARCH"
    static let dividerMarker = "======="
    static let replaceMarker = ">>>>>>> REPLACE"
    static let maxEdits = 20

    struct Failure: Error, Equatable {
        let reason: String
    }

    /// Whether `reply` is written as edit blocks.
    static func isEditReply(_ reply: String) -> Bool {
        lines(reply).contains { $0.trimmingCharacters(in: .whitespaces) == searchMarker }
    }

    /// The edits of `reply`, in order; nil when it has no edit block. Throws a
    /// `Failure` for a block that is not complete, has nothing to search for,
    /// or when there are too many blocks.
    static func parse(_ reply: String) throws -> [AISourceEdit]? {
        guard isEditReply(reply) else { return nil }
        var edits: [AISourceEdit] = []
        var search: [String]?
        var replace: [String]?
        for line in lines(reply) {
            let marker = line.trimmingCharacters(in: .whitespaces)
            if marker == searchMarker {
                guard search == nil else { throw Failure(reason: "an edit block starts before the one before it ends") }
                search = []
            } else if marker == dividerMarker, search != nil, replace == nil {
                replace = []
            } else if marker == replaceMarker {
                guard let from = search, let to = replace else {
                    throw Failure(reason: "an edit block ends without its SEARCH part and its ======= line")
                }
                let text = from.joined(separator: "\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Failure(reason: "edit \(edits.count + 1) has nothing in its SEARCH part")
                }
                edits.append(AISourceEdit(search: text, replace: to.joined(separator: "\n")))
                guard edits.count <= maxEdits else { throw Failure(reason: "there are more than \(maxEdits) edit blocks") }
                search = nil
                replace = nil
            } else if replace != nil {
                replace?.append(line)
            } else if search != nil {
                search?.append(line)
            }
        }
        guard search == nil else { throw Failure(reason: "the last edit block has no >>>>>>> REPLACE line") }
        return edits
    }

    /// `source` with `edits` applied one after the other. The result ends with
    /// a line break. Throws a `Failure` when a searched text is not in the
    /// code, or is there more than once.
    static func apply(_ edits: [AISourceEdit], to source: String) throws -> String {
        var text = normalized(source)
        for (index, edit) in edits.enumerated() {
            let count = occurrences(of: edit.search, in: text)
            guard count > 0 else {
                throw Failure(reason: "the SEARCH text of edit \(index + 1) is not in the current code; it has to be copied exactly, with its indentation")
            }
            guard count == 1 else {
                throw Failure(reason: "the SEARCH text of edit \(index + 1) is in the current code \(count) times; add neighbouring lines so that it is there once")
            }
            guard let range = text.range(of: edit.search, options: .literal) else { continue }
            text.replaceSubrange(range, with: edit.replace)
        }
        while let last = text.unicodeScalars.last, last == "\n" || last == " " || last == "\t" {
            text.unicodeScalars.removeLast()
        }
        return text + "\n"
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        normalized(text).components(separatedBy: "\n")
    }

    private static func occurrences(of part: String, in text: String) -> Int {
        var count = 0
        var from = text.startIndex
        while let range = text.range(of: part, options: .literal, range: from..<text.endIndex) {
            count += 1
            from = range.upperBound
        }
        return count
    }
}
