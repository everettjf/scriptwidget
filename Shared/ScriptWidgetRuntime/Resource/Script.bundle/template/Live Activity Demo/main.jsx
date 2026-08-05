// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 
// Usage for component Live Activity and Dynamic Island
// 


// $render is also for lock screen live activity
$render(
  <hstack frame="max" spacing="12" padding="14" background="#1c1917">
    <zstack frame="48,48"><circle frame="48,48" color="#7c2d12"/><icon systemName="figure.run" size="24" color="#fb923c"/></zstack>
    <vstack alignment="leading" spacing="3"><text font="caption" color="#fdba74">LIVE ACTIVITY</text><text font="headline" weight="bold" color="white">Morning Run</text><text font="caption" color="#d6d3d1">12:48 · 2.4 km</text></vstack>
    <spacer/><badge text="LIVE" color="#fb923c"/>
  </hstack>
);


// $dynamic_island is for dynamic island
// on iPhone 14 Pro/ProMax and iOS16.1+
$dynamic_island({
    expanded: { // expanded is required , at least one of the four child below is required
        leading: <icon systemName="figure.run" color="#fb923c" />,
        trailing: <text color="white">2.4 km</text>,
        center: <text color="white">Morning Run</text>,
        bottom: <text color="#d6d3d1">12:48 elapsed</text>,
    },
    compactLeading: <icon systemName="figure.run" color="#fb923c" />,
    compactTrailing: <text color="white">2.4</text>,
    minimal: <icon systemName="figure.run" color="#fb923c" />,
});
