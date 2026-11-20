//! What changed between two versions of a widget's code, line by line. Port
//! of `AiSourceDiff.kt`. Computed on this computer; nothing is sent anywhere.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Same,
    Added,
    Removed,
    Skipped,
}

/// One line to show. For [`Kind::Skipped`], `skipped` unchanged lines are left out and `text` is empty.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    pub kind: Kind,
    pub text: String,
    pub skipped: usize,
}

impl Line {
    fn of(kind: Kind, text: &str) -> Self {
        Self { kind, text: text.to_owned(), skipped: 0 }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Summary {
    pub added: usize,
    pub removed: usize,
}

impl Summary {
    pub fn is_empty(&self) -> bool {
        self.added == 0 && self.removed == 0
    }
}

pub struct AiSourceDiff;

impl AiSourceDiff {
    /// Unchanged lines kept around a change.
    pub const CONTEXT_LINES: usize = 3;
    /// Above this many lines on a side the comparison is not made; the caller shows the code instead.
    pub const MAX_LINES: usize = 4_000;
    /// The changed middle parts may hold this many line pairs.
    const MAX_CELLS: u64 = 4_000_000;

    pub fn split(text: &str) -> Vec<String> {
        let mut lines: Vec<String> = text.replace("\r\n", "\n").split('\n').map(str::to_owned).collect();
        if lines.last().is_some_and(String::is_empty) {
            lines.pop();
        }
        lines
    }

    /// How many lines were added and removed; `None` when a side is too long to compare.
    pub fn summary(old: &str, new: &str) -> Option<Summary> {
        let all = Self::full_lines(old, new)?;
        Some(Summary { added: all.iter().filter(|line| line.kind == Kind::Added).count(), removed: all.iter().filter(|line| line.kind == Kind::Removed).count() })
    }

    /// The changed lines with [`AiSourceDiff::CONTEXT_LINES`] unchanged ones around them; `None` when a side is too long.
    pub fn lines(old: &str, new: &str) -> Option<Vec<Line>> {
        Self::lines_with_context(old, new, Self::CONTEXT_LINES)
    }

    pub fn lines_with_context(old: &str, new: &str, context: usize) -> Option<Vec<Line>> {
        let all = Self::full_lines(old, new)?;
        if all.iter().all(|line| line.kind == Kind::Same) {
            return Some(Vec::new());
        }
        let mut keep = vec![false; all.len()];
        for (index, line) in all.iter().enumerate() {
            if line.kind != Kind::Same {
                let last = (index + context).min(all.len() - 1);
                keep[index.saturating_sub(context)..=last].fill(true);
            }
        }
        let mut result: Vec<Line> = Vec::new();
        let mut skipped = 0;
        for (index, line) in all.into_iter().enumerate() {
            if keep[index] {
                if skipped > 0 {
                    result.push(Line { kind: Kind::Skipped, text: String::new(), skipped });
                    skipped = 0;
                }
                result.push(line);
            } else {
                skipped += 1;
            }
        }
        if skipped > 0 {
            result.push(Line { kind: Kind::Skipped, text: String::new(), skipped });
        }
        Some(result)
    }

    fn full_lines(old: &str, new: &str) -> Option<Vec<Line>> {
        let before = Self::split(old);
        let after = Self::split(new);
        if before.len() > Self::MAX_LINES || after.len() > Self::MAX_LINES {
            return None;
        }
        // What both sides start and end with needs no comparison.
        let mut head = 0;
        while head < before.len() && head < after.len() && before[head] == after[head] {
            head += 1;
        }
        let mut tail = 0;
        while tail < before.len() - head && tail < after.len() - head && before[before.len() - 1 - tail] == after[after.len() - 1 - tail] {
            tail += 1;
        }
        let a = &before[head..before.len() - tail];
        let b = &after[head..after.len() - tail];
        if a.len() as u64 * b.len() as u64 > Self::MAX_CELLS {
            return None;
        }

        // Longest common subsequence of the middle parts.
        let width = b.len() + 1;
        let mut table = vec![0u32; (a.len() + 1) * width];
        for i in (0..a.len()).rev() {
            for j in (0..b.len()).rev() {
                table[i * width + j] = if a[i] == b[j] { table[(i + 1) * width + j + 1] + 1 } else { table[(i + 1) * width + j].max(table[i * width + j + 1]) };
            }
        }
        let mut result: Vec<Line> = Vec::with_capacity(before.len() + after.len());
        result.extend(after[..head].iter().map(|line| Line::of(Kind::Same, line)));
        let (mut i, mut j) = (0, 0);
        while i < a.len() || j < b.len() {
            if i < a.len() && j < b.len() && a[i] == b[j] {
                result.push(Line::of(Kind::Same, &b[j]));
                i += 1;
                j += 1;
            } else if i < a.len() && (j >= b.len() || table[(i + 1) * width + j] >= table[i * width + j + 1]) {
                result.push(Line::of(Kind::Removed, &a[i]));
                i += 1;
            } else {
                result.push(Line::of(Kind::Added, &b[j]));
                j += 1;
            }
        }
        result.extend(after[after.len() - tail..].iter().map(|line| Line::of(Kind::Same, line)));
        Some(result)
    }
}
