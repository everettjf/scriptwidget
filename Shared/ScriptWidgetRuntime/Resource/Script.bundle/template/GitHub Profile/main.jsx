// Real authenticated profile. Connect GitHub in Settings > Service Accounts,
// then allow this installed widget. Web Studio supplies editable samples only.
// Shows your GitHub name and repository counts. Try changing the colors, or which
// numbers the layouts show.
// $services runs on iPhone, iPad and Mac, and on Android with a fine-grained token (no
// OAuth sign-in); not on Windows or Linux. widget.json must declare the permissions
// "services" and "network", and the host api.github.com.

// $getenv("widget-size") is the size being drawn: "small", "medium", "large",
// "extraLarge", or a Lock Screen size whose name starts with "accessory".
const family = $getenv("widget-size"),
  accessory = family.startsWith("accessory");
// $device.isdarkmode() is true when the system uses the dark appearance.
const dark = $device.isdarkmode(),
  compact = family === "small";
// Lock Screen sizes get a clear background and the system's own text colors.
const background = accessory ? "clear" : dark ? "#192822" : "#f1f8f3";
const primary = accessory ? "primary" : dark ? "#e7f5eb" : "#224432";
const secondary = accessory ? "secondary" : dark ? "#a4bead" : "#60776a";
// Read the data. When there is no profile, `state` says why.
let profile = null,
  state = "notConnected";
try {
  // status() only looks at the connection saved on this device; profile() asks GitHub.
  state = await $services.status("github");
  if (state === "connected") profile = await $services.profile("github");
} catch (error) {
  // A failed call throws an error whose text contains a code such as service_rate_limit.
  const message = String(error);
  state = message.includes("service_rate_limit")
    ? "rateLimited"
    : message.includes("service_expired") || message.includes("service_credential")
      ? "expired"
      : message.includes("service_permission")
        ? "notGranted"
        : message.includes("service_not_connected")
          ? "notConnected"
          : "offline";
}
// What to show for each state: [title, explanation].
const messages = {
  notConnected: ["Connect GitHub", "Open Service Accounts in ScriptWidget Settings."],
  notGranted: ["Allow this widget", "Choose this widget in Service Accounts."],
  unavailable: ["Account unavailable", "Review Service Accounts in ScriptWidget."],
  expired: ["Reconnect GitHub", "Update your token in Service Accounts."],
  rateLimited: ["Try again later", "GitHub is rate limiting requests."],
  offline: ["Unable to refresh", "Try again when your connection is available."],
};
const notice = messages[state] || messages.offline;
// A count that GitHub did not share is null; show a dash for it.
const number = (value) => (value === null ? "—" : String(value));
// A reusable piece of layout, used below as <Metric … />: a number with a label under it.
const Metric = ({ label, value }) => (
  <vstack alignment="leading" spacing="2">
    <text font="title2" fontWeight="semibold" color={primary}>
      {number(value)}
    </text>
    <text font="caption2" color={secondary}>
      {label}
    </text>
  </vstack>
);
// No profile: show the notice in a form that fits the size.
if (!profile) {
  if (family === "accessoryInline") $render(<text>{notice[0]}</text>);
  else if (family === "accessoryCircular")
    $render(
      <vstack spacing="1">
        <image systemName="person.crop.circle" />
        <text font="caption2">
          {state === "notConnected"
            ? "Setup"
            : state === "notGranted"
              ? "Allow"
              : state === "expired"
                ? "Login"
                : state === "rateLimited"
                  ? "Later"
                  : "Retry"}
        </text>
      </vstack>,
    );
  else
    $render(
      <vstack
        frame="max"
        alignment="leading"
        spacing="6"
        padding={accessory ? "0" : "16"}
        background={background}
      >
        <text font="headline" color={primary}>
          {notice[0]}
        </text>
        <text font={accessory ? "caption2" : "caption"} color={secondary}>
          {notice[1]}
        </text>
      </vstack>,
    );
} else if (family === "accessoryInline") {
  // Lock Screen, inline: one line of text.
  $render(<text>{`@${profile.username} · ${profile.publicRepositories} repos`}</text>);
} else if (family === "accessoryCircular") {
  // Lock Screen, circular: only the number of public repositories.
  $render(
    <vstack spacing="1">
      <text font="headline">{number(profile.publicRepositories)}</text>
      <text font="caption2">repos</text>
    </vstack>,
  );
} else if (family === "accessoryRectangular") {
  // Lock Screen, rectangular: two short lines.
  $render(
    <vstack alignment="leading" spacing="2">
      <text font="headline">{`@${profile.username}`}</text>
      <text font="caption2">{`${profile.publicRepositories} repos · ${number(profile.followers)} followers`}</text>
    </vstack>,
  );
} else {
  // Home Screen sizes. The small widget (`compact`) leaves out the third number and the
  // last line. frame="max" fills the widget; padding is the space in points around the content.
  $render(
    <vstack
      frame="max"
      alignment="leading"
      spacing={compact || family === "medium" ? "8" : "14"}
      padding="16"
      background={background}
    >
      <hstack spacing="8">
        <image systemName="chevron.left.forwardslash.chevron.right" font="title2" />
        <vstack alignment="leading" spacing="1">
          <text font="headline" color={primary}>
            {profile.displayName || profile.username}
          </text>
          <text font="caption" color={secondary}>{`@${profile.username}`}</text>
        </vstack>
      </hstack>
      <spacer />
      <hstack alignment="top" spacing={compact ? "8" : "32"}>
        <Metric label="Public repos" value={profile.publicRepositories} />
        <Metric label="Followers" value={profile.followers} />
        {!compact && <Metric label="Following" value={profile.following} />}
      </hstack>
      {!compact && (
        <text font="caption2" color={secondary}>
          {profile.privateRepositories === null
            ? "Private repository count not shared"
            : `${profile.privateRepositories} private repositories`}
        </text>
      )}
      {family !== "medium" && !compact && <spacer />}
    </vstack>,
  );
}
