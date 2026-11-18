//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component attribute frame
// frame sets the size of a view in points, as "width,height". "max" stands for all the
// room there is. Try the forms listed below on the two rectangles.
//

/*

 frame="max"
 frame="max,topLeading"
 frame="10,20"
 frame="10,20,topLeading"
 
 frame="max,20"
 frame="10,max"
 frame="max,20,topLeading"
 frame="10,max,topLeading"


 the "topLeading" represent alignment, could be one of the values below:
    "center"
    "leading"
    "trailing"
    "top"
    "bottom"
    "topLeading"
    "topTrailing"
    "bottomLeading"
    "bottomTrailing"
*/
// The stack fills the widget. Each rectangle is 50 points wide and 30 high.
$render(
  <vstack frame="max">
    <rect frame="50,30" color="green"></rect>
    <rect frame="50,30" color="blue" corner="5"></rect>
  </vstack>,
);
