//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component Live Activity and Dynamic Island
// Live Activities run on iPhone and iPad. Android shows a Live Update notification and
// does not draw this layout. Mac, Windows and Linux have no Live Activities.
// Start one in the app under Settings > Live Activities.
//

// $render is also for lock screen live activity
$render(
  <vstack frame="max">
    <text>hello live activity</text>
  </vstack>,
);

// $dynamic_island is for dynamic island
// on iPhone 14 Pro/ProMax and iOS16.1+
$dynamic_island({
  expanded: {
    // expanded is required , at least one of the four child below is required
    leading: <text>leading</text>,
    trailing: <text>trailing</text>,
    center: <text>center</text>,
    bottom: <text>bottom</text>,
  },
  // The island in its small form has a left and a right side.
  compactLeading: <text>compactLeading</text>, // required
  compactTrailing: <text>compactTrailing</text>, // required
  // The smallest form, used when several activities share the island.
  minimal: <text>minimal</text>, // required
});
