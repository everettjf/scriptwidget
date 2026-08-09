//
//  AIExamplePrompts.swift
//  ScriptWidget
//
//  Curated starter prompts surfaced on the AI Generate screen. Kept
//  deliberately concrete (mentioning colors, data sources, layout)
//  so the agent loop converges quickly.
//

import Foundation

struct AIExamplePrompt: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String    // SF Symbol name
    let size: AIWidgetSize
    let prompt: String
}

enum AIExamplePrompts {
    static let all: [AIExamplePrompt] = [
        AIExamplePrompt(
            title: "Weather",
            symbol: "cloud.sun.fill",
            size: .medium,
            prompt:
                "Show the current weather for my device location using the Open-Meteo API " +
                "(https://api.open-meteo.com/v1/forecast). Dark navy background. " +
                "Big temperature in Celsius, feels-like temperature below in a smaller caption, " +
                "and the weather code. Handle missing location gracefully with a message."
        ),
        AIExamplePrompt(
            title: "Clock",
            symbol: "clock.fill",
            size: .small,
            prompt:
                "A minimalist clock widget. Show the current time as a large HH:mm, " +
                "today's weekday and date below in a muted caption. " +
                "Dark gradient background from near-black to deep purple."
        ),
        AIExamplePrompt(
            title: "Countdown",
            symbol: "calendar.badge.clock",
            size: .medium,
            prompt:
                "A countdown widget to 2026-12-31. Show days remaining as a big number, " +
                "with the label 'days until New Year' underneath. " +
                "Warm orange-to-red gradient background, light text."
        ),
        AIExamplePrompt(
            title: "Crypto Price",
            symbol: "bitcoinsign.circle.fill",
            size: .medium,
            prompt:
                "Fetch the current Bitcoin price in USD from " +
                "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true " +
                "and display it. Large USD price, a second line with the 24h change " +
                "(green with ▲ if positive, red with ▼ if negative). Black background."
        ),
        AIExamplePrompt(
            title: "Battery Ring",
            symbol: "battery.75percent",
            size: .small,
            prompt:
                "Show the device battery percentage via $device as a number in the center " +
                "of a circular gauge ring. Use green above 50%, yellow 20-50%, red below 20%. " +
                "Dark background."
        ),
        AIExamplePrompt(
            title: "Quote",
            symbol: "quote.bubble.fill",
            size: .large,
            prompt:
                "A daily quote widget. Hardcode 7 short inspirational quotes (one per weekday) " +
                "and display the one matching today's weekday. " +
                "Quote in a readable body font centered, author on a second line in caption. " +
                "Soft pastel gradient background."
        ),
        AIExamplePrompt(
            title: "Steps",
            symbol: "figure.walk",
            size: .small,
            prompt:
                "Show today's step count from $health. Large number centered, " +
                "'steps' label below in caption. Progress bar at the bottom " +
                "showing progress toward a 10000-step goal. Dark teal background."
        ),
        AIExamplePrompt(
            title: "Habit Grid",
            symbol: "checkmark.square.fill",
            size: .large,
            prompt:
                "A GitHub-style 7x5 habit tracker grid (35 cells). Hardcode a boolean " +
                "array of 35 values representing the last 35 days of a 'read 20 mins' habit. " +
                "Green filled cells for completed, gray for missed. " +
                "Header: 'Reading streak' with current streak count in the top-right."
        ),
    ]
}

/// Reusable, composable instructions that make generation behavior explicit.
/// Skills are intentionally local and version controlled: they never execute code,
/// access credentials, or widen runtime permissions.
struct AIWidgetSkill: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let instruction: String
}

enum AIWidgetSkills {
    static let all: [AIWidgetSkill] = [
        AIWidgetSkill(
            id: "responsive-layout",
            title: "Responsive Layout",
            symbol: "rectangle.3.group",
            summary: "Adapt one script to every widget family.",
            instruction: "Use $getenv(\"widget-size\") to create intentional small, medium, and large layouts. Keep the information hierarchy readable in every family."
        ),
        AIWidgetSkill(
            id: "accessible-design",
            title: "Accessible Design",
            symbol: "accessibility",
            summary: "Improve contrast, hierarchy, and legibility.",
            instruction: "Use strong text/background contrast, avoid color as the only signal, keep important text legible, and prefer concise labels."
        ),
        AIWidgetSkill(
            id: "resilient-data",
            title: "Resilient Data",
            symbol: "network.badge.shield.half.filled",
            summary: "Handle network and missing-data failures.",
            instruction: "When data is remote or optional, validate it and render a useful fallback state. Never expose secrets or invent unsupported runtime APIs."
        ),
        AIWidgetSkill(
            id: "visual-polish",
            title: "Visual Polish",
            symbol: "paintbrush.pointed",
            summary: "Apply a coherent native visual system.",
            instruction: "Create a restrained native-looking visual system with consistent spacing, typography, color, and alignment. Avoid decorative clutter."
        ),
        AIWidgetSkill(
            id: "runtime-debugger",
            title: "Runtime Debugger",
            symbol: "ladybug",
            summary: "Repair errors with the smallest safe change.",
            instruction: "Prioritize the supplied runtime diagnostic. Make the smallest correction that fixes it, preserve unrelated behavior, and use only documented ScriptWidget APIs."
        ),
    ]

    static func augment(_ prompt: String, selectedIDs: Set<String>) -> String {
        let selected = all.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return prompt }
        let instructions = selected.map { "- \($0.title): \($0.instruction)" }.joined(separator: "\n")
        return """
        \(prompt)

        Apply these ScriptWidget skills:
        \(instructions)
        """
    }
}
