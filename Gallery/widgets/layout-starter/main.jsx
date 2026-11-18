// Open Layout in the editor to select, edit, add and move these layers.
// Code remains the source of truth. This template needs no permissions.
// A plain card: an icon and a short line at the top, two lines of text at the bottom.
// Try changing the texts and the colors.

// $render draws the widget. frame="max" fills the whole widget, alignment="leading"
// lines the children up on the left, and padding is the space in points around them.
$render(
  <vstack frame="max" alignment="leading" spacing="8" padding="16" background="#f1f6fb">
    {/* <hstack> places its children side by side, <vstack> one below the other. */}
    <hstack spacing="6">
      <icon systemName="sparkles" size="18" color="#526f9e" />
      <text font="caption" color="#657b96">
        A fresh start
      </text>
    </hstack>
    {/* <spacer /> takes all free space, which pushes the two texts to the bottom. */}
    <spacer />
    <text font="headline" fontWeight="semibold" color="#263e60">
      Make today yours
    </text>
    <text font="caption" color="#657b96">
      A little space for your ideas.
    </text>
  </vstack>,
);
