//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// Health Steps Ring
// Requires read-only HealthKit permission in the main app.
//

const goal = 8000;

if (!$health.isAvailable()) {
  $render(
    <hstack frame="max" background="#422006" padding="14" spacing="14">
      <icon systemName="figure.walk.circle.fill" size="48" color="#fbbf24"/>
      <vstack alignment="leading" spacing="4"><text font="caption" color="#fcd34d">STEPS TODAY</text><text font="title2" weight="bold" color="white">Health on iPhone</text><text font="caption" color="#fde68a">Add this widget on iOS to see your ring.</text></vstack>
    </hstack>
  );
} else {
  const granted = await $health.requestAuthorization();
  if (!granted) {
    $render(
      <hstack frame="max" background="#422006" padding="14" spacing="14"><icon systemName="heart.text.square.fill" size="46" color="#fbbf24"/><vstack alignment="leading" spacing="4"><text font="caption" color="#fcd34d">HEALTH ACCESS</text><text font="title2" weight="bold" color="white">Connect your steps</text><text font="caption" color="#fde68a">Allow read access in ScriptWidget.</text></vstack></hstack>
    );
  } else {
    const steps = await $health.stepCountToday();
    const value = steps.value || 0;
    const progress = Math.min(1, value / goal);

    $render(
      <vstack frame="max" background="#0f172a">
        <text font="caption" color="#94a3b8">Steps Today</text>
        <gauge
          angle="260"
          value={progress}
          thickness="10"
          label={value.toFixed(0)}
          labelFont="title3"
          title={`Goal ${goal}`}
          titleFont="caption"
        />
        <text font="caption2" color="#94a3b8">{(progress * 100).toFixed(0)}% of goal</text>
      </vstack>
    );
  }
}
