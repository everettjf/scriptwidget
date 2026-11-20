# Connected Services API (Runtime 1.4)

<!-- platforms:start -->
> **Runs on:** iPhone and iPad, Mac, Android (With a fine-grained token, no OAuth sign-in), Linux (With a fine-grained token kept in the system keyring, no OAuth sign-in). **Not on:** Windows. Details and limits: [Platform support](platform-support.md).
<!-- platforms:end -->

`$services` reads a user-connected account through a fixed native request broker. The only supported provider is `github`. Account connection and per-widget approval live in ScriptWidget Settings > Service Accounts (iOS) or Settings > Services (Mac). Web Studio uses editable samples; it does not authenticate or contact the provider.

```json
{
  "permissions": ["services", "network"],
  "networkDomains": ["api.github.com"],
  "minimumRuntimeVersion": "1.4"
}
```

These are fields within a full Package 2.0 manifest. A real installed widget owner and the `services` permission are required for both methods. `profile` also requires the declared network permission/domain and an explicit native grant for that owner. A legacy or uninstalled template preview cannot access native accounts. Imports and reinstallation cannot select another widget's owner UUID or inherit its account grant.

```jsx
const status = await $services.status("github");
if (status === "connected") {
  const profile = await $services.profile("github");
  $render(<text>{`${profile.username}: ${profile.publicRepositories} repos`}</text>);
} else {
  $render(<text>Connect and allow this widget in Service Accounts.</text>);
}
```

`status(service)` makes no HTTP request. It resolves to `notConnected`, `notGranted`, `connected`, or `unavailable`. Connected means a local account and this owner's grant exist; it does not guarantee that the provider still accepts the token. A locked, corrupt or unavailable secure store rejects with a sanitized error rather than pretending that the account was disconnected. `unavailable` covers unsupported provider integration or missing native service configuration.

`profile("github")` performs a fixed authenticated `GET https://api.github.com/user`. The account is chosen in native Settings; a script cannot select an arbitrary account, URL, request header or token. The response has exactly these fields:

| Field | Type / meaning |
| --- | --- |
| `service` | `"github"` |
| `subject` | Provider user ID as a string |
| `username` | GitHub login, including managed-user suffixes |
| `displayName` | String or null |
| `publicRepositories` | Nonnegative integer |
| `privateRepositories` | Nonnegative integer or null when not shared |
| `followers`, `following` | Nonnegative integer or null |

A missing private count is not zero. The token's provider permissions determine which private fields are returned; the [GitHub authenticated-user endpoint](https://docs.github.com/en/rest/users/users#get-the-authenticated-user) supports fine-grained tokens with no additional permission for basic profile access. ScriptWidget omits email, location, arbitrary provider fields and response headers. Credentials stay in the dedicated native Keychain group, not in scripts, package exports, preferences, snapshots or AI prompts. No credentials should be pasted into Web mocks.


Each method consumes one of the execution's eight shared data queries. Profile requests also share ordinary native fetch limits (eight concurrent, 32 total), have bounded ephemeral HTTP transport, reject all redirects and limit streamed responses to 128 KiB. Web profiles share the preview's existing network budget. Requests recheck installed execution identity and private connection authority before sending and before delivery. Disconnecting, reconnecting or changing the owner's grant invalidates pending results. A provider response for a different user ID is rejected. No automatic retries, token refresh, profile persistence, arbitrary authenticated fetch or writes are exposed.

Future timeline entries and Live Activity/Dynamic Island presentations reject live service queries with `timeline_read_only`. Read in the current execution and reuse a display snapshot when composing those presentations. Do not embed tokens in Live Activity state.

Common failures include `service_permission`, `service_not_connected`, `service_expired`, `service_locked`, `service_credential`, `service_rate_limit`, `service_unavailable`, `query_limit`, and `network_limit`. Catch them and show setup/reconnect/retry states; never turn a failure into plausible zero counts.

Web Studio's Connected Services panel provides a healthy profile by default, editable fields/JSON, and scenarios for disconnection, missing widget access, zero counts, an unshared private count, expiry, rate limits and offline behavior. Response overrides cannot bypass manifest/network checks, a denied status, unsupported providers or query budgets. Mock profile objects accept only the documented fields. Mock data stays in the browser draft and is not exported with the package.

[GitHub Profile template](../Shared/ScriptWidgetRuntime/Resource/Script.bundle/template/GitHub%20Profile/main.jsx) uses these APIs with all eight widget families and explicit setup/error states. Real account authorization, signed app/widget Keychain sharing and physical-device delivery still need acceptance; deterministic tests and sample screenshots do not prove those checks.

GitHub.com managed-user logins may include an underscore and enterprise shortcode within the 39-character limit, as described in [GitHub username normalization](https://docs.github.com/en/enterprise-cloud%40latest/admin/managing-iam/iam-configuration-reference/username-considerations-for-external-authentication). Native and Web validation accept those names; arbitrary enterprise server hosts are not part of this API.

Native fixture captures: [sample profile](images/github-profile-sample.png), [setup state](images/github-profile-setup.png), and [Web Studio mock controls](images/github-profile-web-studio.png). These are sample accounts and actual rendering/UI, not a live provider authorization.

## Provider removal

The unshipped conditional Spotify integration has been removed at the user's request, including native authorization/configuration and browser fixtures. Only `status("github")` and `profile("github")` are supported. Unknown provider names reject with `service_operation` in native and Web execution; `$services.playback` is not present. Drafts using the removed integration must be edited to a supported data source; they do not silently receive GitHub samples. Package/compiler ABI stays 1.0 and Runtime API stays 1.4; no released Spotify compatibility is claimed.
