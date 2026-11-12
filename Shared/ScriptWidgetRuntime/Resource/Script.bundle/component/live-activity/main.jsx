// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for component Live Activity and Dynamic Island
// 


// $render is also for lock screen live activity
$render(
    <vstack frame="max">
        <text>hello live activity</text>
    </vstack>
);


// $dynamic_island is for dynamic island
// on iPhone 14 Pro/ProMax and iOS16.1+
$dynamic_island({
    expanded: { // expanded is required , at least one of the four child below is required
        leading: <text>leading</text>,
        trailing: <text>trailing</text>,
        center: <text>center</text>,
        bottom: <text>bottom</text>,
    },
    compactLeading: <text>compactLeading</text>, // required
    compactTrailing: <text>compactTrailing</text>, // required
    minimal: <text>minimal</text>, // required
});
