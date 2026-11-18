// Loaded by main.jsx. An imported file may contain JSX. textItems is used there.

const values = ["one", "two", "three", "four"];

// One <text> element per value.
const textItems = values.map((value) => {
  return <text>{value}</text>;
});
