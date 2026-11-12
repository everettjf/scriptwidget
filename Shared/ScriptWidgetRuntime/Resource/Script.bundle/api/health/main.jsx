//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api health
// Note: HealthKit requires main app permission and capability.
// This API reads health data only (no write).
//

if (!$health.isAvailable()) {
  $render(
    <vstack frame="max" background="#0f172a">
      <text font="title3" color="#f87171">HealthKit Unavailable</text>
      <text font="caption" color="#94a3b8">This platform does not support HealthKit.</text>
    </vstack>
  );
} else {
  const granted = await $health.requestAuthorization();

  if (!granted) {
    $render(
      <vstack frame="max" background="#0f172a">
        <text font="title3" color="#fbbf24">Permission Needed</text>
        <text font="caption" color="#94a3b8">Enable Health access in the main app.</text>
      </vstack>
    );
  } else {
    const steps = await $health.stepCountToday();
    const energy = await $health.activeEnergyToday();
    const heart = await $health.heartRateLatest();

    $render(
      <vstack frame="max" background="#0f172a">
        <text font="caption" color="#94a3b8">Health Today</text>
        <text font="title3" color="#e2e8f0">Steps: {steps.value.toFixed(0)}</text>
        <text font="caption" color="#94a3b8">Active Energy: {energy.value.toFixed(0)} kcal</text>
        <text font="caption" color="#94a3b8">Latest HR: {heart.value.toFixed(0)} bpm</text>
      </vstack>
    );
  }
}
