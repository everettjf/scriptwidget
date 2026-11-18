//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component link
// Tapping a link opens its url. Try your own URLs.
// linkurl on a view, here the outer stack, is the URL for a tap on that view.
//

$render(
  <vstack frame="max" linkurl="https://atomsprout.com/scriptwidget">
    {/* The children of a link are what the user sees and taps. */}
    <link url="https://www.baidu.com" background="blue">
      <text font="title">Hello Baidu</text>
    </link>
    <link url="https://www.google.com" background="green">
      <hstack>
        <text>Hello</text>
        <text>Google</text>
      </hstack>
    </link>
    <link url="https://www.bing.com" background="yellow">
      <vstack>
        <text>Hello</text>
        <text>Bing</text>
      </vstack>
    </link>
  </vstack>,
);
