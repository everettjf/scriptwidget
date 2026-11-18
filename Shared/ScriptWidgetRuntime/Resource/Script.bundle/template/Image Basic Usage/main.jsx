//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component image
//
// Shows a picture that fills the widget, with a label on top of it.
// The list below shows other ways to write <image>; copy one into $render to try it.

/*

    <image />
    <image systemName="mosaic.fill" />
    <image id="image0" />
    
    <image id="image" mode="fit" ratio="0.6" />
    <image id="image" mode="fill" frame="260,60" />

    <image id="image" mode="fill" clip frame="200,100"/>
    
    <image id="image" mode="fill" clip="rect" frame="200,100"/>
    <image id="image" mode="fill" clip="ellipse" frame="200,100"/>
    <image id="image" mode="fill" clip="circle" frame="200,100"/>
    <image id="image" mode="fill" clip="capsule" frame="200,100"/>

    <image id="image" mode="fill" corner="30" frame="200,100"/>
*/

$render(
  // <zstack> puts its children on top of each other: first the picture, then the text.
  <zstack frame="max" background="#0f172a">
    {/* mode="fill" scales the picture until it covers its frame; "fit" shows all of it instead. */}
    <image id="image" mode="fill" frame="max" />
    {/* frame="max,bottomLeading" fills the widget and keeps the content at the bottom left. */}
    <vstack frame="max,bottomLeading" alignment="leading" padding="14">
      <spacer />
      <badge text="LOCAL IMAGE" color="white" />
      <text font="title2" weight="bold" color="white">
        Photo spotlight
      </text>
    </vstack>
  </zstack>,
);
