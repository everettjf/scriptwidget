// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for component link
// 

$render(
  <vstack frame="max" linkurl="https://atomsprout.com/scriptwidget">
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
  </vstack>
);

