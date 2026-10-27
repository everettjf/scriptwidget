# Package storage and atomic updates

`$storage` stores local values under the current package namespace. It does not sync records through iCloud. String and JSON keys cannot exceed 256 UTF-8 bytes, and each stored value cannot exceed 256 KiB. Reads return an empty string/object for a missing key; writes return a Boolean that the script must check.

- `getString(key)` / `setString(key, value)` read and write strings.
- `getJSON(key)` / `setJSON(key, object)` read and write JSON objects.
- `keys()`, `remove(key)` and `clear()` apply only to this package.

Runtime 1.3 adds `compareAndSetString(key, expected, replacement)` and `compareAndSetJSON(key, expected, replacement)`. They replace a value only if it still equals what the script read. A missing string matches `""`; a missing JSON object matches `{}`. A stored value of another type does not match. JSON property order does not affect comparison, and malformed stored JSON is preserved rather than silently replaced.

## Updating a counter

```jsx
let saved = false;
for (let attempt = 0; attempt < 4; attempt++) {
  const previous = $storage.getString("water.count");
  const count = previous === "" ? 0 : Number(previous);
  if (!Number.isInteger(count) || count < 0) throw new Error("Restore the saved count before changing it.");
  if ($storage.compareAndSetString("water.count", previous, String(count + 1))) {
    saved = true;
    break;
  }
}
if (!saved) throw new Error("Storage is busy or unavailable. Try again.");
$render(<text>Saved</text>);
```

Perform this mutation from a named button/action handler, not during ordinary widget rendering. Reread and validate on every retry. A compare conflict, invalid input, unavailable shared container or lock timeout returns `false`. Keep retries bounded; do not spin indefinitely inside a widget extension.

Applications and extensions coordinate mutations with a package-scoped OS file lock. Lock acquisition is limited to 200 ms. Preference caches refresh inside the lock before comparing, and native JavaScript callbacks never run while it is held. Ordinary writes, removals, clears and declared toggle state writes use the same coordinator when shared storage is available. Separate reads followed by ordinary `setString/setJSON` are still not atomic; use a compare-and-set method for shared read/modify/write operations.

The default legacy path retains the existing UserDefaults persistence mechanism and its durability semantics. Applied writes request preference synchronization. Lock files are generated bookkeeping outside authored packages and remain in place across clear operations, so an active lock cannot be replaced by a new inode. Their paths derive from a hash of the namespace; symlinked child directories/files and nonregular or multiply-linked lock files are rejected.

Existing template string/JSON formats remain compatible. The default legacy path requires no record-format migration; activating the native UUID/file context requires the separate identity migration described below. In particular, **Habit Heatmap** keeps its existing `habitHeatmap.v1.*` string format, validates it before each check-in and retries conflicts while preserving the other writer's day. Its package declares minimum Runtime 1.3. Normal rendering never creates check-in history.

## Web preview

Mock Data → Storage sets initial values for each preview run. Reads, writes and comparisons execute normally against that state; per-method response overrides cannot force CAS success. Choose **Atomic updates → Unavailable / busy** to exercise a save-failure branch while keeping readable history. `storageAtomicAvailable: false` is the equivalent fixture field. Preview data is not exported with the package.

## Verification

`node Scripts/test-storage-atomic.mjs` compiles the production coordinator and starts eight independent processes behind a start barrier. It requires all 400 increments to survive. An intentionally uncoordinated negative control must lose updates, demonstrating that the test exposes the race. The release-readiness gate includes this test on Apple build hosts.

Unit and runtime tests cover stale comparisons, type conflicts, UTF-8 budgets, canonical JSON equality, namespace isolation, hostile lock paths, bounded lock contention and heatmap retries. Unsigned bridge tests inject an isolated directory and preference domain; they do not establish real signed App Group acceptance. Device/extension acceptance remains a separate release gate.

The native file probe deliberately holds an owner lock until an actual rejection is observed. It confirms the bounded denial, then requires four independent workers to commit exactly 400 increments with matching mirror values. Only attempts that never entered the lock may retry, within a probe-only deadline; locked transaction failures are fatal. Both a mismatched pair and a malformed record file must fail immediately without retries or changes. Crash-before/after and all 32 capacity values remain checked. The driver waits for every child before deleting its disposable root. These checks do not change the runtime's 200 ms lock limit or establish signed app/widget access.

## Interactive record templates

**Hydration Goal**, **Mood Check-in**, **Packing Checklist**, and **Habit Streak Tracker** now save real local records through package storage (Runtime 1.3). A normal render never creates a record. On iOS 17+/macOS 14+, use their Home Screen buttons; accessory widgets show a summary. Older systems can display records but cannot execute these widget buttons.

- Hydration: optional widget parameter `{"goal":8,"glassML":250}`. Add one glass with a tap. Stored values are millilitres, so changing glass size does not reinterpret previous days. The supported goal is 1–32 glasses and each glass is 25–2000 mL; these are configuration bounds, not a medical recommendation. Legacy `current,goal` input keeps its goal, but never seeds the sample current count as real history.
- Mood: select one of five moods to save or replace today's check-in. Re-selecting the same mood does not create another change. The optional parameter is a short intention or `{"intention":"Take a pause"}`.
- Packing: supply 1–8 unique comma-separated labels, such as `Tickets,Water,Keys`. Each tap toggles that label. Reordering labels preserves checks; renaming a label creates a different item. Small/medium layouts show the first few labels; use a large widget for the full list.
- Habit streak: supply a habit name such as `Read`, then tap **Check in**. Repeated taps on the same day do not add records. Yesterday’s streak remains visible until today’s check-in; a missed calendar day breaks the streak. It uses local dates and calendar arithmetic across daylight-saving/year boundaries. At the 366-day retained-history limit it shows `366+`, a lower bound rather than an invented exact total.

**Reset today** clears today's entry, preserving other days. **Undo** restores the most recent successful change once, including a reset; another undo does nothing. It operates on the latest shared package change, so another widget's intervening edit becomes the newest undo target. A new edit replaces that one-step undo snapshot. Large widgets show recent daily history, and writes retain up to 366 local calendar days. Each midnight begins a new daily entry; refresh alone does not mark it complete. The four examples use separate keys (`hydration.v1`, `mood.v1`, `checklist.v1`, `habitStreak.v2`) and keep all data within their package namespace.

The complete template includes `lib/records.js`; install/copy the whole package. Invalid saved data is preserved and produces an error instead of being replaced with an empty record. Atomic updates retry conflicts at most four times and report unavailable storage. For Web Studio, seed these keys under Mock Data → Storage to preview history; each preview run starts from the selected mock state, and it never writes device records. Clearing app storage or deleting/renaming a package is not a backup or sync workflow; use the native record manager below for supported templates; arbitrary script storage still needs its own workflow.

Direct `onClick` button/toggle functions receive the widget's `widget-param` during execution, matching the configuration that produced the label. Declared actions invoked from Shortcuts/control surfaces continue to use their own action context; these four examples do not declare parameter-dependent system actions.


### Record boundaries and older habit counters

Hydration rejects an added glass that would exceed the template’s 64,000 mL storage bound; it keeps the original value and reports an error rather than recording only part of a glass. This is a data bound, not a suggested intake. The history window includes today and the preceding 365 local dates. Rendering does not prune records; successful explicit edits remove dates before that window. A device date rollback does not silently discard future entries to make room: a full history returns an error and preserves the original data. Undo cannot restore an entry outside the retained window.

The former built-in Habit Streak Tracker incremented its counter during refresh, so its `habit.streak` / `habit.lastDate` values are not verified check-ins. The new example preserves those keys, labels an earlier counter as unverified, and starts explicit records under `habitStreak.v2`. Reset and Undo apply to the new records only. Existing personal packages are user-authored files and are not automatically rewritten by an app update; installing a new template creates a separate package. If you update the source of an existing package, copy its helper too, keep a backup, and retain the old keys for reference rather than inventing completed dates.

## Native record manager

In **My Widgets** on iPhone/iPad, long-press a supported record template (or swipe right) and choose **Records & Configuration**. On Mac, right-click its sidebar entry. This supports Hydration Goal, Mood Check-in, Packing Checklist, Habit Streak Tracker and Habit Heatmap.

The sheet edits the daily goal/glass size, intention, checklist labels, or habit names. Choose **Save Configuration** to apply the changes. Defaults are shared by instances of that package; a widget instance parameter can override them in the four templates that accept parameters. Heatmap names use their stored defaults, keeping the stable `read`, `run` and `meditate` IDs and their history. Ordinary rendering never saves configuration.

**History** shows the retained calendar-day records, with more rows available on demand. **Export Record Backup** saves a separate JSON file containing only the selected template's recognized record/configuration keys. Script package exports do not contain these records. **Choose Backup to Restore** first shows the source widget, time, daily record count and configuration. Confirm **Replace Local Records** to replace the selected package's recognized values, including removing recognized values absent from the backup. It never adopts a namespace or file path from the backup. If records change after the preview, the operation fails and asks you to reload rather than losing the intervening edit.

Backups for another record kind, unsupported versions/keys, invalid record dates/values, invalid settings or files over 1 MiB are rejected before mutation. Restore and configuration changes use the same cross-process coordinator as widget actions. Invalid string records can still be exported for safekeeping. Wrongly typed values are exported as diagnostic `unsupportedValues`; those diagnostic files cannot be restored directly. A valid earlier backup can replace such corrupt values after preview and confirmation. Unrelated storage keys are never included or modified.

Record templates opt into this native sheet with a small package resource:

```json
{"formatVersion":1,"kind":"hydration"}
```

The file is `record-template.json` (at most 4 KiB). Supported kinds are `hydration`, `mood`, `checklist`, `habitStreak`, `habitHeatmap` and configuration-only `countdown`/`photoCard`/`weather`/`healthCard`/`repoStats`/`launcher`. It grants no permissions: the package must still have a valid manifest and declare `storage`. The native sheet does not run package JavaScript to inspect, configure, export or restore records. It can read validated cached descriptors/manifests after iCloud eviction even when the script entry is not locally available; a present invalid descriptor never falls back to an older valid one.

The saved configuration is a string under `recordTemplate.config.v1`, read and validated by the package-local helper:

```json
{"version":1,"kind":"hydration","values":{"goal":8,"glassML":250}}
```

It is limited to 4 KiB and rejects unknown fields, types, unsupported versions and kind mismatches. All five bundled helpers share its validation rules. Web Studio can preview these defaults by seeding this storage key, keeping simulated data separate from native records. The backup envelope is documented by [record-backup.schema.json](../Shared/ScriptWidgetRuntime/Resource/record-backup.schema.json); native semantic validation additionally checks the JSON strings' record format and byte budgets.

## Native identity migration under development

The native UUID identity coordinator and publication journal are implemented. In the development worktree, ordinary app startup opens an activated profile before authoring UI, and storage, actions and native record sheets use its bound installation identity. Legacy compatibility consumers are fenced once activation begins. Signed-container and device acceptance remain required before release. These internal IDs are not a new package-manifest field, JavaScript capability, backup field or iCloud-synced record format.

The coordinator freezes a native inventory, retains every legacy original, and copies only unambiguous values into separate UUID namespaces. An incomplete inventory cannot automatically resolve compound dotted keys. Ambiguous values require native preview and an explicit assignment; source and target changes invalidate that preview. Reusing a removed name creates a fresh identity, while a native rename retains its identity.

Fresh directory publication uses a separate bounded journal under the same registry lock. Preparation and validation happen before taking the lock; only directory inspection and atomic publication belong inside it. The native caller supplies its library-location hash and a device/inode receipt for the prepared directory. Those values must come from trusted native filesystem operations, never imported package metadata. An occupied destination is rejected before a reservation is written.

The journal blocks lookup for the affected name and excludes other identity mutations until recovery finishes. A matching published directory commits the exact reserved UUID; an absent destination rolls back a reservation that was never exposed. A different directory, inaccessible root or invalid journal remains unresolved instead of guessing or deleting anything. Recovery never reruns publication. If the registry commit completed before journal cleanup, later disappearance of the directory cannot reactivate the previous identity. Old records remain preserved throughout. Preference synchronization retains the existing UserDefaults persistence semantics; process-crash tests are not power-loss or signed-device acceptance.

The process probe covers a simultaneous eight-publisher race and forced process exit immediately before and after rename, followed by recovery in an independent process. These probes exercise the production coordinator with isolated temporary directories/preferences; their filesystem callback is a fixture, so they do not prove that the app installer, Share extension, iCloud source/cache paths or WidgetKit have been connected.

The package manager now has an explicit native storage context for installing prepared packages. With that context supplied after native inventory, blank creation, template installation, Remix and archive import use the journal through the actual descriptor-based directory publisher. The context binds its library location to the native root directory identity, rejects a replaced root, and can recover a pending publication after recreation in a new context. It never initializes migration from an imported name or a manifest ID. The app's default manager now resolves the ready native profile; startup activation, Gallery updates, rename/delete, library selection and runtime/action/record-sheet consumers use the coordinated paths. Tests use isolated storage and real package-manager operations; they do not establish signed production-container acceptance.

New blank projects prepare source, optional images and a valid manifest before atomic publication, including when identity migration is disabled. Failure leaves no partial library package. Editing a manifestless legacy package keeps its format; a present invalid manifest is rejected before the main file is changed. Public manifest IDs and the native storage identities remain separate concepts.

### Source and cache directory bindings

The opt-in identity context now records native source/cache directory bindings outside packages. Each binding carries the native owner, package name, directory role, native root-location identifier and device/inode receipt. Lookup requires the current active owner and a matching location, role and actual directory receipt; a manifest ID or copied file cannot create that grant. A native legacy inventory may associate a source directory once; a changed directory or root needs an explicit migration decision. Outstanding legacy-record review still blocks normal bound lookup.

The real cache builder captures the authenticated source binding before copying, revalidates the prepared tree, and checks the source snapshot again during publication. An outdated copy cannot bind to a newer same-name install. Cache publication uses a descriptor-based atomic directory exchange; the old cache occupies the staging location until cleanup. Cache roots cannot overlap the authored library. Normal cache rebuilding can bind a recreated disposable cache root after validating the source again.

If a host exits after the directory exchange but before its binding is saved, lookup rejects that unrecorded cache. Rebuilding restores it; the reader never guesses ownership from its code or manifest. Retired identities retain their own bindings for recovery but cannot resolve an active scope. Rolling back an unexposed new identity removes only that identity's provisional bindings, preserving the previous owner's fallback cache and records. The private directory index is limited to 8192 entries/4 MiB, with one source and one cache binding per identity; malformed present metadata is rejected rather than reset.

These binding APIs and the opt-in cache builder are verified native modules. The default application, native action dispatch and per-file fallback readers have **not** switched to bound directory scopes yet; the record sheet uses them only when its native manager supplies an activated storage context; these module tests do not establish production-wide isolation or real iCloud/device acceptance.

### Opt-in execution snapshots

Native callers can construct `ScriptWidgetExecutionSnapshot` from a bound source or whole-cache directory and supply it to a runtime. It streams a private copy through directory descriptors, rejecting links, special files, aliases, changing file identities and resource-limit violations. The original binding is checked again after copying. The copied manifest, entry, imports, JSON and images are then read through the same readonly package, without mixing source and per-file cache paths. The renderer retains that package for resource lifetime.

The default limits are 500 entries, 16 levels, 25 MiB per resource, 64 MiB per snapshot and 512 KiB for the entry. Private kernel leases keep active resources alive, cap active snapshots at 32 per temporary root and allow subsequent acquisitions to remove unleased folders after a host exits. Releasing the last retained package removes its snapshot. These bounds are not physical-device performance or power-loss acceptance.

Snapshot-backed execution requires its main input to match the captured entry. An unsaved editor preview must explicitly request a native entry override when capturing. This prevents an old caller string from silently adopting a later manifest. The opt-in path skips the legacy global compiled-artifact load/save and last-known-good fallback; compilation goes through the normal guarded compiler. Default non-snapshot runtimes retain their existing behavior. A trusted identity-aware artifact cache/performance review remains part of the activation work.

`$storage` in this opt-in path uses the captured native UUID and original native preferences/container, rather than the private copy's filesystem location. Package 2.0 still requires `storage`. Identity changes cancel the session and fail explicitly, not as an empty record set. String/JSON writes and compare-and-set check the same 1024-key/2 MiB aggregate budget under coordination; shrinking or clearing older oversized data remains possible. Timeline projections cannot mutate records. Default legacy runtimes retain their existing namespace and behavior until the coordinated migration is enabled.

Real JSC tests cover frozen imports/files/manifest/images, UUID persistence across snapshots, explicit editor overrides, same-name reinstall denial, permission declarations, projections, aggregate budgets, whole-cache offline execution, global artifact rejection and retained resource cleanup. Entry/file budget and link/FIFO/lease boundaries are also exercised. Native actions, data-API identity checks, record sheets, library lifecycle and migration review now accept the injected context. Default startup/cutover and library switching still require integration and acceptance before this feature is enabled for users.

### Asynchronous API ownership

The native Promise bridge now captures the execution state (or the resolver's associated context for a native-created promise). It validates the execution before starting a producer and again on the execution's serial callback queue before handing a payload to user code. Only the first settlement is accepted. Finished sessions discard late success/error values; a replaced snapshot cancels its session and cannot hand the old payload to a continuation.

Network, Calendar, Location and Data Source Plugin requests also recheck identity at their native query, cache-write and delivery boundaries. Redirects must preserve the frozen package's declared domains and public-host policy; plugin redirects additionally remain HTTPS-only and inside the plugin's own hosts. Snapshot Calendar caches use the snapshot's original storage backend. Future Location entries can use an authorized saved location but cannot start a live fix.

Health reads and authorization review participate in the shared eight-query execution limit. Native Health queries register bounded cancellation resources; session finish/cancellation stops outstanding queries, and completion removes the resource registration. Projection and query-limit rejection precede HealthKit access. Actual HealthKit authorization/query cancellation still requires device acceptance: deterministic tests cover the guards and cancellation lifecycle without reading health records or presenting permission prompts.

Session-lifetime and one-settlement checks also apply to legacy native API requests. Directory ownership revalidation requires a supplied execution snapshot; default non-snapshot runtimes cannot gain that protection merely from this bridge change. These checks do not activate UUID startup migration. Actions and record management use the context only when their native manager supplies it; signed-device/iCloud acceptance remains separate.


### Native record manager integration

The native record manager accepts an execution snapshot and uses its frozen template descriptor and storage permission, original storage backend, and UUID namespace. Reads, configuration updates, history and explicit backup restoration revalidate the binding; validation is repeated inside the record lock before reading or modifying records. Bulk replacement checks the same whole-namespace key/byte budget before changing any key, including keys outside the record template's fixed export allowlist.

When the live native manager has an activated storage context, opening the record sheet captures a bound source snapshot. It refuses readonly previews and packages outside that library. The name-based compatibility path is available only before native activation and is fenced once activation begins. Backup metadata cannot choose or replace a native owner: a user may explicitly restore old records into a new installation, while the old sheet remains invalid and the old values are retained.

This integration does not by itself activate migration or prove actual native file-picker interaction, WidgetKit clicks, signed shared containers, iCloud behavior or physical-device performance.

### Native actions and control state

With an activated native storage context, the action catalog enumerates validated manifest metadata and directory bindings without allocating execution snapshots for every package. Selecting an action captures one bound package, verifies the original owner and reviewed manifest, and runs its frozen entry. Manifests cannot supply a native storage owner. A bound system action/control identifier includes that native owner; a saved identifier cannot follow a same-name installation, even when the public package ID is reused. Legacy identifiers remain in non-migrated mode; ambiguous public-ID matches now fail instead of selecting the first package. Migration of existing system selections still needs the startup/migration product flow.

Toggle writes, native control-state reads and action code share the captured UUID/backend, permission checks, coordination and aggregate storage budget. A refused state write does not execute the action or reload the widget. The existing action semantics remain: an accepted toggle value is persisted before its function runs; a later function failure does not roll back that value.

The renderer retains its native execution snapshot independently of the weak runtime reference. Declared buttons/toggles use the scoped catalog. Direct `onClick` intents serialize explicit String parameters and reconstruct their bound snapshot at the receiving host, as described below. A direct intent without a captured scope cannot silently adopt an active migrated installation. Metadata/host tests do not prove end-to-end WidgetKit click delivery; that remains a separate acceptance check before default activation.

### Source rename and uninstall transactions

An activated package manager uses a persistent native relocation journal for same-library renames and uninstall. The journal contains the original bound receipt and owner; packages cannot choose these values. A rename preserves the UUID, verifies an absent destination, and commits the moved source binding. Old execution scopes and the old named cache become invalid; the cache can be rebuilt under the new name. An uninstall first atomically moves the source to a hidden native tombstone, then retires the owner. Original records are retained, and a later same-name install receives a fresh owner.

Recovery only inspects actual directory receipts: an unchanged source with an absent destination rolls back an uncommitted intent; a matching destination with an absent source commits it. A different/inaccessible directory, foreign root, invalid journal or contradictory committed state is refused with the journal preserved. Recovery never reruns a move or revives an already committed former name. A pending relocation blocks both affected names and other identity mutations. It does not run recursive copies, cleanup or JavaScript under the identity lock.

Retired tombstone cleanup runs outside that lock, checks the exact original receipt and uses bounded descriptor traversal. A maintenance call attempts at most eight matching tombstones; substituted directories are preserved. The original retired directory bindings let maintenance recover cleanup missed by a host exit after journal commit. Preference records and ordinary source/cache paths are not part of tombstone cleanup. These opt-in paths do not activate startup migration, complete Gallery replacement/library switching, or constitute signed iCloud/device acceptance.

A native retry recognizes a just-recovered relocation of the same source and requested destination as completed, including uninstall. It does not proceed to look up a source that the recovered transaction already moved. Fresh source publication also recovers a pending relocation before allocating another owner.

### Gallery provenance and identity-preserving updates

An activated native library records the verified Gallery item association in its private owner index. Public manifest IDs and the separate Gallery installation-list file do not confer that association. Native lookup follows renames, refuses unknown roots and stops using retired owners. Imports/remixes remain fresh installations without Gallery provenance, even if their public ID matches a Gallery item. Existing non-migrated Gallery behavior is retained until startup migration is enabled.

Verified downloads are copied through the bounded descriptor reader into a native stage on the same library volume, then validated again, including the UTF-8 entry's 512 KiB limit. Fresh publication allocates a new native UUID. Updating an associated installation journals an atomic directory exchange: the UUID and record values stay unchanged, the source receipt changes and old cache bindings are removed. Old execution snapshots cannot continue under the replacement. No download, recursive copy, JavaScript execution or cleanup runs under the identity lock.

Recovery examines both installed and staging receipts. An unperformed exchange rolls back; a completed exchange commits the original owner with the new source binding. Wrong roots, malformed journals and unexpected directories remain unavailable with the journal retained. Cleanup is registered before clearing the transaction, uses exact native receipts outside the lock, and preserves substituted directories. The cleanup queue is bounded at 128 entries, maintenance processes eight entries per call, and preparation refuses 32 outstanding native stages. Interrupted/unknown stages are preserved rather than guessed safe to delete. Preparation-failure cleanup also checks the original root and stage receipt.

The native Gallery installer uses this path after its normal host, byte count, hash and manifest checks. If post-install cache rebuilding fails, it reports that the source was installed and the cache needs retry; it does not roll back an already committed identity. The native provenance allows a retry even if saving the separate installation-list file failed. This work does not by itself enable startup migration, signed iCloud acceptance or WidgetKit/AppIntents cross-process delivery.


### Serializable direct widget actions

Direct `onClick` intents now expose four App Intents parameters: function name, package name, widget configuration parameter and execution-scope metadata. They do not store a Swift package/context/snapshot object in the intent. The scope contains the original name, owner UUID, source/cache role, native location hash and directory receipt; it is a selector that must match the receiving host's native registry, not a storage grant or filesystem path.

The receiver validates exact scope fields, canonical names, UUID/location/receipt types, the function identifier, a 4096-byte scope limit and a 16 KiB configuration-parameter limit. It chooses the native library or its separately configured whole-cache root, verifies the current binding and captures a fresh coherent package before executing the function with the widget parameter. It cannot select arbitrary paths from intent data, follow a same-name reinstall or fall back from a scoped request into legacy name-based storage. Legacy requests are accepted only by a non-migrated native manager and resolve their package inside that manager's library.

Unbound readonly previews and unsaved-entry previews display ordinary disabled controls and do not dispatch installed script functions. This prevents an unsaved function preview from unexpectedly running the older entry still on disk. Installed widgets retain their intent controls. Screenshot QA for UIKit-backed controls uses an actual hosted view hierarchy; ImageRenderer alone can omit switches or show unsupported placeholders.

AppIntentsTesting verifies all four parameters in the extracted native definitions. Isolated host tests round-trip the request, reopen the native context, execute real JavaScript, exercise a known whole-cache scope and reject retired/forged/wrong-root/unscoped requests. Actual WidgetKit/system dispatch across processes, signed shared-container access and physical-device clicks still need end-to-end acceptance. Startup migration remains disabled until the remaining consumers and lifecycle/UI work are ready.

### Native inventory and older-record review

`ScriptWidgetLibraryInventory` captures native directory receipts without creating an identity index or copying records. It rechecks the root, listing and receipts, rejects linked/unsupported entries, ignores ordinary metadata files, and treats iCloud or cloud placeholders as incomplete inventory. A missing folder is not treated as proof of deletion.

The shared older-record review service requires an already initialized native context and source bindings. It exposes only pending fields relevant to that library, plus unassigned fields. The app settings entry is shown only when that context is available; opening the review flow never bootstraps legacy preferences. The startup coordinator must first stop legacy writers, inventory/register sources and arrange the coordinated cutover before enabling this entry for an upgraded library.

Copying requires an explicit preview and selection. Under coordination, the implementation rechecks source/target fingerprints, candidate owner metadata, original source bindings and physical root/directory receipts before the first write. Users may choose more than one original candidate, producing independent copies. A changed owner, source, target, binding or library causes a new review to be required. The model clears stale selections after an error.

“Keep Original Without Copying” marks the reviewed field resolved without reading, copying or deleting its value or changing any target. It remains usable when a payload cannot be fingerprinted. A confirmation explains that no widget receives a copy. Originals remain stored. Preview text is bounded; opaque comparison fingerprints are SHA-256 digests rather than retained copies of every encoded source/target. Existing per-value and namespace limits still apply.

Tests use real isolated preferences for normal records and native metadata. Deliberately oversized/unreadable payloads use an in-memory preference provider: an earlier iOS fixture that persisted approximately 17 MiB returned a missing test index, and that run is preserved as a failure. These tests do not establish real CFPreferences capacity or persistence of oversized values. Capacity/performance measurements remain required before production cutover; the default startup migration is still disabled.


## File-backed native context (development; default startup still disabled)

The native UUID context now accepts a throwing `ScriptWidgetStorageBackend`. `ScriptWidgetFileStorageBackend` stores each owner's complete namespace in a separate private file and stores bounded identity/transaction/cache metadata separately. Original `script.*` preferences are a read-only migration source. It does not adopt a preference-domain UUID registry when a file registry is absent or corrupt; only the explicit native inventory/bootstrap may establish identities. The default shared manager still uses the legacy path pending coordinated startup and library-switch acceptance.

When this backend is injected, the existing runtime bridge, string/JSON CAS, native record manager, declared buttons/toggles, control-state reader, cache-context reconstruction and older-record review all use the same backend. Native namespace mutations stage changes and atomically replace a single owner file only after the callback succeeds. A false/throwing callback or invalid final state leaves the prior file unchanged. Public API names and stored template record formats remain the same. Missing keys keep their documented empty results; corrupt/unreadable record files raise a storage error on reads and cannot be overwritten by treating them as an empty namespace.

Records retain the 256-byte UTF-8 key, 256 KiB value, 1,024-key and 2 MiB owner bounds. Encoded frames additionally check owner identity, type, counts, lengths and trailing bytes. Legacy property-list values have depth/node/logical-size limits. Keys are byte-exact UTF-8, including different Unicode normalization forms, and never become path components. Descriptor-relative reads reject symlinks, multiply-linked files, FIFOs and directory-name aliases. Writes stage a private file, synchronize its content and atomically rename it; actual power-loss durability and signed-device data protection remain device acceptance work.

`node Scripts/test-storage-files.mjs` exercises the production file adapter and identity coordinator with four owners and 8 MiB of real records, verifies all values in a separate process, performs 400 paired counter updates across four processes, and checks whole-namespace state from a new process after abrupt exits before/after commit. The release-readiness gate includes this probe. iOS's opt-in file-capacity study exercises the same identity coordinator, CAS and budget checks, then reopens the backend in the same test process; it does not substitute for a system-launched widget extension.

The earlier CFPreferences capacity study failed on this iOS simulator after 16 verified 256 KiB values (4 MiB), while Mac verified 8 MiB through independent processes. This is an observed failure point, not a claimed universal OS threshold. The file-backed study verifies the same 8 MiB workload without putting native records or identity metadata into CFPreferences. Evidence is in `__Release/capabilities/storage-files/`; the original failing experiment remains in `__Release/capabilities/storage-capacity/`. Neither study proves physical-device, signed App Group, iCloud, widget-memory or default-cutover acceptance.


## Native library activation coordinator (development)

`ScriptWidgetStorageProfiles` now provides a native activation boundary above individual package identities. A library's canonical path and directory receipt select a private profile; another library with the same widget names receives separate record/identity files. Only the original profile may read the frozen older `script.*` migration source. Switching requires an explicit native `allowSwitch`; extension receivers can open an already-ready context but cannot bootstrap it.

Activation publishes a `preparing` state before inventory or migration work. It freezes the original native inventory in a per-profile journal, recovers existing installation/relocation/replacement transactions, and persists planned owner UUIDs before registering source bindings. Readers capture an activation ID: switching away permanently invalidates that context, even after returning to the same library. Source contexts, cloned cache contexts and reconstructed direct-action hosts use that guard. Once all source receipts and the final inventory match, the coordinator publishes `ready`.

A resumed adoption uses the journaled UUID when identity registration committed but the directory-binding write did not. A replaced, retired or newly discovered directory receives a fresh identity and cannot inherit old records merely by reusing a name. Original values remain available to native recovery; a second library does not automatically copy older preferences. Directory changes during an interrupted initial inventory are compared with the frozen receipts before reusing a migrated owner.

Private file stores now anchor their data-directory receipt in a separate bounded parent marker. Replacing/removing the store directory or losing its anchor cannot silently create an empty store and rebootstrap identities. A profile additionally records its scoped store receipt; unknown fields, malformed present metadata and substituted files are rejected. The record frame remains private implementation state, not an importable package contract.

The development worktree connects these coordinator APIs to ordinary iOS/macOS startup, global managers, extension snapshots, native record sheets and actions. Tests use disposable libraries, real JSC and reconstructed action hosts. Native library selection, legacy-writer gating, isolated previews, whole-package cache fallback and scoped compiled fallback are implemented. System-dispatched widget actions, signed App Group, physical-device performance and real iCloud acceptance still require evidence; this work is not published.

### Files restored after startup

While the native app is in the foreground, it checks the selected library every three seconds for restored directories that are not yet registered. Readable packages are adopted through the existing journaled coordinator, cached, and followed by a WidgetKit timeline reload. Partial downloads, malformed manifests, linked paths and unavailable storage are retried or rejected without deleting original files. Open native/Web Studio editors defer adoption until their leases close. Background restoration is checked when the app becomes active again; extensions never perform adoption themselves.

Existing directory receipts keep their owner UUID and records. A different directory with the same name receives a fresh UUID; earlier records remain preserved for native recovery and are never attached solely by name. Unchanged libraries do not rotate their activation. Manual library refresh remains available for explicit recovery.

## Legacy cutover fence and isolated preview records (development)

Legacy native consumers now use `ScriptWidgetLegacyStorageBackend`. The profile state lock covers each read and each complete mutation, including preference synchronization, and activation uses the same lock to publish `preparing`. A previously opened record sheet or legacy button cannot write after that publication. The callback inside a legacy transaction receives the underlying store while the fence is held; it does not reacquire the state lock. Bound UUID/file consumers continue to use their captured native context.

Unbound execution checks for a present private store before running or delivering asynchronous API results. A preparing/ready profile requires an execution identity; old callers receive a migration/identity error, and late private payloads are rejected. Before any store exists, ordinary non-storage legacy code retains its availability on unsigned hosts without an App Group. Record access is stricter: a declared shared root that is missing, inaccessible or inconsistent cannot authorize a read and does not become an empty record. Older compatibility paths with no container URL still retain their previous behavior; the live startup factories report unavailable storage rather than relying on that compatibility fallback.

An unbound `readonly` package now receives one in-memory record namespace per runtime. String/JSON writes and CAS can exercise preview behavior without reading preferences, creating App Group files, or mutating installed records. Fresh preview runs start fresh; package storage permissions, byte/key/value/namespace limits and timeline write restrictions still apply. Only this private memory backend can perform CAS without a filesystem lock. Native isolated preview storage is separate from Web Studio's existing editable Mock Data settings; it does not claim to simulate every native system API.

Read-only previews also cannot read, publish or remove installed widgets' global last-known-good compiled artifacts. Source-addressed transpilation caching remains available. UTF-8 byte slicing preserves leading combining marks in storage keys, including listing and round-tripping a key through the native file backend; character-based prefix removal must not drop part of a user's key.

A Debug-only Mac hosted-process probe verifies the actual production fence across process boundaries: an independent legacy writer stops during preparing, all completed paired values migrate consistently, and restarting a writer after ready produces zero writes. It accepts only a disposable UUID-named temp root and matching test preference domain, runs before the app UI, and is absent from Release builds. This does not establish system WidgetKit dispatch, signed App Group or physical-device acceptance. Default startup and library UI now use the coordinator. Uninstalled previews deny personal system-data queries, and installed snapshots use an owner/policy-scoped compiled cache. Physical-device cache performance and signed-container acceptance remain unverified.


## Choosing and refreshing a library

In iOS storage settings or macOS Data Access settings, choose **Choose Widget Library**. A selected library keeps its own widgets and records; choosing another library does not move or delete either library's files. Close native widget editors and stop Web Studio before switching or refreshing. If the selected storage goes offline, reconnect it and retry; the app does not silently open another library, and previously authorized complete widget caches can remain available.

Before opening an iCloud-backed library, each native host process establishes its own iCloud container access through Foundation. A path saved by the app does not itself authorize a widget extension to read that container. This initialization does not change the selected path, directory bindings, record owners, or cache fallback rules; local libraries do not require it. Real container access still requires signed-in, signed-device acceptance beyond the deterministic tests.

After adding widget directories through Files or iCloud Drive, use **Refresh Selected Library**. Refresh reconciles native directory identities, retains unchanged installations and records, and gives newly discovered directories independent identities. It invalidates old execution contexts and requests a widget refresh after cache preparation. Original legacy preference values remain preserved and are not automatically assigned to late-arriving directories.

Web Studio stays attached to the library selected when the server starts. Newly created names can appear during that session; an already-seen name retains its installation identity. After deleting/replacing an installation or changing libraries, stop and restart Web Studio to obtain a new session. Old browser drafts cannot overwrite the replacement installation.


## Countdown configuration

The bundled Countdown package adds a configuration-only `countdown` kind to Record Backup 1. Its sole managed key is `recordTemplate.config.v1`; the values are `title`, `targetDate`, `repeatYearly` and `accent`. The native configuration form saves through the same bound owner and conflict-checked transaction as record templates. It provides a Gregorian date picker and preserves configuration through backup/restore. Countdown has no daily history keys or fake record entries. Older app versions that do not recognize this kind reject its backup rather than interpreting it as another template.

Calendar-only dates count calendar days across daylight-saving changes. Yearly February 29 events wait for the next leap year. The existing `YYYY-MM-DD Event` and `YYYY-MM-DDTHH:mm:ss Event` parameters remain supported, with invalid dates and nonexistent local times reported explicitly. Per-instance parameters override saved defaults without writing them. The template README documents formatting and WidgetKit scheduling limits.


## Photo Card configuration and assets

The bundled Photo Card uses a configuration-only `photoCard` kind in Record Backup 1. Its sole record key is `recordTemplate.config.v1`, containing `title`, `caption`, `layout` (`single`, `duo`, `grid`) and an ordered `photos` list of up to four package-local `photo-<UUID>` names. It has no daily history. The native picker imports only the user-selected Photos item or file; no photo-library API is exposed to JavaScript and the package requests storage only.

Native import bounds source files to 25 MiB and source dimensions to 20,000 pixels per axis/100 million total pixels. ImageIO prepares an orientation-normalized thumbnail up to 1,536 pixels, then the crop is encoded as an independent PNG up to 768 × 768 pixels/3 MiB. GPS, capture time and original filenames/album identifiers are not copied. The PNG encoder may generate image dimensions and color-space metadata. There are up to 12 native photo assets per package; the form selects and orders up to four and allows explicit deletion of unreferenced imports. References in either the current draft or saved configuration protect an asset from that deletion. If saved configuration cannot be read, the form protects all existing photo assets until repaired.

Cropping/importing an asset does not write configuration. Save Configuration uses the same bound owner and conflict-checked record transaction as other templates. Per-instance JSON parameters can override presentation without changing saved defaults. A replacement installation cannot be read or written by an old photo editor/record sheet. Managed photo imports request a complete package cache refresh; previously completed cache snapshots can be used when source storage is unavailable.

Record backups contain settings and photo references only. Export the complete widget package separately to retain the actual photo files. Restoring a reference without its asset shows a missing-file state in configuration; the native image renderer uses its normal unavailable-image placeholder until the file is restored or replaced. Empty templates do not insert stock or personal-looking demo photos. Template thumbnails use original code-drawn example artwork.

This selected-file import feature is separate from M3 PhotoKit album queries, limited-library authorization and scheduled library-backed rotation; those capabilities are not implied by the native picker.


## Weather and health configuration backups

The `weather` kind manages only `recordTemplate.config.v1`: saved city label, latitude/longitude, location preference and temperature unit. Saved city coordinates are included in an explicit configuration backup; transient GPS/forecast cache (`weather.met.v1`) is not. City selection never grants location or network permissions. See each bundled weather README and the [HTTP response API](http-response-api.md).

The `healthCard` kind also manages only `recordTemplate.config.v1`, containing `metric`, `stepsGoal` and `energyGoal`. It has no daily history, HealthKit samples, query results or authorization state. All metrics use the same validated native configuration transaction and restore preview as other kinds. A backup cannot change the destination package's permissions or select an unrecognized metric. Older app versions reject unknown backup kinds; they do not reinterpret health settings as daily records. See [Health readings](health-api.md).


The `repoStats` kind backs up only saved `repository` and `accent` configuration. Its transient `github.stats.v1` cache and daily public-count history are excluded. It grants no network permission and cannot contain credentials; the built-in template declares only api.github.com. Unknown repositories, settings and accents fail validation. See [Public data cards](public-data-cards.md).

The `launcher` configuration-only kind saves title, accent and ordered link definitions (including explicitly supplied shortcut text). It has a 32 KiB configuration allowance; other kinds retain 4 KiB. Backups can contain personal link/input data. Neither restore nor URL validation opens a target app. See [Launchers and system actions](launcher-actions.md).

## Optional iCloud JSON

`$storage` remains local and is not migrated automatically. New packages can opt into the separate [iCloud JSON API](icloud-json-api.md) (Runtime 1.5), with explicit native user connection, cache-first reads and preserved conflicting revisions.
