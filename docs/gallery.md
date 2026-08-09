# Widget & Skills Gallery

The Gallery is the shared, GitHub-backed catalog in ScriptWidget for installing community widgets and reusable AI Skills. On Mac, open **Widget & Skills Gallery** from the File menu (`⌘⇧G`) or **Community Gallery** in the sidebar. On iPhone and iPad, open **New Widget → Community Gallery**.

## Trust model

The curated `Gallery/index.json` in this repository is the trust root, and a human curator reviews every catalog change. ScriptWidget accepts only an HTTPS `raw.githubusercontent.com` index and HTTPS GitHub source links. Before an item reaches the widget or Skill importer, every listed file must match its declared path, exact byte count, and lowercase SHA-256 digest. Unknown JSON properties, redirects to another host, unsafe paths, case-colliding files, unsupported runtime versions, and oversized packages fail closed.

Hashes make changes reviewable and detect corrupted or substituted downloads, but they do not make arbitrary community code trustworthy: a party able to change the curated index can also change its hashes. Review the linked source before installing. Widgets run within ScriptWidget's documented runtime and declared Package 2.0 permissions; Skills are prompt guidance and cannot execute code.

The index is cached for 15 minutes. ScriptWidget sends `If-None-Match` when GitHub provides an ETag and uses the last fully validated cache when offline. GitHub rate-limit responses are shown without silently accepting unverified data.

## Submit a widget

1. Create a Package 2.0 folder containing `widget.json` and `main.jsx` (plus any declared assets).
2. Use a stable reverse-DNS `id`, semantic version, SPDX-style license name, and runtime version `1.0`.
3. Put the reviewed files under `Gallery/widgets/<slug>/` and add one index item. Each raw URL must point to the eventual `main` path.
4. Set each `bytes` value to the exact file size and `sha256` to the SHA-256 of the exact committed bytes.
5. Run `./Scripts/release-readiness.sh` and include screenshots for small, medium, and large families when supported.

## Submit a Skill

Skills must contain exactly `skill.json` and `SKILL.md`, follow Skills 1.0, and remain below 256 KiB. Put them under `Gallery/skills/<slug>/`, add their exact sizes and hashes to the index, and run the release checks. Instructions must be narrowly scoped, disclose important tradeoffs, avoid secrets, and never claim unavailable tools or runtime APIs.

## Updating an item

Raise the semantic version whenever content changes, update every affected size and hash, and describe the migration or behavioral change in the pull request. ScriptWidget also treats a changed fingerprint at the same version as an available update, so an emergency corrected artifact is not hidden; normal submissions should still bump the version.

## Curator checklist

- Confirm the source repository and author/license information.
- Review network domains, permissions, privacy behavior, fallback UI, and generated Prompt guidance.
- Verify Package 2.0 or Skills 1.0 locally and reject symlinks or paths outside the package.
- Recalculate sizes and hashes from the committed files; never copy values supplied only in a PR description.
- Test install, update, offline cache, and representative widget families on both macOS and iOS/iPadOS.
