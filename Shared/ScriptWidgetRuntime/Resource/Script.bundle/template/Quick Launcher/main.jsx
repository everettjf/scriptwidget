// Quick Launcher — replace the URLs with your own favorites.

$render(
  <vstack frame="max" background="#111827" spacing="12" padding="14">
    <hstack frame="max">
      <text font="headline" color="#f9fafb">Quick Launch</text>
      <spacer />
      <text font="caption2" color="#6b7280">Tap to open</text>
    </hstack>
    <hstack frame="max" spacing="10">
      <link url="https://calendar.google.com" background="#1d4ed8">
        <vstack padding="10"><icon systemName="calendar" size="24" color="#ffffff" /><text font="caption" color="#ffffff">Calendar</text></vstack>
      </link>
      <link url="https://github.com" background="#374151">
        <vstack padding="10"><icon systemName="chevron.left.forwardslash.chevron.right" size="24" color="#ffffff" /><text font="caption" color="#ffffff">GitHub</text></vstack>
      </link>
      <link url="https://www.google.com" background="#047857">
        <vstack padding="10"><icon systemName="magnifyingglass" size="24" color="#ffffff" /><text font="caption" color="#ffffff">Search</text></vstack>
      </link>
    </hstack>
  </vstack>
);
