# Planes of Nothingness

A webcomic reader that ships as **one HTML file**. Every page image is embedded
inside it, so it works offline: copy `planes-of-nothingness.html` to a phone and
open it in the browser.

## Reading

- **Scroll** mode shows an episode as one long strip.
- **Pages** mode shows one page at a time. Swipe, tap the left/right edge, or use
  the arrow keys. Tap the middle to hide the bars.
- The last page you read and your preferred mode are remembered on each device.

## Project layout

| Path | What it is |
| --- | --- |
| `comic/comic.json` | The list of seasons, episodes and pages, in reading order, with each page's caption text (used for screen readers). |
| `comic/season-XX/episode-XX/` | The page images. |
| `src/reader.html` | The reader app (HTML, CSS and plain JavaScript, no libraries). Contains a `__COMIC_DATA__` placeholder. |
| `build.ps1` | Fills the placeholder with the comic data and images and writes the final file. |
| `planes-of-nothingness.html` | The built, ready-to-use file. Do not edit it by hand; rebuild it instead. |

## Building

On Windows, in PowerShell, from this folder:

```powershell
.\build.ps1
```

## Adding an episode

1. Put the page images in a new folder, e.g. `comic/season-01/episode-02/01.jpg`, `02.jpg`, ...
2. Add the episode to `comic/comic.json` with its `folder` and a `pages` list.
   An optional `"title"` is shown instead of "Episode 2".
3. Run `.\build.ps1` and commit the result.

A new season works the same way: add a season entry with its own `folder`.
