// Animation Golden Bloom
// A flower whose petals are each turned by the golden angle, in two rings that rotate in
// opposite directions. Try changing the number of petals or the colors.
//
// The golden angle in degrees. Turning each petal by it spreads the petals around the
// circle without two of them landing on the same spot.
const goldenAngle = 137.507764;
// The numbers 0 to 12 and 0 to 7: one for each petal and each seed.
const petals = Array.from({ length: 13 }, (_, index) => index);
const seeds = Array.from({ length: 8 }, (_, index) => index);

// One petal: an ellipse at the top of a tall box with nothing else in it. Rotating the box
// around its center carries the ellipse around the middle of the flower. `rotation` is in
// degrees.
const petal = (index) => (
  <vstack frame="34,118" rotation={index * goldenAngle}>
    <ellipse frame="15,38" color={index % 2 === 0 ? "#f9a8d4" : "#c4b5fd"} />
    <spacer />
  </vstack>
);

// A seed is built the same way with a shorter box, so it sits closer to the middle.
const seed = (index) => (
  <vstack frame="16,64" rotation={index * goldenAngle}>
    <circle frame="7,7" color="#fde68a" />
    <spacer />
  </vstack>
);

// Fermat phyllotaxis: consecutive elements differ by the golden angle.
// animation="clockCustom,34" turns a stack half a turn every 34 seconds; a negative
// number turns it the other way.
$render(
  <zstack frame="max" background="#1b1026">
    <zstack frame="126,126" animation="clockCustom,34">
      {petals.map(petal)}
    </zstack>
    <zstack frame="76,76" animation="clockCustom,-21">
      {seeds.map(seed)}
    </zstack>
    {/* The center of the flower. */}
    <circle frame="28,28" color="#fbbf24" />
    <circle frame="12,12" color="#fff7ed" />
    {/* The labels: a full-size stack over the picture, with a <spacer /> between the texts. */}
    <vstack frame="max" alignment="leading" padding="12">
      <text font="caption" weight="bold" color="#fce7f3">
        GOLDEN BLOOM
      </text>
      <spacer />
      <text font="caption2" color="#f9a8d4">
        φ · 137.507764°
      </text>
    </vstack>
  </zstack>,
);
