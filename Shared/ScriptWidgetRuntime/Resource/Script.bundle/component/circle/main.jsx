//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component circle
// Four circles: filled, as a ring, as a part of a ring, and that part turned.
//

$render(
  <hstack frame="max">
    <circle frame="40,40" color="blue"></circle>
    {/* stroke draws only the outline, with this line width. */}
    <circle frame="40,40" color="blue" stroke="10"></circle>
    {/* trim leaves out the start of the outline: 0.2 is the first 20%. */}
    <circle frame="40,40" color="blue" stroke="10" trim="0.2"></circle>
    {/* rotation turns the view, in degrees. */}
    <circle frame="40,40" color="blue" stroke="10" trim="0.2" rotation="90"></circle>
  </hstack>,
);
