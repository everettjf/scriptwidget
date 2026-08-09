# Governance

ScriptWidget uses a maintainer-led, contribution-friendly model. The goal is to make decisions transparent while keeping a security-sensitive Apple application coherent and shippable.

## Roles

- **Users** report needs, test releases, and share widgets or Skills.
- **Contributors** submit code, tests, documentation, designs, templates, or reviews under the project license.
- **Reviewers** are trusted contributors who consistently provide accurate review in a subsystem.
- **Maintainers** merge changes, manage releases and security reports, curate Gallery content, and set repository policy. The current lead maintainer is Everett Jiang (`@everettjf`).

Roles are earned through sustained, constructive work. Maintainers may delegate review areas and should document new maintainer or reviewer responsibilities publicly.

## Decisions

Routine fixes use pull-request review and passing release checks. Significant changes—public Runtime APIs, package formats, security boundaries, data collection, platform scope, large dependencies, or migrations—start with an issue or discussion describing the user problem, alternatives, compatibility, risk, tests, and documentation.

Maintainers seek rough consensus, but the lead maintainer has final responsibility when a decision is blocked. Decisions should cite technical and user evidence; disagreement is not misconduct. Security fixes may be developed privately and documented after coordinated disclosure.

## Compatibility and trust

Runtime and package contracts are versioned. Breaking changes require an explicit migration path and release note. Imported scripts, network content, Gallery metadata, AI output, iCloud documents, app-group storage, and credentials are security boundaries and must fail closed.

The Gallery is curated, not an unrestricted executable marketplace. Inclusion is discretionary and may be revoked for security, privacy, licensing, abandonment, misleading behavior, or repeated quality failures.

## Releases

A release candidate should pass `./Scripts/release-readiness.sh`, document known limitations, and complete the device matrix appropriate to its changes. Maintainers publish release notes from `CHANGELOG.md` and may defer a feature that cannot be verified safely.

## Policy changes

Governance changes use a pull request and normal public review. The lead maintainer may make an urgent temporary policy change for safety, followed by a documented review.
