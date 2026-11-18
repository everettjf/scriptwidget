// Real authenticated profile. Connect GitHub in Settings > Service Accounts,
// then allow this installed widget. Web Studio supplies editable samples only.
const family = $getenv("widget-size"),
  accessory = family.startsWith("accessory");
const dark = $device.isdarkmode(),
  compact = family === "small";
const background = accessory ? "clear" : dark ? "#192822" : "#f1f8f3";
const primary = accessory ? "primary" : dark ? "#e7f5eb" : "#224432";
const secondary = accessory ? "secondary" : dark ? "#a4bead" : "#60776a";
let profile = null,
  state = "notConnected";
try {
  state = await $services.status("github");
  if (state === "connected") profile = await $services.profile("github");
} catch (error) {
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
const messages = {
  notConnected: ["Connect GitHub", "Open Service Accounts in ScriptWidget Settings."],
  notGranted: ["Allow this widget", "Choose this widget in Service Accounts."],
  unavailable: ["Account unavailable", "Review Service Accounts in ScriptWidget."],
  expired: ["Reconnect GitHub", "Update your token in Service Accounts."],
  rateLimited: ["Try again later", "GitHub is rate limiting requests."],
  offline: ["Unable to refresh", "Try again when your connection is available."],
};
const notice = messages[state] || messages.offline;
const number = (value) => (value === null ? "—" : String(value));
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
  $render(<text>{`@${profile.username} · ${profile.publicRepositories} repos`}</text>);
} else if (family === "accessoryCircular") {
  $render(
    <vstack spacing="1">
      <text font="headline">{number(profile.publicRepositories)}</text>
      <text font="caption2">repos</text>
    </vstack>,
  );
} else if (family === "accessoryRectangular") {
  $render(
    <vstack alignment="leading" spacing="2">
      <text font="headline">{`@${profile.username}`}</text>
      <text font="caption2">{`${profile.publicRepositories} repos · ${number(profile.followers)} followers`}</text>
    </vstack>,
  );
} else {
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
