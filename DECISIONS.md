# Decisions

Lasting decisions about how StableBar is built, reviewed and shipped, so they don't get argued again or lost in a closed pull request. Each says what was decided, why, and where. Product choices, such as a feature that was declined, stay in their issues, where the [triage skill](.agents/skills/triage/SKILL.md) finds them.

Add an entry when a pull request sets a rule, a policy or a choice not to do something. Changing or removing one is the maintainers' call.

## Releases

- **Betas from `main`, stable by hand** (2026-10-16, [#3], [#23]). A push to `main` publishes a beta when the app changed since the newest release and a `feat`, `fix`, `perf` or `refactor` commit changed it, and a maintainer promotes a beta to stable, so stable ships what beta users ran. There is no develop branch. Pushes that change only docs, CI or tests don't ship the same app again ([#309]).
- **Merge commits by default** ([CONTRIBUTING](CONTRIBUTING.md#how-we-work)). semantic-release reads each commit that reaches `main`: a merge commit leaves it every commit to read, and a squash leaves one, for when a single commit should stand for the pull request. [Commits and releases](CONTRIBUTING.md#commits-and-releases) says which commits make a release and reach the changelog.
- **An issue for every `fix`, `feat` or `perf`** (2026-10-31, [#390]). The issue holds the problem and the decision; the `Linked issue` check enforces it. Other types can skip it.
- **Updates carry an EdDSA signature as well as the Developer ID** (2026-11-10, [#335]). Sparkle checks both, so the signing team or the key can change in a release while the other still matches. This replaces [#100]'s choice of the Developer ID alone. The feed isn't published without the `SPARKLE_ED_PRIVATE_KEY` secret, and [CONTRIBUTING](CONTRIBUTING.md#commits-and-releases) says how to back up and change the key.
- **Release secrets live in the `release` environment** (2026-11-19). Only `main` can use it, so a workflow pushed on another branch can't read the signing, notarization and update keys. Anyone with write access can push such a branch, and a repository secret reaches it. The variables stay repository-wide.
- **The old `Seb-GRAF` repository names stay free** (2026-11-20, [#854]). StableBar, `stablebar-packages` and `homebrew-tap` moved to `stablebox`, and installed copies still reach them through GitHub's redirects from `Seb-GRAF`: the update feed, the release list, the Store index, the schema link that tells older builds which release wrote a file, and existing Homebrew taps. Creating a repository or fork with one of those names under `Seb-GRAF` deletes its redirect for good, so never do it.
- **Homebrew's `zap` keeps `~/.config/stablebar`** (2026-11-25). The casks in `stablebox/homebrew-tap` and homebrew/cask trash only StableBar's caches and preferences. That folder holds people's configuration, scripts and packages, the Cask Cookbook says `zap` must not remove files people made, and StableBar's own Uninstall keeps it unless asked.

## Reviews and checks

- **cubic reviews every pull request, CodeRabbit the risky ones** (2026-11-17, [#772], [#773]). CodeRabbit's free plan allows each author two reviews an hour, so pull requests opened together went unreviewed. cubic is free for public repositories and resolves its own threads. CodeRabbit, which had reviewed every pull request since 2026-10-31 ([#391]), now reviews those labeled `deep-review`: more than 400 changed lines, a file in `.github/deep-review-paths`, or added by hand. A workflow asks it again every hour when its limit held a review back. No paid review tools or API keys.
- **No auto-merge** (2026-10-31). The rules need no approval, but a maintainer merges; nothing merges itself.
- **A person approves changed screens** (2026-10-31, [#395], [#397]). CI draws before/after screens, and any maintainer, the author too, adds `visual-ok` after looking. A visible change also shows screenshots in its pull request description (2026-11-08, [#484]).
- **Pull requests compare with `main`'s own screens** (2026-11-17). Each push to `main` draws its screens once, and a pull request uses those of its base, drawing from the base only the scenes it adds or edits, instead of drawing the whole base again in every run. Docs images drawn from one commit on different CI Macs, and on two runner images, matched byte for byte. A cancelled draw leaves Visual review pending, not failed. A pull request waits on Linux for `main`'s screens of its base while `main`'s run is drawing them, rather than drawing the base again on a Mac. When the base still has scenes to draw and the app changed, it uses `main`'s release build of the base if that run kept one, and compiles the base otherwise.
- **`main`'s CI doesn't preempt pull requests** (2026-11-17). From 2026-11-16, a run on `main` cancelled the pull request runs it found and restarted their cancelled jobs once its own were done. Main stopped waiting, but in its first day this threw away about 1,600 macOS minutes of cut-off jobs, showed pull requests as failed until the restart, and reran them against the `main` from before the merge. Before it, only one run on `main` had waited long for a Mac (88 minutes). Pull requests now spend fewer macOS minutes instead; if `main` waits again, the answer is a merge queue or more runners, not cancelling pull requests.
- **CI builds with one pinned Xcode** (2026-11-08, [#479]). A runner image update can't change the toolchain under a pull request; moving to a newer Xcode is a pull request of its own.
- **Commit messages are checked before they leave the Mac** (2026-11-08, [#485]). Git hooks check them in every tool, and Claude Code also builds when an agent stops. `STABLEBAR_SKIP_HOOKS=1` turns the hooks off for one person.
- **Screens are drawn once they hold still, each scene in a process of its own** (2026-11-20, [#794]). A drawing is kept once three in a row match, held for two seconds while a spinner shows, instead of after a fixed two seconds. Watching the process's threads and run loop instead of its drawings missed changes that only a drawing showed. Scenes draw a few at once, each in a process of its own: several at once in one process shared its main thread and drew pages still loading on CI's three cores, and what a process has drawn changes what it draws later, such as which version of the app's icon an image gets.
- **Scenes draw only dark unless appearance is what they show** (2026-11-24). Every scene drew light and dark, 326 images taking about five minutes on each side of a pull request's comparison. In November's pull requests, about 395 changed screens changed in both appearances, and no scene changed in only one: the five screens that did were docs images, which still draw both. Scenes about contrast, transparency, text that follows its background, themes and their tokens, tinted images, color editors and shadows keep both.
- **A flaky test doesn't block a pull request** (2026-11-17). When up to five Swift Testing tests fail, the Test job runs them once more on their own and passes with a warning naming those that pass then. They still get fixed, in a pull request of their own. A test that fails twice, an XCTest failure, a crash, a hang or more failures fail the job.

## Code

- **Included themes don't change their look in place** (2026-11-20, [#873]). A revamp retires them and adds new themes under new IDs. Anyone whose configuration selects a retired theme keeps it, unchanged and with their edits. The themes the revamp retires move to the Store: the update installs a user's theme as its Store package, from a copy inside the app, so it needs no network, and Built-in, which a configuration without a theme draws, becomes the Store theme **Classic**. Themes retired before stay in **Yours** for those who use them and don't go to the Store. Someone who chose a theme chose how their bar looks, and their edits are tuned to it, so an update never redraws it. Retired themes keep shipping, frozen, for files the update can't rewrite, such as included files, but nothing besides the Store offers one to someone who doesn't have it. The fallback, the values under every theme that fill whatever it leaves out, never changes either: Fern and the themes people saved or made on the website lean on it.
- **Settings keeps edits to the look with their theme** (2026-11-19, [#853]). What Settings changes about the look (theme colors, the shared widget, group, popup and bar styles, the bar's look and a widget's Style tab) goes into the main file's profile whose only condition is the selected theme, created on the first edit, so switching themes leaves it with that theme and choosing the theme again brings it back. Such a profile applies even while another profile is pinned. Look values in the main file outside profiles apply under every theme: Settings lists them and moves them in or out, but saves a look edit there only through **Apply to every theme**. Putting a widget in one of the theme's groups, taking it out and **Ungroup** on such a group are edits of the theme too ([#873]), since another theme may not have the group; groups people start with **Group With** stay in the main file.
- **Settings changes the look in one place** (2026-11-24, [#923]). Appearance holds every color, font and size, and the bar's position; the Bar tab holds what's on the bar, where it shows and its screens. [#853] gave the bar editor the same look sections as the Theme page, and people couldn't tell which one to use. A widget's or a group's own style stays with it in the Bar tab. The empty `members` list **Ungroup** leaves in the main file for a group the selected theme doesn't fill is the bar's structure, so Settings doesn't list it as a look value that applies under every theme ([#925]).
- **Previews of the bar read only wallpapers macOS doesn't protect** (2026-11-20, [#873]). Behind the theme cards and the bar's preview, StableBar shows the Mac's wallpaper only when its path, with symbolic links and `..` resolved, is in /System or /Library, where Apple's are, or in ~/Pictures outside a Photos library. A picture on the Desktop, in Documents, Downloads, iCloud Drive, another app's data or another volume could make macOS ask for access, so StableBar shows its own wallpaper instead. Previews read it once, scaled down. Drawings made offscreen never read the Mac's wallpaper. Setup's backdrop and theme tiles follow the same rule, with StableBar's own wallpaper, the same in light and dark. Over StableBar's own, a bar that follows the wallpaper shows its dark side on setup's stage: the menu bar's look comes from the desktop, which setup then doesn't show.
- **The bar follows the wallpaper through the menu bar's own look** (2026-11-23). With `bar.followsWallpaper`, a display's bar is light or dark as macOS draws that display's menu bar over its wallpaper. StableBar reads that look from its status item's window, which macOS moves to the display whose menu bar is active: public API, no permission, and no wallpaper read. Sampling the wallpaper instead would need the protected reads previews avoid, a guess at what macOS would pick, and a redraw for every wallpaper change, Space and dynamic wallpaper.
- **Text follows its background only where the theme's reads poorly** (2026-11-23). With `bar.textFollowsBackground`, a widget's content takes the other appearance only where the widget's text color reads below 3:1 on what's behind it and its other value reads better; backgrounds keep the bar's appearance. Choosing by the background's lightness alone would flip colors a theme pairs with one surface, such as text on an accent fill, and the colors of workspace cells and roles don't decide, since themes keep some faint on purpose. A theme turns it on, so themes made before it don't change, and the wallpaper counts as black or white as the menu bar's look says, for the reasons above.
- **Delete removes every version of a theme** (2026-11-19, [#853]). A gallery card stands for a whole theme, and saving a theme again adds a version, so **Delete…** uninstalls each installed version. Widget packages keep one **Uninstall…** per version ([#279]).
- **A one-color image tints rather than switching by appearance** (2026-11-19, [#853]). `"tinted": true` draws an image in its text color, which follows the bar's real color. Choosing a light or a dark image by appearance can't: a bar like Notch's stays black in light mode.
- **Sliders may take a role implicitly** (2026-11-17). Sliders with neither `filled` nor another role follow a nonempty `slider` role, so themes can style controls without owning widget layouts. Explicit `filled` choices retain their behavior, and an empty role retains the native control. Other blocks still require explicit roles.
- **Window managers own their gaps** (2026-11-13). StableBar does not turn macOS menu-bar auto-hide off to reserve space: that changes the usable screen area underneath existing window-manager gaps, and the reserved height does not follow StableBar’s height. Keep windows clear remains a correction for ordinary windows after a drag.
- **`BarStore` only wires one bar together** (2026-11-19). It had grown to 74 stored properties and 1,400 lines. Its concerns moved, unchanged, into types of their own: `ConfigurationStore` (files, edits, reload, migrations, theme trials), `WidgetScripts` (scripts, providers, events, click actions, suspension), `BarPresentation` (resolved styles), `AppWatcher` (front app and menu bar owner) and the runtime commands; the sources are grouped in folders by area. Every scene and docs image drew the same pixels before and after, and the command line printed the same. It was a restructuring, not a rewrite: existing state still moves into a `StateMachine` when a bug in it is fixed.
- **Architecture rules are tests** (2026-11-08, [#484]). `ArchitectureRulesTests` caps `BarStore`'s stored state, a number that only goes down, allows no `unowned` reference ([#493]), keeps private macOS API in `PrivateAPI.swift` ([#490]), keeps state machines free of UI frameworks, tasks, the clock and the system, and has every view draw StableBar's icon through `StableBarIcon` ([#895]): macOS can look up other artwork in two copies of the app, which changed the screens CI compares.
- **Decisions about state are state machines, in plain Swift** (2026-11-17). A feature's state is one enum with a pure `handle(event)` that returns an effect for its owner to perform, so every transition has a unit test and no combination of flags can contradict another. A trial on `WidgetPopup`'s hover and click state with The Composable Architecture took 14 more packages and a 37% slower clean build, and its store refuses an action sent while it handles another, which AppKit callbacks do. The same reducer in plain Swift was as easy to test. `SetupPlacement` is the first: setup's placement choice had three fields and a counter checked in three places to drop stale answers. Existing state moves over when a bug in it is fixed, not in a rewrite.
- **Private macOS API is a maintainer's call** (2026-11-08, [#484], [#490]). Every call lives in `PrivateAPI.swift` and is looked up at runtime, never with `@_silgen_name`, so a macOS without one turns off only its feature.
- **Menu bar items open with a click sent to MenuBarAgent** (2026-11-22, [#798]). On macOS 27, an item whose menu the bar doesn't draw gets a left click posted to MenuBarAgent's menu bar window, the private event field and call the experimental right-click uses ([#767]), instead of a press through Accessibility. SwiftUI's menu bar extras that open a window ignore the press, so their items never opened from the bar. Where no MenuBarAgent window is found, the item still gets the press. A right-click stays opt-in.
- **Now playing comes from MediaRemote, read inside perl** (2026-11-20, [#876]). The `nowPlaying` provider and the Sound details' music card read what plays in any app, as Control Center does, from the private MediaRemote framework, and send its commands there. Since macOS 15.4 MediaRemote answers only Apple's binaries, so a small library of StableBar's, built with the package and signed with the app, runs inside `/usr/bin/perl` (Resources/now-playing.pl). It looks its calls up at runtime and exits without them, which leaves the card empty. The Store's Now playing package covered only Music and Spotify through Automation.
- **The mixer checks and asks for System Audio Recording through TCC** (2026-11-20, [#876]). Per-app volume and output play each app back through a Core Audio process tap, which needs System Audio Recording, and no public call checks that permission or asks for it. Without them, a tap the person declined plays silence while it mutes the app, so the mixer uses TCC's `TCCAccessPreflight` and `TCCAccessRequest`, asks only on the first change to an app and never in setup, and turns off on a macOS without them.
- **External displays' brightness goes over DDC/CI, and dims below it with a window** (2026-11-24). The Quick toggles send VESA's brightness command through IOKit's private IOAVService calls, as MonitorControl and m1ddc do, found in `PrivateAPI.swift` and matched to their display by the maker, model and serial number the IORegistry and CoreGraphics both give. Below the darkest a display goes, and on a display that doesn't answer, a black window that clicks go through and captures leave out dims it, rather than the display's gamma table, which Night Shift and True Tone also set. The dimming goes with StableBar, so a crash never leaves a display dark.
- **The mixer's taps run in StableBar's process and wait for each app's sound** (2026-11-22, [#897]). CoreAudio plays a tap's sound on its own real-time thread, so a busy main thread can't make it stutter; a helper process would only keep apps at their volume through a crash, at the cost of another signed binary, a protocol between the two and likely a second permission. A tap's device starts with the app's sound through `tapautostart`, not when StableBar hears that the app plays, and waits again once the app stops, since a running output keeps the Mac from sleeping. Only macOS 27 is known to make a started device wait; where it runs at once instead, the tap stops it while the app is quiet and starts it itself when one of the app's processes plays. Taps stay `.muted`, so a late start cuts a sound short rather than playing it at full volume.
- **The configuration file is public API** (2026-10-26, [#337]). People's files, Store packages and themes depend on it, so changes are additive. Renaming or removing a property, or changing what it means, needs a migration, a test that loads the old form and a maintainer's OK. StableBar 0.9.0 and later, and betas built after [#337], skip the properties they don't know, with a warning, once the configuration says a newer release wrote it. Earlier versions stop at the first one. The [guide](docs/configuration.md#files-from-a-newer-stablebar) has the exact rules. Migrations of an old form run in memory on every file the loader reads, so includes and packages stay as they are, and are saved into the main file and screen setups' own bars at launch. A migration of values people can still choose skips files pinned to a release ([#223]).
- **Theme links carry only a theme** (2026-11-16, [#676]). A
  `stablebar://theme?v=1&package=…&config=…` link carries only `package.json` and `config.json`; a
  `stablebar://theme?v=2&d=…` link carries them as the strings `package` and `config` of one JSON
  payload, compressed and encoded as a bar link's `d`. Either holds at most 64 KB for the URL, 128 KB
  for the two decoded files together, 257 KB for a `v=2` payload, whose JSON escapes can double the
  files, 32 levels of JSON nesting, 16 profiles and 4,096 JSON values across both files. The first
  caps were 32 KB and 372 values, four times the values of the largest bundled theme of the time. Dot and Gloss outgrew them, so since [#873] they
  match a bar link's payload, at least twice the largest included theme. Reference expansion shares a budget of 300,000
  units and 8,000,000 bytes of reference origin paths; a link exceeding either is refused as too
  many references. Theme configuration keys are `tokens`,
  `defaults`, `popupDefaults`, `groupDefaults`, `roles`, `workspaceDefaults`, `bar`, `groups` and `profiles`. Other
  keys are refused, including legacy `customization` and `removedWidgets`; an empty `widgets` list
  is ignored. Screenshots, includes and extra files are refused. At the root and in every profile,
  `bar` must be a literal object with only `height`, `margin`, `inset`, `spacing`, `background`,
  `style`, `divider`, `notchWidth`, `notchSpacing`, `fillNotch`, `popupOffset`, `glass`, `followsWallpaper` and
  `textFollowsBackground`. Inside `bar`,
  numbers must be literal; colors may use tokens or settings with `choices`. Free-text string settings under
  `bar` are refused, and references cannot supply the `bar` object or its keys. This keeps links
  from changing the bar's edge, its offset or the menu bar's auto-hide. Current and legacy bundled
  theme IDs are reserved, and so is `classic`, which an update installs from the app ([#873]);
  Save as Theme refuses them too. A non-theme package's ID cannot be reused. An installed ID and
  version are reused only when both files match byte for byte; otherwise the author raises the
  version on the page. The app never renumbers a theme.
- **Theme links bound bar values** (2026-11-16, [#676]). Every numeric value under `bar`, including
  nested styles, states, gradients and every profile, must be a finite JSON number literal.
  References that can supply numbers through tokens, combined profiles or setting choices are
  refused. Bounds use the full property path: `bar.height` 16…100, `bar.inset` 0…100, `bar.spacing`
  0…50, `bar.margin` 0…40 and `bar.popupOffset` 0…40 (its pending control in [#664]). Within
  `bar.style` and its states, border width uses 0…6, corner radius 0…40, font size 6…40,
  horizontal/vertical padding 0…40 and opacity 0…1. `bar.glass.transparency` uses 0…1.
  `bar.divider` uses 0…6 for its width and 0…100 for its height, and, as in `bar.style`, 0…40 for its
  corner radius and 0…1 for its opacity. Gradients in `bar.background`, style backgrounds and
  `bar.divider.background` use locations 0…1 and angle 0…360. These bounds follow Settings controls. With no
  Settings controls, `bar.notchWidth` uses 0…1,000, `bar.notchSpacing` 0…100 and style offsets
  −1,000…1,000. All remaining numeric values use 0…1,000, including style height, spacing and edge
  padding. These refusals apply to links; folder themes keep the ordinary configuration rules.
- **Bar links carry only built-in and Store widgets** (2026-11-18, [#807]). A
  `stablebar://bar?v=1&d=…` link carries what a bar shows on one display, resolved: its look and
  widgets with the active profiles applied, without profiles, screen layouts or `display`. `d` is
  the JSON payload, compressed with zlib's raw DEFLATE and base64url-encoded. The app shares
  `https://stablebar.app/bar.html#v=1&d=…`, a page that opens the link, since social sites don't
  open `stablebar://` links; the fragment never reaches a server. The look is an inline theme,
  `package.json` and `config.json`, under every theme link rule and limit above, made the way
  **Save as Theme…** merges the main file's look into the current theme. It keeps only the
  theme's tokens and those the look refers to, as a token can hold a provider's header. Its ID is
  `shared-` and 8 hex digits of a hash of its files, its name the theme's with "(shared)". A
  built-in widget keeps only `id`, `type`, `role`, `position`, `icon`, `tooltip`, `style`,
  `format`, `text`, `layout`, `hoverLayout`, `overlay`, `popup`, `animation`, `workspace`,
  `group`, `priority`, `overflow`, `transition`, `expandOnHover`, `openOnHover`, `shown`,
  `hidden`, `tiles`, `details`, `hideWhenIdle`, `timeZone`, `background`, `popupBackground` and
  `tooltipBackground`. Its popup loses `onOpen` and `onClose`, and its blocks lose every block
  that runs, opens or changes something (`onClick`, `onClickField`, `open`, `openField`,
  `quitField`, `openMenuBarItem`, `selectInputSourceField`, `selectOutputDeviceField`,
  `onChange`, `onSubmit`, `onStop`, `onStar`, `set`), every `image` block and every list whose
  row is one of those. Script and custom provider widgets, widgets from folders or private
  sources, includes, templates, `environment` and `packageSources` stay behind. A Store package
  carries its ID, version, its widgets' positions and own `group`s, and its number, boolean and
  choice settings; secret and free-text settings keep the package's defaults. The recipient
  applies the same filters, installs packages from the Store, through its review when they need
  one, gets the version the Store lists (the link's while it's the newest), and leaves out
  packages the Store doesn't list. A Store version already on the recipient's bar skips the
  review and keeps its settings, with the link's over them. Without the link's look,
  a widget keeps its `group` only when the bar already has that group. Each group a widget keeps
  gets an empty entry in the main file's `groups`, so the widgets stay valid under another theme. **Use this bar**
  replaces the main file's widgets, packages, widget overrides and order, screen layouts and the
  widget changes in its profiles, and with **Every screen** the look that Save as Theme would
  move, in one undoable change; widgets that included files add stay. When the link centers
  widgets and the Mac has a notched display under a top bar, **Try on Bar** and **Use this bar**
  also write a `screens.laptop.layout` that puts them left of the notch: the bar puts them right
  of it with the right-hand ones, where a bar made on a wide monitor doesn't fit. Other screens
  keep them centered. Limits: 64 KB for the URL,
  128 KB for the decoded payload, 32 levels of JSON nesting and 4,096 JSON values. Theme links
  have had the same caps since [#873].
- **A native provider may read a macOS tool's output** (2026-11-16, [#220]). When no public API gives the data and the tool needs no permission, a native provider can run a macOS command-line tool, off the main actor and without a shell: `bluetooth` reads every connected device's battery from `system_profiler`. Apple doesn't document the tool's output keys, so a missing or renamed key leaves that value empty instead of failing the provider.
- **A package can't move another party's credentials** (2026-11-17, [#85], [#744]). A package may set the `url` of a provider, directly or in a profile, only when no file or profile gives that provider a token other than one of that package's own secrets, and no other file sets its `headers`. A package without commands can reach the Store after CI alone, so it must not point your token, a header you typed or another package's secret at its own host. In its own files, a package writes out each provider's `url` and `headers`, without `@token.` references, so StableBar needn't follow tokens to see where a request goes or what it sends. The check doesn't work out which profiles can be active together, so it can refuse an unusual but harmless setup. URLs and headers set in your own files stay free, `@token.` references included.
- **Tests keep their own time** (2026-11-08, [#491]). Code whose tests depend on time takes a clock, and the test clock lives in the repository rather than in a new dependency.
- **Blocking work stays off Swift's shared pool** (2026-11-13, [#618]). The pool has one thread per core, three on CI, and never replaces a blocked one. A slow copy or a lookup that can stall runs through `BlockingWork.run` on a GCD queue, and tests that block such work check that it does. [AGENTS.md](AGENTS.md#writing-tests) has the rule for tests.
- **Comments are for the next reader** (2026-11-10, [#533]). A comment says what the code can't, such as why it must be so, in a line or two. How the bug was found and fixed goes in the issue, the pull request and the commit message. [AGENTS.md](AGENTS.md#writing-comments) has the rule.

[#3]: https://github.com/stablebox/StableBar/issues/3
[#23]: https://github.com/stablebox/StableBar/pull/23
[#85]: https://github.com/stablebox/StableBar/issues/85
[#100]: https://github.com/stablebox/StableBar/pull/100
[#220]: https://github.com/stablebox/StableBar/issues/220
[#223]: https://github.com/stablebox/StableBar/issues/223
[#279]: https://github.com/stablebox/StableBar/issues/279
[#309]: https://github.com/stablebox/StableBar/pull/309
[#335]: https://github.com/stablebox/StableBar/issues/335
[#337]: https://github.com/stablebox/StableBar/pull/337
[#390]: https://github.com/stablebox/StableBar/pull/390
[#391]: https://github.com/stablebox/StableBar/pull/391
[#395]: https://github.com/stablebox/StableBar/pull/395
[#397]: https://github.com/stablebox/StableBar/pull/397
[#479]: https://github.com/stablebox/StableBar/pull/479
[#484]: https://github.com/stablebox/StableBar/pull/484
[#485]: https://github.com/stablebox/StableBar/pull/485
[#490]: https://github.com/stablebox/StableBar/pull/490
[#491]: https://github.com/stablebox/StableBar/pull/491
[#493]: https://github.com/stablebox/StableBar/pull/493
[#533]: https://github.com/stablebox/StableBar/pull/533
[#618]: https://github.com/stablebox/StableBar/issues/618
[#664]: https://github.com/stablebox/StableBar/issues/664
[#676]: https://github.com/stablebox/StableBar/issues/676
[#744]: https://github.com/stablebox/StableBar/pull/744
[#767]: https://github.com/stablebox/StableBar/issues/767
[#772]: https://github.com/stablebox/StableBar/issues/772
[#773]: https://github.com/stablebox/StableBar/pull/773
[#794]: https://github.com/stablebox/StableBar/pull/794
[#798]: https://github.com/stablebox/StableBar/issues/798
[#807]: https://github.com/stablebox/StableBar/issues/807
[#853]: https://github.com/stablebox/StableBar/issues/853
[#854]: https://github.com/stablebox/StableBar/issues/854
[#873]: https://github.com/stablebox/StableBar/issues/873
[#876]: https://github.com/stablebox/StableBar/issues/876
[#895]: https://github.com/stablebox/StableBar/issues/895
[#897]: https://github.com/stablebox/StableBar/issues/897
[#923]: https://github.com/stablebox/StableBar/issues/923
[#925]: https://github.com/stablebox/StableBar/issues/925
