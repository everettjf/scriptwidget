//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// Habit Streak Tracker (uses $storage)
//

const today = new Date();
const todayKey = today.toISOString().slice(0, 10);
const lastDate = $storage.getString("habit.lastDate");
let streakValue = parseInt($storage.getString("habit.streak") || "0", 10);

if (lastDate !== todayKey) {
  if (lastDate) {
    const lastTime = new Date(lastDate + "T00:00:00Z").getTime();
    const diffDays = Math.floor((today.getTime() - lastTime) / (24 * 60 * 60 * 1000));
    if (diffDays === 1) {
      streakValue += 1;
    } else {
      streakValue = 1;
    }
  } else {
    streakValue = 1;
  }
  $storage.setString("habit.lastDate", todayKey);
  $storage.setString("habit.streak", String(streakValue));
}

$render(
  <vstack frame="max" background="#be123c">
    <text font="caption" color="#fecdd3">Habit Streak</text>
    <text font="title2" color="white">{streakValue} days</text>
    <text font="caption2" color="#ffe4e6">Last update: {todayKey}</text>
  </vstack>
);
