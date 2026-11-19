# AI conversation

The AI window of the Mac app is a conversation about one widget: describe it, look at the preview, ask for a change, look again. This page says what it does, what it sends to the AI provider and what it keeps on the Mac. Provider setup is in [AI generation](ai-generate.md).

![The conversation on the left and the preview on the right; the third turn did not run and the widget stayed at version 2](images/ai-conversation-mac.png)

![The running app after a session with a local stand-in provider: a repaired turn, a turn left behind, and a change that did not run](images/ai-conversation-mac-live.png)

iPhone and iPad still have the earlier single request with a Refine field; the conversation is planned for them and will use the same shared code.

## Using it

1. Open **Generate with AI** from the sidebar menu, the empty window or the File menu.
2. Describe the widget and press Return. The preview on the right shows it as soon as it runs.
3. Ask for a change in your own words, for example "make the title smaller". The preview keeps showing the current widget while the AI works.
4. Every change that runs becomes a numbered version. **Go to This Version** under a turn, or the arrows at the bottom, show an older one. Nothing is sent to the provider when you do that.
5. If you ask for something while an older version is shown, the conversation continues from that version, and the turns after it are marked "left behind" and are no longer sent.
6. **Save Widget** saves the version on screen as a widget.

The size picker above the preview runs the widget again on the Mac at that size. It costs no tokens.

The **+** button holds Skills and examples. Skills chosen there apply to every turn of the conversation. They are text added to the request and grant nothing; see [Skills](skills.md).

## When something goes wrong

| What happened | What you see |
|---|---|
| The code did not run | The AI is told the error and tries again, up to three times. A turn that needed that says "Fixed automatically". |
| It still did not run | The widget and the preview stay as they were. The turn shows the error, **Try Again** and **Show Its Code**. |
| The provider could not be reached or refused | The turn shows the reason and **Retry**. Everything else stays usable. |
| You pressed Stop (⌘.) | The request ends at once and the widget stays as it was. |
| The app closed during a turn | The turn is shown as interrupted, with **Send Again**. |
| No provider is set up | A notice with a button to the AI settings; nothing can be sent. |

## Drafts

A conversation is saved after every change, without asking. One that has not been saved as a widget is a draft: closing the window keeps it, and the window offers it under **Continue a draft** next time. The **…** menu starts a new conversation, opens another draft or deletes the current one.

Conversations are files in the app's own Application Support folder (`ScriptWidget/AIConversations`), one JSON file each. They stay on this Mac: not in iCloud, not in the app group. The 50 most recent are kept, and each keeps its 30 most recent versions.

## What is sent to the provider

Each turn sends one request, plus one for each repair:

- the fixed instructions and API reference, the same in every turn;
- your earlier requests in this conversation with the AI's one-sentence answer to each, shortened, at most the last 12, and never those left behind;
- the current widget source, and the version before it when it is short, so that "put it back" can work;
- the selected Skills, and your new request.

A repair also sends the error and the ends of the last ten console lines of the failed run, each cut to 300 characters. A widget can print anything it read, so keep that in mind when a widget handles private data.

## What is never sent or stored

- The API key or OAuth token is read from the Keychain for the request header only. It is not written into a conversation file, a prompt, a log, UserDefaults or a widget.
- A conversation file holds your requests, the AI's notes, error summaries and widget sources. It names no provider, server or model.

## Safety

Generated code is untrusted. It runs only through the ScriptWidget runtime, in a temporary package, under the same time, memory and API limits as any widget.

One difference from a saved widget remains: the preview package has no `widget.json`, so it is treated like a legacy package and may use the network, while a widget saved from the conversation gets a new Package 2.0 manifest with no permissions. A generated widget that fetches data therefore works in the preview and needs the `network` permission and its domains added in the editor after saving. The Android app already has the AI declare this; the Apple apps do not yet.

## Limits

| | |
|---|---|
| Attempts per turn | 4: one generation and three repairs (3 in all with Apple Private Cloud Compute) |
| Request length | 4,000 characters |
| Widget source kept per version | 256 KB |
| Versions per conversation | 30 |
| Conversations kept | 50 |

## Not in this version

Streaming output, thumbnails of several sizes at once, the same conversation in the editor's Copilot panel, targeted edits instead of whole-file replies, a view of what changed between versions, and the iPhone and iPad interface.

## For contributors

- `Shared/ScriptWidgetRuntime/AI/AIConversation.swift`: the saved model and its limits.
- `AIConversationStore.swift`: the files.
- `AIConversationSession.swift`: the state a view observes; it sends turns through `AgentLoop` in its `turn` mode.
- `PromptBuilder.userPromptTurn` and `parseTurnReply`: the request and reply format.
- `macOS/ScriptWidgetMac/AIGenerate/AIGenerateWindowView.swift`: the window.
- `Tests/ScriptWidgetRuntimeTests/AIConversationTests.swift`: tests against a stub provider. They need no key and make no network request.
- The picture on this page is written by the same test file when `AI_CONVERSATION_SNAPSHOT_DIR` names a folder (prefix it with `TEST_RUNNER_` for `xcodebuild`). It draws the window with a prepared conversation; it does not click through it.
