# ScriptWidget Runtime API

> Generated from Studio's static API metadata (schema v1, runtime 26.6). The native runtime switch is authoritative. Do not edit by hand.

## Components

### `<VStack>`

Arrange children vertically.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `spacing` | `number` | No |  |

### `<HStack>`

Arrange children horizontally.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `spacing` | `number` | No |  |

### `<ZStack>`

Overlay children.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |

### `<VGrid>`

Vertical lazy grid.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Values: `leading`, `center`, `trailing` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `columns` | `string` | Yes |  |
| `spacing` | `number` | No |  |

### `<HGrid>`

Horizontal lazy grid.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Values: `top`, `center`, `bottom`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `columns` | `string` | Yes |  |
| `spacing` | `number` | No |  |

### `<Text>`

Display text content.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `text` | `string` | No |  |

### `<Date>`

Display a formatted date.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `date` | `date|number` | Yes |  |
| `style` | `enum` | No | Values: `time`, `date`, `relative`, `offset`, `timer` |

### `<Image>`

Display a bundled, remote, or SF Symbol image.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
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

Display a GIF from the package.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `file` | `string` | Yes |  |

### `<Spacer>`

Flexible layout space.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `minLength` | `number` | No |  |

### `<Rect>`

Rectangle shape.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `trim` | `number|string` | No |  |
| `stroke` | `string` | No |  |

### `<RoundedRect>`

Filled rounded rectangle.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `radius` | `number` | No |  |

### `<Capsule>`

Capsule shape.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `trim` | `number|string` | No |  |
| `stroke` | `string` | No |  |

### `<Ellipse>`

Ellipse shape.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `trim` | `number|string` | No |  |
| `stroke` | `string` | No |  |

### `<Circle>`

Circle shape.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `trim` | `number|string` | No |  |
| `stroke` | `string` | No |  |

### `<Gauge>`

Display a gauge or instrument.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
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
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
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
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `url` | `url` | Yes |  |

### `<Divider>`

Horizontal or vertical separator.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `thickness` | `number` | No |  |
| `axis` | `enum` | No | Values: `horizontal`, `vertical` |

### `<Line>`

Fixed-length line.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
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
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `systemName` | `string` | Yes |  |
| `size` | `number` | No |  |

### `<Label>`

Text paired with an SF Symbol.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `title` | `string` | No |  |
| `systemName` | `string` | Yes |  |

### `<Progress>`

Linear or circular progress.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
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
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
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
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `text` | `string` | No |  |
| `radius` | `number` | No |  |

### `<Chip>`

Outlined metadata chip.

| Property | Type | Required | Notes |
| --- | --- | --- | --- |
| `background` | `color` | No | Background color, hex value, or named color. |
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
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
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
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
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
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
| `color` | `color` | No | Foreground color, hex value, or named color. |
| `font` | `enum` | No | Semantic text style. Values: `largeTitle`, `title`, `title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`, `caption`, `caption2` |
| `fontWeight` | `enum` | No | Font weight. Values: `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black` |
| `fontDesign` | `enum` | No | Font design. Values: `default`, `rounded`, `serif`, `monospaced` |
| `frame` | `number|string` | No | Size or frame description. |
| `padding` | `number|string` | No | Padding amount or edge description. |
| `corner` | `number` | No | Corner radius. |
| `opacity` | `number` | No | Opacity from 0 through 1. |
| `alignment` | `enum` | No | Layout alignment. Values: `center`, `leading`, `trailing`, `top`, `bottom`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`, `firstTextBaseline`, `lastTextBaseline` |
| `clip` | `enum` | No | Clip the view to a shape. Values: `circle`, `rect`, `capsule`, `ellipse` |
| `rotation` | `number` | No | Rotation in degrees. |
| `rotation3d` | `string` | No | 3D rotation description. |
| `shadow` | `string` | No | Shadow color, radius, and offset description. |
| `animation` | `string` | No | Timeline-driven animation description. |
| `widgetAccentable` | `boolean` | No | Group this view into the accent layer in tinted and vibrant widget appearances. |
| `linkurl` | `url` | No | Widget deep link URL. |
| `on` | `boolean` | Yes |  |
| `onClick` | `function` | No |  |
| `actionID` | `action-id` | No |  |
| `stateKey` | `storage-key` | No |  |

## Runtime functions

- `fetch`: Perform a network request.
- `importJS`: Import a package-relative JavaScript file.
- `$dataSource.request`: Call a declared Data Source Plugin operation. Requires Package 2.0 plugins, network permission, and networkDomains declarations.

## Environment values

- `widgetFamily`
- `scriptName`
- `scriptParameter`
- `widget-rendering-mode`
- `live-activity-state`
- `live-activity-surface`
- `action-id`
- `action-source`
- `action-value`
- `control-id`
- `control-value`

