//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component date
// <date> shows a date, or a running time that the system keeps up to date by itself.
// Try style="relative" or style="offset", or date="tomorrow".
//

$render(
  <vstack>
    {/* style="time" shows the time of day; style="date" shows the calendar date. */}
    <date font="caption" date="now" style="time" />
    <date font="caption" date="now" style="date" />
    {/* style="timer" counts the time since the date: here since midnight. */}
    <date font="caption" date="start of today" style="timer" />
    {/* date also takes a time in milliseconds, which is what Date.now() returns. */}
    <date font="title" date={Date.now()} style="timer" />
  </vstack>,
);
