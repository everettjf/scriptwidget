# ScriptWidget Skills 1.0

Skills are reusable instructions that specialize AI generation and Copilot without changing the widget runtime. A layout reviewer, brand guide, API-integration checklist, or accessibility reviewer can be written once and selected for any prompt.

## Use and create Skills on Mac

Open **ScriptWidget > Manage Skills…** (`⇧⌘K`). Built-in Skills are read-only; duplicate one to customize it, or choose **New**. Give the Skill a clear summary and write focused Markdown instructions in `SKILL.md`, then save it. Custom Skills appear immediately in AI Generate and Studio Copilot and sync in the `Skills` folder beside widget projects.

Select only the Skills relevant to the current request. ScriptWidget appends their name, version, and complete instructions in a deterministic order after your prompt.

## Share a Skill

Choose **Export…** to create a `.swskill` archive. Another user can open Manage Skills and choose **Import**. Duplicate identifiers are rejected, so update an installed Skill in place or give a fork a new identifier.

A Skills 1.0 package contains exactly two UTF-8 text files:

```text
MySkill/
├── skill.json
└── SKILL.md
```

`skill.json` follows [skill.schema.json](../Shared/ScriptWidgetRuntime/Resource/skill.schema.json). Its `formatVersion` is `1`, `promptFile` is always `SKILL.md`, and `minimumRuntimeVersion` is currently `1.0`.

## Security model

A Skill is prompt context, not a plugin: it cannot execute code, read secrets, access files or the network, install dependencies, or grant runtime permissions. Imported archives are preflighted for unsafe paths and links, limited to 256 KiB compressed, limited to the two documented files, size-checked again while loading, and rejected when the manifest contains unknown fields. Treat imported instructions as untrusted advice and inspect them before use.

## Authoring guidance

- State the outcome and constraints precisely.
- Refer only to documented ScriptWidget runtime APIs.
- Ask for useful fallback, privacy, and accessibility behavior where relevant.
- Avoid embedding credentials, private data, or instructions that depend on local machine paths.
- Keep one Skill focused; combine several small Skills at generation time.
