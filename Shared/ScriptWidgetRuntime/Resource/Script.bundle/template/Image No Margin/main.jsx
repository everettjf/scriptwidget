//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
//
// Shows three pictures side by side, with no gap between them or around them.
// Try other pictures (image/image0.png to image2.png in this widget's folder) or words.

// spacing="0" removes the gap between the columns. frame="max" makes a view fill its space.
$render(
  <hstack frame="max" spacing="0" background="#111827">
    {/* One column: a picture with a word on top of it. */}
    <zstack frame="max">
      <image id="image0" mode="fill" frame="max" />
      <text font="headline" weight="bold" color="white">
        Explore
      </text>
    </zstack>
    <zstack frame="max">
      <image id="image1" mode="fill" frame="max" />
      <text font="headline" weight="bold" color="white">
        Create
      </text>
    </zstack>
    <zstack frame="max">
      <image id="image2" mode="fill" frame="max" />
      <text font="headline" weight="bold" color="white">
        Enjoy
      </text>
    </zstack>
  </hstack>,
);
