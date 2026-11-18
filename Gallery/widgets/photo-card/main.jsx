// Import, crop, select and order photos in Records & Configuration, then save.
// Assets stay inside the package. Export the package to back up photo files;
// a record backup contains the settings only. No album or network access.
if (!$import("lib/configuration.js"))
  throw new Error("Install the complete Photo Card template, including lib/configuration.js.");
const options = photoCardConfiguration.read(
  $storage.getString("recordTemplate.config.v1"),
  $getenv("widget-param"),
);
const size = $getenv("widget-size");
const limit = options.layout === "grid" ? 4 : options.layout === "duo" ? 2 : 1;
const photos = options.photos.slice(0, limit);
function Photo({ name, height }) {
  return <image name={name} mode="fit" ratio={1} frame={"max," + height} />;
}
if (size === "accessoryInline") {
  $render(<text>{photos.length ? options.title : "Choose photos in ScriptWidget"}</text>);
} else if (size === "accessoryCircular") {
  $render(
    photos.length ? (
      <image name={photos[0]} mode="fit" ratio={1} frame="52,52" />
    ) : (
      <icon systemName="photo" size="28" />
    ),
  );
} else if (size === "accessoryRectangular") {
  $render(
    <hstack spacing="8">
      {photos.length ? (
        <image name={photos[0]} mode="fit" ratio={1} frame="48,48" />
      ) : (
        <icon systemName="photo" size="28" />
      )}
      <vstack alignment="leading" spacing="3">
        <text font="headline">{options.title}</text>
        <text font="caption2">
          {photos.length ? options.caption : "Choose your photos in the app"}
        </text>
      </vstack>
    </hstack>,
  );
} else if (!photos.length) {
  $render(
    <vstack frame="max" padding="14" spacing="8" background="#f5f5f4">
      <icon systemName="photo.on.rectangle.angled" size="28" color="#57534e" />
      <text font="headline" color="#292524">
        Add your photos
      </text>
      <text font="caption2" color="#57534e">
        Open Records &amp; Configuration
      </text>
    </vstack>,
  );
} else if (size === "small") {
  $render(
    <vstack frame="max" padding="10" spacing="5" background="#fafaf9">
      <Photo name={photos[0]} height="102" />
      <text font="caption" weight="semibold" color="#292524">
        {Array.from(options.title).slice(0, 16).join("")}
      </text>
    </vstack>,
  );
} else if (size === "medium") {
  $render(
    <vstack frame="max" padding="12" spacing="7" background="#fafaf9">
      <hstack spacing="6">
        {photos.map((name) => (
          <Photo name={name} height="88" />
        ))}
      </hstack>
      <hstack frame="max">
        <text font="caption" weight="semibold" color="#292524">
          {options.title}
        </text>
        <spacer />
        <text font="caption2" color="#78716c">
          {photos.length + (photos.length === 1 ? " photo" : " photos")}
        </text>
      </hstack>
    </vstack>,
  );
} else {
  const rows = photos.length > 2 ? [photos.slice(0, 2), photos.slice(2)] : [photos];
  $render(
    <vstack frame="max" padding="14" spacing="8" background="#fafaf9">
      <text font="headline" weight="semibold" color="#292524">
        {options.title}
      </text>
      {rows.map((row) => (
        <hstack spacing="8">
          {row.map((name) => (
            <Photo name={name} height={rows.length > 1 ? "120" : "240"} />
          ))}
        </hstack>
      ))}
      {options.caption ? (
        <text font="caption" color="#57534e">
          {options.caption}
        </text>
      ) : null}
    </vstack>,
  );
}
