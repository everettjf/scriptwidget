# Package files

<!-- platforms:start -->
> **Runs on:** iPhone and iPad, Mac, Android, Windows, Linux. Details and limits: [Platform support](platform-support.md).
<!-- platforms:end -->

`$file` reads only the currently executing package. In installation-bound execution it uses the frozen package snapshot. It does not expose device directories, another widget, system photo albums or account credentials.

- `$file.read(path)` reads UTF-8 text; missing/unreadable text returns an empty string.
- `$file.readJSON(path)` reads a JSON object. Missing or invalid JSON returns an empty object; a non-object JSON value is not an object result.
- `$file.exists(path)` (API 1.3) returns whether a regular file is present at the exact package-relative path, including binary resources. Directories, missing files, links, hard links and unsafe paths return false in native execution. It does not start an iCloud download. Presence does not validate image bytes or guarantee readable contents.

```jsx
const name = "background-00000000-0000-4000-8000-000000000001";
$render($file.exists("image/" + name + ".png")
  ? <image name={name} mode="fill" frame="max"/>
  : <text>Restore the selected background image in ScriptWidget.</text>);
```

Use exact canonical relative names, without absolute paths, drive prefixes, backslashes, dot components, control characters or boundary escapes. File operations revalidate the native installation snapshot; a removed or switched installation cannot follow the same name into another widget.

Web Studio evaluates presence against workspace files, including binary resource names. Image bytes remain in the renderer; the execution worker receives zero-byte presence markers, and cannot read binary images as text or import them as executable modules. Add/remove the workspace file to change this value, rather than providing a fake per-method API response. Node's package directory loader includes regular binary files as bytes; execution preparation retains their paths without decoding their content.
