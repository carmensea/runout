# Themes

Status: built 2026-11-05, five themes approved by the owner. One token file, one component, one
Settings panel; no change to layout, typography, routes, data or integrations.

## How it works

- **Tokens.** `src/styles/tokens.css` keeps `:root` as the Original theme and adds one
  `:root[data-theme='…']` block per theme over the same semantic names (`--bg --s1 --s2 --ln --ln2
  --fg --fg2 --mu --ac --acfg --err --c1…--c7`). Two surfaces exist for themes to open or close:
  `--shell`, the page ground behind everything (the page colour, or transparent when a sky shows
  through), and `--panel`, the surface under dense content (transparent in Original and Moss).
  The moving themes also carry `--sky-ground`, `--sky-conic`, `--sky-blur`, `--sky-turn`,
  `--sky-overlay` and `--sky-star-opacity`.
- **The choice.** `src/theme/theme.ts` reads and writes `runout:theme` in localStorage and sets
  `data-theme` on `<html>`; an inline script in `index.html` applies it before the first paint, so
  nothing flashes; an unknown stored value falls back to Original. `useTheme()` re-renders
  subscribers when it changes. The `theme-color` meta follows the theme.
- **The sky.** `src/components/shell/Sky.tsx`, mounted once in the app shell, draws nothing in
  Original and Moss. For Cotton Candy, Midnight Candy and Verdant it is idlewinny.com's rotating
  background from the recovered site (`components/rotating-background.tsx`,
  `starry-background.tsx`, `app/globals.css` in the site's own source, kept privately): a fixed
  container, a 200 percent conic layer blurred 30 px turning once in 18 seconds, a dark radial
  overlay, and 40 of the original's twinkling stars placed by a fixed seed. The site's 50 ms timer
  is a CSS rotation of the same period; animations are transform-only. `prefers-reduced-motion`
  holds the sky and the stars at their first frame.
- **Component changes, all no-ops in Original:** `body` and the shell take `--shell`; dashboard
  sections, Settings panels and the Time Machine's blocks take `--panel`; the activity chart's bars
  take `--c1` instead of the accent.
- **Settings → Appearance** tab: a radio group of tiles, each
  rendered from its theme's own tokens by scoping `data-theme` on the tile. The account menu at the
  top right offers the same five.
- **Follows the account.** Signed in, a choice is saved with `PATCH /api/account` (`users.theme`,
  nullable) and reported in `GET /api/connection`; the shell applies it once the connection loads.
  The browser's own copy still paints first, so nothing flashes; a failed save changes nothing visible.

## The five

| Theme | Ground | Sky | Accent |
|---|---|---|---|
| Original | charcoal | none | burnt orange, unchanged |
| Moss | deep forest, sidebar a step lighter | none | botanical green; data stays pale sage |
| Cotton Candy | the Idle Winny sky | pink, purple, slate blue, blue-violet, royal blue | bubblegum pink |
| Midnight Candy | the same sky at night | deep plum, indigo, violet, muted pink; 36 s turn | muted pink |
| Verdant | a forest aurora | deep forest, emerald, dark teal, turquoise, sea-glass, pine | soft emerald |

## Knobs for review (prototype only, read from `<html>` data attributes once)

`data-sky-turn` (seconds), `data-sky-stars` (count), `data-sky-mode="scaled"` (draw the blurred
layer at 100 percent and scale it by two: the same picture at a quarter of the pixels, for phones
if the cost ever demands it). The capture scripts set them; nothing in the app does.

## Not done, on purpose

The Idle Winny falling stars and cloud.
