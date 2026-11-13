# ScriptWidget Runtime API

> Generated from Studio's static API metadata (schema v1, runtime 1.6). The native runtime switch is authoritative. Do not edit by hand.

## Components

### `<VStack>`

Arrange children vertically.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `spacing` | `number` | No |  |

### `<HStack>`

Arrange children horizontally.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `spacing` | `number` | No |  |

### `<ZStack>`

Overlay children.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |

### `<VGrid>`

Vertical lazy grid.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Values: `leading`, `center`, `trailing` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `columns` | `string` | Yes |  |
| `spacing` | `number` | No |  |

### `<HGrid>`

Horizontal lazy grid.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Values: `top`, `center`, `bottom`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `columns` | `string` | Yes |  |
| `spacing` | `number` | No |  |

### `<Text>`

Display text content.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `text` | `string` | No |  |

### `<Date>`

Display a formatted date.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `date` | `date|number` | Yes |  |
| `style` | `enum` | No | Values: `time`, `date`, `relative`, `offset`, `timer` |

### `<Image>`

Display a bundled, remote, or SF Symbol image.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `systemName` | `string` | No |  |
| `name` | `string` | No |  |
| `id` | `string` | No | Deprecated: Use name. |
| `url` | `url` | No |  |
| `src` | `url` | No | Deprecated: Use url. |
| `ratio` | `number` | No |  |
| `mode` | `enum` | No | Values: `fit`, `fill` |
| `accentedRenderingMode` | `enum` | No | Control how the image is rendered in tinted and clear widget appearances. Values: `accented`, `desaturated`, `accentedDesaturated`, `fullColor` |

### `<Gif>`

Display a bounded package GIF using system decoding: up to 8 MiB input and 1,048,576 canvas pixels. iOS retains at most 60 downsampled frames / 4 MiB decoded pixels; more frames fall back to the first frame. Mac, Reduce Motion and reduced luminance use a static first frame. Active iOS previews use public SwiftUI timing with variable frame delays. Snapshots, inactive scenes, Mac and accessibility fallbacks use the first frame. No private clock bridge or continuous WidgetKit guarantee.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `file` | `string` | Yes |  |

### `<Spacer>`

Flexible layout space.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `minLength` | `number` | No |  |

### `<Rect>`

Rectangle shape.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `trim` | `number|string` | No |  |
| `stroke` | `string` | No |  |

### `<RoundedRect>`

Filled rounded rectangle.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `radius` | `number` | No |  |

### `<Capsule>`

Capsule shape.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `trim` | `number|string` | No |  |
| `stroke` | `string` | No |  |

### `<Ellipse>`

Ellipse shape.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `trim` | `number|string` | No |  |
| `stroke` | `string` | No |  |

### `<Circle>`

Circle shape.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `trim` | `number|string` | No |  |
| `stroke` | `string` | No |  |

### `<Gauge>`

Display a gauge or instrument.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `type` | `string` | No |  |
| `value` | `number` | No |  |
| `style` | `enum` | No | Values: `circular`, `linear` |
| `text` | `string` | No |  |
| `current` | `string` | No |  |
| `min` | `string` | No |  |
| `max` | `string` | No |  |
| `angle` | `number` | No |  |
| `thickness` | `number` | No |  |
| `needleColor` | `color` | No |  |
| `label` | `string` | No |  |
| `title` | `string` | No |  |
| `sections` | `string` | No |  |

### `<Chart>`

Render chart data.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `type` | `enum` | No | Values: `bar`, `bar-x`, `bar-y`, `bar-gantt`, `line`, `point`, `line-point`, `area`, `rect`, `rule-x` |
| `data` | `json` | Yes |  |
| `category` | `boolean` | No |  |
| `hideLegend` | `boolean` | No |  |
| `hideXAxis` | `boolean` | No |  |
| `hideYAxis` | `boolean` | No |  |

### `<Link>`

Open a URL when selected.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `url` | `url` | Yes |  |

### `<Divider>`

Horizontal or vertical separator.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `thickness` | `number` | No |  |
| `axis` | `enum` | No | Values: `horizontal`, `vertical` |

### `<Line>`

Fixed-length line.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `thickness` | `number` | No |  |
| `length` | `number` | No |  |
| `axis` | `enum` | No | Values: `horizontal`, `vertical` |

### `<Icon>`

SF Symbol icon.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `systemName` | `string` | Yes |  |
| `size` | `number` | No |  |

### `<Label>`

Text paired with an SF Symbol.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `title` | `string` | No |  |
| `systemName` | `string` | Yes |  |

### `<Progress>`

Linear or circular progress.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `value` | `number` | Yes |  |
| `total` | `number` | No |  |
| `label` | `string` | No |  |
| `style` | `enum` | No | Values: `linear`, `circular` |
| `trackColor` | `color` | No |  |
| `thickness` | `number` | No |  |

### `<Ring>`

Circular progress ring.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `value` | `number` | Yes |  |
| `thickness` | `number` | No |  |
| `trackColor` | `color` | No |  |

### `<Badge>`

Compact status badge.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `text` | `string` | No |  |
| `radius` | `number` | No |  |

### `<Chip>`

Outlined metadata chip.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `text` | `string` | No |  |
| `radius` | `number` | No |  |
| `borderColor` | `color` | No |  |

### `<Stat>`

Title, value, and subtitle statistic.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `title` | `string` | No |  |
| `value` | `string` | Yes |  |
| `subtitle` | `string` | No |  |
| `mutedColor` | `color` | No |  |

### `<Button>`

Interactive widget button. Use actionID to share a declared Package 2.0 action with Siri, Shortcuts, and Control Widgets.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `action` | `enum` | No | Values: `reload` |
| `onClick` | `function` | No |  |
| `actionID` | `action-id` | No |  |

### `<Toggle>`

Interactive widget toggle. A declared actionID requires a package-relative storage stateKey.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `backgroundMaterial` | `enum` | No | Runtime API 1.4. Public SwiftUI frosted material inside the widget, not Home Screen wallpaper blur or system Liquid Glass. At most four material backgrounds per tree. background supplies an opaque-composited Reduce Transparency fallback. In accented/vibrant mode local material is omitted for system rendering; none keeps the ordinary background. Values: `none`, `ultraThin`, `thin`, `regular`, `thick`, `ultraThick` |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Square size (64 or "64"), width,height ("64,48"), or flexible frame ("max", "max,48"). |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | Static degree,x,y,z rotation with four finite numbers and a nonzero axis. Invalid values are ignored; axis magnitude is normalized. Reduce Motion removes the tilt. This does not read device motion or provide parallax. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | iOS public SwiftUI scheduled clock/swing effect. Mac renders static standard-clock poses; other effects remain at rest. Signed clockCustom intervals specify a half-turn (full cycle = 2 * abs(interval)), minimum magnitude 0.25 seconds. App previews can animate; WidgetKit decides cadence and may freeze. Reduced motion/luminance freezes standard clock poses and keeps custom/swing effects at rest. Dynamic scripts are not rerun on animation ticks. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `on` | `boolean` | Yes |  |
| `onClick` | `function` | No |  |
| `actionID` | `action-id` | No |  |
| `stateKey` | `storage-key` | No |  |

## Runtime functions

- `$storage.getString`: Read a package-scoped string. Missing keys return an empty string.
- `$storage.setString`: Set a package-scoped string, limited to 256 KiB of UTF-8. Check the success result.
- `$storage.getJSON`: Read a package-scoped JSON object. Missing or invalid values return an empty object.
- `$storage.setJSON`: Store a valid JSON object, limited to 256 KiB encoded. Check the success result.
- `$storage.compareAndSetString`: Atomically replace a string only when it still matches expected. A missing key matches an empty string. Conflicts return false; reread and retry a bounded number of times. Requires the shared storage container.
- `$storage.compareAndSetJSON`: Atomically replace a JSON object if its current value equals expected, independent of property order. A missing key matches an empty object. Wrong types and conflicts return false. Requires the shared storage container.
- `$storage.remove`: Remove a key from this package only.
- `$storage.keys`: List keys in this package's namespace.
- `$storage.clear`: Clear this package's storage. Other packages are unaffected.
- `$music.isAvailable`: Runtime 1.4. Read-only Music app playback, not every audio player. Requires an installed owner, music permission and Music library approval in native Settings. current() is asynchronous and returns provider, state, hasItem, nullable title/artist/album/duration/position and capturedAt. State may be playing while details are absent (Home Sharing). Native player access is main-thread-only: synchronous hosts prepare one snapshot before JSC waits; background previews capture on the main queue. No playback/queue mutation, scans, artwork, credential or subscription inference. No live queries in future entries/Live Activities. Main system-player API is unavailable on macOS; Web supplies editable samples, never actual device access.
- `$music.authorizationStatus`: Runtime 1.4. Read-only Music app playback, not every audio player. Requires an installed owner, music permission and Music library approval in native Settings. current() is asynchronous and returns provider, state, hasItem, nullable title/artist/album/duration/position and capturedAt. State may be playing while details are absent (Home Sharing). Native player access is main-thread-only: synchronous hosts prepare one snapshot before JSC waits; background previews capture on the main queue. No playback/queue mutation, scans, artwork, credential or subscription inference. No live queries in future entries/Live Activities. Main system-player API is unavailable on macOS; Web supplies editable samples, never actual device access.
- `$music.current`: Runtime 1.4. Read-only Music app playback, not every audio player. Requires an installed owner, music permission and Music library approval in native Settings. current() is asynchronous and returns provider, state, hasItem, nullable title/artist/album/duration/position and capturedAt. State may be playing while details are absent (Home Sharing). Native player access is main-thread-only: synchronous hosts prepare one snapshot before JSC waits; background previews capture on the main queue. No playback/queue mutation, scans, artwork, credential or subscription inference. No live queries in future entries/Live Activities. Main system-player API is unavailable on macOS; Web supplies editable samples, never actual device access.
- `$services.status`: Runtime 1.4: status(service) and profile(service) are asynchronous. Only provider: github. Unknown providers reject with service_operation. Requires an installed owner and services permission. profile additionally requires network and api.github.com in networkDomains, a native connected GitHub account and explicit owner grant. Native Settings handles credentials; scripts cannot log in or obtain tokens. profile returns service, subject, username, displayName, publicRepositories, privateRepositories, followers and following (missing values are null). No live queries in future entries or Live Activities. Eight shared data queries; native requests also share the eight concurrent/32 total network budget, while Web uses its existing preview network budget. Web uses editable best-state samples only; it never authenticates or sends these requests.
- `$services.profile`: Runtime 1.4: status(service) and profile(service) are asynchronous. Only provider: github. Unknown providers reject with service_operation. Requires an installed owner and services permission. profile additionally requires network and api.github.com in networkDomains, a native connected GitHub account and explicit owner grant. Native Settings handles credentials; scripts cannot log in or obtain tokens. profile returns service, subject, username, displayName, publicRepositories, privateRepositories, followers and following (missing values are null). No live queries in future entries or Live Activities. Eight shared data queries; native requests also share the eight concurrent/32 total network budget, while Web uses its existing preview network budget. Web uses editable best-state samples only; it never authenticates or sends these requests.
- `$device.screen`: Device values depend on hardware. Some legacy Mac values are placeholders; inspect the API documentation before using them as measurements.
- `$device.language`: Device values depend on hardware. Some legacy Mac values are placeholders; inspect the API documentation before using them as measurements.
- `$device.model`: Device values depend on hardware. Some legacy Mac values are placeholders; inspect the API documentation before using them as measurements.
- `$device.name`: Device values depend on hardware. Some legacy Mac values are placeholders; inspect the API documentation before using them as measurements.
- `$device.battery`: Device values depend on hardware. Some legacy Mac values are placeholders; inspect the API documentation before using them as measurements.
- `$device.systemVersion`: Device values depend on hardware. Some legacy Mac values are placeholders; inspect the API documentation before using them as measurements.
- `$device.isdarkmode`: Device values depend on hardware. Some legacy Mac values are placeholders; inspect the API documentation before using them as measurements.
- `$device.totalDiskSpace`: Device values depend on hardware. Some legacy Mac values are placeholders; inspect the API documentation before using them as measurements.
- `$device.freeDiskSpace`: Device values depend on hardware. Some legacy Mac values are placeholders; inspect the API documentation before using them as measurements.
- `$system.appInfo`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.locale`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.preferredLanguages`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.timeZone`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.is24HourClock`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.calendarInfo`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.systemUptime`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.memory`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.thermalState`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.lowPowerMode`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.brightness`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.reduceMotionEnabled`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.platform`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.hostName`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.processName`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.osVersionString`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.processorCount`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$system.activeProcessorCount`: System metadata, not whole-device CPU, FPS or network traffic monitoring. Hardware-specific values may be unavailable.
- `$photos.isAvailable`: Requires photos permission and explicit native photo/album selection (none by default). Limited Photos authorization is supported. items({limit:1..4,offset:0..63,maxAgeSeconds:0..86400}) returns bounded, metadata-stripped JPEG thumbnails as image data URLs. Four 768px / 128KiB thumbnails at most; private snapshots expire after 24h and are rechecked against current access, selected sources and asset revisions. Cloud-only items report unavailableCount; download them in Photos first. Future timeline/Live Activity presentations read matching snapshots only. Web uses editable sample data and photosSelection IDs; no actual library access.
- `$photos.authorizationStatus`: Requires photos permission and explicit native photo/album selection (none by default). Limited Photos authorization is supported. items({limit:1..4,offset:0..63,maxAgeSeconds:0..86400}) returns bounded, metadata-stripped JPEG thumbnails as image data URLs. Four 768px / 128KiB thumbnails at most; private snapshots expire after 24h and are rechecked against current access, selected sources and asset revisions. Cloud-only items report unavailableCount; download them in Photos first. Future timeline/Live Activity presentations read matching snapshots only. Web uses editable sample data and photosSelection IDs; no actual library access.
- `$photos.requestAuthorization`: Requires photos permission and explicit native photo/album selection (none by default). Limited Photos authorization is supported. items({limit:1..4,offset:0..63,maxAgeSeconds:0..86400}) returns bounded, metadata-stripped JPEG thumbnails as image data URLs. Four 768px / 128KiB thumbnails at most; private snapshots expire after 24h and are rechecked against current access, selected sources and asset revisions. Cloud-only items report unavailableCount; download them in Photos first. Future timeline/Live Activity presentations read matching snapshots only. Web uses editable sample data and photosSelection IDs; no actual library access.
- `$photos.items`: Requires photos permission and explicit native photo/album selection (none by default). Limited Photos authorization is supported. items({limit:1..4,offset:0..63,maxAgeSeconds:0..86400}) returns bounded, metadata-stripped JPEG thumbnails as image data URLs. Four 768px / 128KiB thumbnails at most; private snapshots expire after 24h and are rechecked against current access, selected sources and asset revisions. Cloud-only items report unavailableCount; download them in Photos first. Future timeline/Live Activity presentations read matching snapshots only. Web uses editable sample data and photosSelection IDs; no actual library access.
- `$calendar.isAvailable`: Requires calendar in widget.json and full system Calendar access. The user's native Settings source selection limits metadata, events and cached snapshots; scripts cannot enlarge it. Use calendars() for permitted IDs and show setup when no sources are selected. Queries are read-only, limited to 31 days and 50 items. Preview calendarSelection simulates this scope without granting package permission.
- `$calendar.authorizationStatus`: Requires calendar in widget.json and full system Calendar access. The user's native Settings source selection limits metadata, events and cached snapshots; scripts cannot enlarge it. Use calendars() for permitted IDs and show setup when no sources are selected. Queries are read-only, limited to 31 days and 50 items. Preview calendarSelection simulates this scope without granting package permission.
- `$calendar.requestAuthorization`: Requires calendar in widget.json and full system Calendar access. The user's native Settings source selection limits metadata, events and cached snapshots; scripts cannot enlarge it. Use calendars() for permitted IDs and show setup when no sources are selected. Queries are read-only, limited to 31 days and 50 items. Preview calendarSelection simulates this scope without granting package permission.
- `$calendar.calendars`: Requires calendar in widget.json and full system Calendar access. The user's native Settings source selection limits metadata, events and cached snapshots; scripts cannot enlarge it. Use calendars() for permitted IDs and show setup when no sources are selected. Queries are read-only, limited to 31 days and 50 items. Preview calendarSelection simulates this scope without granting package permission.
- `$calendar.events`: Requires calendar in widget.json and full system Calendar access. The user's native Settings source selection limits metadata, events and cached snapshots; scripts cannot enlarge it. Use calendars() for permitted IDs and show setup when no sources are selected. Queries are read-only, limited to 31 days and 50 items. Preview calendarSelection simulates this scope without granting package permission.
- `$reminders.isAvailable`: Requires reminders in widget.json and full system Reminders access. Reads require native Settings selected lists. create/update/setCompleted additionally require remindersWrite and a native declared action, stable requestID, durable replay receipts and an unchanged selected list. Web writes update preview-only items/receipts; receipt identities are derived from that state, with configurable API errors. Use lists() for IDs. items() selects pending due dates or completed completion dates in a positive window of at most 31 days, up to 50 items. Undated pending reminders are excluded. remindersSelection mocks the user scope without granting permission.
- `$reminders.authorizationStatus`: Requires reminders in widget.json and full system Reminders access. Reads require native Settings selected lists. create/update/setCompleted additionally require remindersWrite and a native declared action, stable requestID, durable replay receipts and an unchanged selected list. Web writes update preview-only items/receipts; receipt identities are derived from that state, with configurable API errors. Use lists() for IDs. items() selects pending due dates or completed completion dates in a positive window of at most 31 days, up to 50 items. Undated pending reminders are excluded. remindersSelection mocks the user scope without granting permission.
- `$reminders.requestAuthorization`: Requires reminders in widget.json and full system Reminders access. Reads require native Settings selected lists. create/update/setCompleted additionally require remindersWrite and a native declared action, stable requestID, durable replay receipts and an unchanged selected list. Web writes update preview-only items/receipts; receipt identities are derived from that state, with configurable API errors. Use lists() for IDs. items() selects pending due dates or completed completion dates in a positive window of at most 31 days, up to 50 items. Undated pending reminders are excluded. remindersSelection mocks the user scope without granting permission.
- `$reminders.lists`: Requires reminders in widget.json and full system Reminders access. Reads require native Settings selected lists. create/update/setCompleted additionally require remindersWrite and a native declared action, stable requestID, durable replay receipts and an unchanged selected list. Web writes update preview-only items/receipts; receipt identities are derived from that state, with configurable API errors. Use lists() for IDs. items() selects pending due dates or completed completion dates in a positive window of at most 31 days, up to 50 items. Undated pending reminders are excluded. remindersSelection mocks the user scope without granting permission.
- `$reminders.items`: Requires reminders in widget.json and full system Reminders access. Reads require native Settings selected lists. create/update/setCompleted additionally require remindersWrite and a native declared action, stable requestID, durable replay receipts and an unchanged selected list. Web writes update preview-only items/receipts; receipt identities are derived from that state, with configurable API errors. Use lists() for IDs. items() selects pending due dates or completed completion dates in a positive window of at most 31 days, up to 50 items. Undated pending reminders are excluded. remindersSelection mocks the user scope without granting permission.
- `$reminders.create`: Requires reminders in widget.json and full system Reminders access. Reads require native Settings selected lists. create/update/setCompleted additionally require remindersWrite and a native declared action, stable requestID, durable replay receipts and an unchanged selected list. Web writes update preview-only items/receipts; receipt identities are derived from that state, with configurable API errors. Use lists() for IDs. items() selects pending due dates or completed completion dates in a positive window of at most 31 days, up to 50 items. Undated pending reminders are excluded. remindersSelection mocks the user scope without granting permission.
- `$reminders.update`: Requires reminders in widget.json and full system Reminders access. Reads require native Settings selected lists. create/update/setCompleted additionally require remindersWrite and a native declared action, stable requestID, durable replay receipts and an unchanged selected list. Web writes update preview-only items/receipts; receipt identities are derived from that state, with configurable API errors. Use lists() for IDs. items() selects pending due dates or completed completion dates in a positive window of at most 31 days, up to 50 items. Undated pending reminders are excluded. remindersSelection mocks the user scope without granting permission.
- `$reminders.setCompleted`: Requires reminders in widget.json and full system Reminders access. Reads require native Settings selected lists. create/update/setCompleted additionally require remindersWrite and a native declared action, stable requestID, durable replay receipts and an unchanged selected list. Web writes update preview-only items/receipts; receipt identities are derived from that state, with configurable API errors. Use lists() for IDs. items() selects pending due dates or completed completion dates in a positive window of at most 31 days, up to 50 items. Undated pending reminders are excluded. remindersSelection mocks the user scope without granting permission.
- `$health.authorizationStatus`: Read-only HealthKit. Request access in the app. Runtime 1.4 adds sleepSummary (up to 7 days / 256 samples, union with explicit stage-conflict precedence), activitySummary (one local Gregorian day including active-energy or move-time mode and optional goals), and workouts (up to 31 days / 50 fully-contained summaries, optional kcal/meters). These require an explicit health manifest; all share the query budget and cannot run in future/Live Activity presentations. No Health readings are persisted by the API. Authorization completion does not reveal whether individual read types were granted; empty results must not be labelled permission denied. API 1.3 readings add hasSamples: false means no readable samples, never a read-denial verdict. Existing value/unit/start/end fields remain.
- `$health.sleepSummary`: Read-only HealthKit. Request access in the app. Runtime 1.4 adds sleepSummary (up to 7 days / 256 samples, union with explicit stage-conflict precedence), activitySummary (one local Gregorian day including active-energy or move-time mode and optional goals), and workouts (up to 31 days / 50 fully-contained summaries, optional kcal/meters). These require an explicit health manifest; all share the query budget and cannot run in future/Live Activity presentations. No Health readings are persisted by the API. Authorization completion does not reveal whether individual read types were granted; empty results must not be labelled permission denied. API 1.3 readings add hasSamples: false means no readable samples, never a read-denial verdict. Existing value/unit/start/end fields remain.
- `$health.activitySummary`: Read-only HealthKit. Request access in the app. Runtime 1.4 adds sleepSummary (up to 7 days / 256 samples, union with explicit stage-conflict precedence), activitySummary (one local Gregorian day including active-energy or move-time mode and optional goals), and workouts (up to 31 days / 50 fully-contained summaries, optional kcal/meters). These require an explicit health manifest; all share the query budget and cannot run in future/Live Activity presentations. No Health readings are persisted by the API. Authorization completion does not reveal whether individual read types were granted; empty results must not be labelled permission denied. API 1.3 readings add hasSamples: false means no readable samples, never a read-denial verdict. Existing value/unit/start/end fields remain.
- `$health.workouts`: Read-only HealthKit. Request access in the app. Runtime 1.4 adds sleepSummary (up to 7 days / 256 samples, union with explicit stage-conflict precedence), activitySummary (one local Gregorian day including active-energy or move-time mode and optional goals), and workouts (up to 31 days / 50 fully-contained summaries, optional kcal/meters). These require an explicit health manifest; all share the query budget and cannot run in future/Live Activity presentations. No Health readings are persisted by the API. Authorization completion does not reveal whether individual read types were granted; empty results must not be labelled permission denied. API 1.3 readings add hasSamples: false means no readable samples, never a read-denial verdict. Existing value/unit/start/end fields remain.
- `$health.isAvailable`: Read-only HealthKit. Request access in the app. Runtime 1.4 adds sleepSummary (up to 7 days / 256 samples, union with explicit stage-conflict precedence), activitySummary (one local Gregorian day including active-energy or move-time mode and optional goals), and workouts (up to 31 days / 50 fully-contained summaries, optional kcal/meters). These require an explicit health manifest; all share the query budget and cannot run in future/Live Activity presentations. No Health readings are persisted by the API. Authorization completion does not reveal whether individual read types were granted; empty results must not be labelled permission denied. API 1.3 readings add hasSamples: false means no readable samples, never a read-denial verdict. Existing value/unit/start/end fields remain.
- `$health.requestAuthorization`: Read-only HealthKit. Request access in the app. Runtime 1.4 adds sleepSummary (up to 7 days / 256 samples, union with explicit stage-conflict precedence), activitySummary (one local Gregorian day including active-energy or move-time mode and optional goals), and workouts (up to 31 days / 50 fully-contained summaries, optional kcal/meters). These require an explicit health manifest; all share the query budget and cannot run in future/Live Activity presentations. No Health readings are persisted by the API. Authorization completion does not reveal whether individual read types were granted; empty results must not be labelled permission denied. API 1.3 readings add hasSamples: false means no readable samples, never a read-denial verdict. Existing value/unit/start/end fields remain.
- `$health.stepCountToday`: Read-only HealthKit. Request access in the app. Runtime 1.4 adds sleepSummary (up to 7 days / 256 samples, union with explicit stage-conflict precedence), activitySummary (one local Gregorian day including active-energy or move-time mode and optional goals), and workouts (up to 31 days / 50 fully-contained summaries, optional kcal/meters). These require an explicit health manifest; all share the query budget and cannot run in future/Live Activity presentations. No Health readings are persisted by the API. Authorization completion does not reveal whether individual read types were granted; empty results must not be labelled permission denied. API 1.3 readings add hasSamples: false means no readable samples, never a read-denial verdict. Existing value/unit/start/end fields remain.
- `$health.activeEnergyToday`: Read-only HealthKit. Request access in the app. Runtime 1.4 adds sleepSummary (up to 7 days / 256 samples, union with explicit stage-conflict precedence), activitySummary (one local Gregorian day including active-energy or move-time mode and optional goals), and workouts (up to 31 days / 50 fully-contained summaries, optional kcal/meters). These require an explicit health manifest; all share the query budget and cannot run in future/Live Activity presentations. No Health readings are persisted by the API. Authorization completion does not reveal whether individual read types were granted; empty results must not be labelled permission denied. API 1.3 readings add hasSamples: false means no readable samples, never a read-denial verdict. Existing value/unit/start/end fields remain.
- `$health.heartRateLatest`: Read-only HealthKit. Request access in the app. Runtime 1.4 adds sleepSummary (up to 7 days / 256 samples, union with explicit stage-conflict precedence), activitySummary (one local Gregorian day including active-energy or move-time mode and optional goals), and workouts (up to 31 days / 50 fully-contained summaries, optional kcal/meters). These require an explicit health manifest; all share the query budget and cannot run in future/Live Activity presentations. No Health readings are persisted by the API. Authorization completion does not reveal whether individual read types were granted; empty results must not be labelled permission denied. API 1.3 readings add hasSamples: false means no readable samples, never a read-denial verdict. Existing value/unit/start/end fields remain.
- `$location.isAvailable`: Package 2.0 requires location permission. Request system access in the app. Widgets also require isAuthorizedForWidgetUpdates. Cache is rechecked against authorization and precision, discarded after 24 hours or revocation, and reports age/isStale.
- `$location.authorizationStatus`: Package 2.0 requires location permission. Request system access in the app. Widgets also require isAuthorizedForWidgetUpdates. Cache is rechecked against authorization and precision, discarded after 24 hours or revocation, and reports age/isStale.
- `$location.isAuthorizedForWidgetUpdates`: Package 2.0 requires location permission. Request system access in the app. Widgets also require isAuthorizedForWidgetUpdates. Cache is rechecked against authorization and precision, discarded after 24 hours or revocation, and reports age/isStale.
- `$location.requestAuthorization`: Package 2.0 requires location permission. Request system access in the app. Widgets also require isAuthorizedForWidgetUpdates. Cache is rechecked against authorization and precision, discarded after 24 hours or revocation, and reports age/isStale.
- `$location.current`: Package 2.0 requires location permission. Request system access in the app. Widgets also require isAuthorizedForWidgetUpdates. Cache is rechecked against authorization and precision, discarded after 24 hours or revocation, and reports age/isStale.
- `$notifications.status`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$notifications.pending`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$notifications.schedule`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$notifications.cancel`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$health.dailyStatistics`: Runtime 1.6. Read-only daily HealthKit statistics on installed iPhone/iPad widgets. Declare health and minimumRuntimeVersion 1.6, review Health access in native Settings. No separate System Access toggle. Missing readings are null/hasSamples false and cannot establish read denial. No raw samples, persistence or queries in future/Live Activity presentations. Preview fixtures never access real Health data.
- `$calendar.create`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data. Calendar writes need calendar and calendarWrite; updates are limited to events this installation created.
- `$calendar.update`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data. Calendar writes need calendar and calendarWrite; updates are limited to events this installation created.
- `$weather.forecast`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$alarms.status`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$alarms.pending`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$alarms.schedule`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$alarms.cancel`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$alarms.stop`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$alarms.pause`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$alarms.resume`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$documents.list`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$documents.readJSON`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$documents.readCSV`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$contacts.selected`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$maps.search`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$maps.geocode`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$maps.reverseGeocode`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$maps.snapshot`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$home.items`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$home.setPower`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$home.runScene`: Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.
- `$icloud.readJSON`: Read cached JSON and revision; conflicts preserve all heads. Requires icloud permission and a native connection. Never certifies upload.
- `$icloud.writeJSON`: Save a new immutable JSON revision locally from a user action. Requires the revision from readJSON. Background exchange is eventual.
- `$icloud.resolveJSON`: Explicitly resolve all observed conflicting heads into a new revision. Stale tokens fail; originals remain.
- `$icloud.sync`: Exchange materialized revisions with iCloud; requires a user action. Upload completion is unknown.
- `$icloud.status`: Read native connection state. In the app, explicitly connect packages to separate stores for isolation or the same store ID to share JSON documents. Scripts cannot choose store IDs. Sync is eventual; local $storage is not migrated. Web uses preview mocks.
- `$file.exists`: Return whether a regular file is locally present inside this package, including binary assets. Missing files, directories, unsafe paths and links return false. Does not download iCloud files or read outside the package. Web preview uses workspace file presence.
- `$file.read`: Read package-relative UTF-8 text. Missing or unavailable files return an empty string.
- `$file.readJSON`: Read a package-relative JSON object.
- `fetch`: Perform a network request and return its response text. Existing HTTP methods keep this string result.
- `$http.getResponse`: GET response metadata: {status, body, headers}. Headers are limited to content-type, cache-control, expires, last-modified, date and retry-after (lowercase; each at most 2048 UTF-8 bytes). Network permissions, public-host policy, redirects, body limits and timeline restrictions still apply. HTTP error statuses resolve; transport errors reject.
- `importJS`: Import a package-relative JavaScript file.
- `$dataSource.request`: Call a declared Data Source Plugin operation. Requires Package 2.0 plugins, network permission, and networkDomains declarations.
- `$xml.parse`: Parse up to 256 KiB of XML into {name, attributes, text, children}. DTDs and external entities are rejected; depth and node limits apply.

## Environment values

- `timeline-date`
- `timeline-time-zone`
- `timeline-slot`
- `timeline-is-projection`
- `widget-size`
- `widget-param`
- `widget-rendering-mode`
- `live-activity-state`
- `live-activity-is-stale`
- `live-activity-surface`
- `action-id`
- `action-source`
- `action-value`
- `control-id`
- `control-value`

