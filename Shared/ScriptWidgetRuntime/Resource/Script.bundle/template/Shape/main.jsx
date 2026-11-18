//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Shape Template
//
// Description: Shape Example
//
// Shows how to build a picture from shapes: a <zstack> lays its children on top of each
// other. Try changing the frames, colors and corner radii.
//

// $getenv("widget-size") is the size being drawn: "small", "medium", "large", …
if ($getenv("widget-size") === "small") {
  // Small: the shapes alone.
  // frame="max" fills the widget; padding is the space around the content, in points.
  $render(
    <vstack frame="max" spacing="8" padding="14" background="#1e1b4b">
      {/* animation="clockCustom,20" asks for a slow rotation: half a turn every 20 seconds. */}
      {/* The system decides whether a widget really moves; otherwise the shapes stand still. */}
      <zstack frame="100,100" animation="clockCustom,20">
        {/* frame is "width,height" in points; radius rounds the corners. */}
        <roundedrect frame="86,86" color="#7c3aed" radius="22" />
        <circle frame="58,58" color="#c4b5fd" />
        <roundedrect frame="28,28" color="#f8fafc" radius="8" />
      </zstack>
      <text font="caption" color="#c4b5fd">
        SHAPES
      </text>
    </vstack>,
  );
} else {
  // Medium and larger: the same shapes beside a column of text.
  $render(
    <hstack frame="max" spacing="18" padding="14" background="#1e1b4b">
      <zstack frame="100,100" animation="clockCustom,20">
        <roundedrect frame="86,86" color="#7c3aed" radius="22" />
        <circle frame="58,58" color="#c4b5fd" />
        <roundedrect frame="28,28" color="#f8fafc" radius="8" />
      </zstack>
      <vstack alignment="leading" spacing="4">
        <text font="caption" color="#c4b5fd">
          SHAPES
        </text>
        <text font="title2" weight="bold" color="white">
          Build with primitives
        </text>
        <text font="caption" color="#ddd6fe">
          Compose, color, rotate.
        </text>
      </vstack>
    </hstack>,
  );
}
