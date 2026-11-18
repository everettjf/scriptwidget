//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component text
// Text with a font, a color and a background. Try other fonts, such as "headline".
//

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max">
    <text font="title">Hello ScriptWidget</text>
    <text font="caption" color="red">
      Hello ScriptWidget
    </text>
    <text font="caption" background="blue" color="white">
      Hello ScriptWidget
    </text>
  </vstack>,
);
