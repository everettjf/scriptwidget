//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Swing Sample
// type "swing" moves a view back and forth. $animation(...) turns the description
// object into a value for the animation prop. Try another duration or distance.
//

// distance: how far the view moves to each side of its place, in points.
// duration: seconds for one way and back to the middle; a full swing takes twice that.
let animationHorizontalDefinition = {
  type: "swing",
  duration: 2,
  direction: "horizontal", // "horizontal", "vertical"
  distance: 100,
};

let animationVerticalDefinition = {
  type: "swing",
  duration: 2,
  direction: "vertical", // "horizontal", "vertical"
  distance: 100,
};

// Each circle has its own animation: one moves sideways, one up and down.
$render(
  <vstack frame="max">
    <circle
      frame="30,30"
      color="green"
      animation={$animation(animationHorizontalDefinition)}
    ></circle>
    <circle
      frame="30,30"
      color="orange"
      animation={$animation(animationVerticalDefinition)}
    ></circle>
  </vstack>,
);
