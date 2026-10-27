<img src="docs/icon.png" width="128" alt="reawm icon">

# reawm

[简体中文](README.zh-Hans.md)

macOS menu bar app that turns your windows into browser-style tabs.

![reawm's tab bar switching between three windows](docs/demo.gif)

the windows on a display share one tab bar. one window shows at a time, filling the space under the bar, while the rest wait out of sight until you pick their tab. a new window joins the bar as the shown tab, or quietly behind it when its app opened it in the background. the bar has no background of its own, so it reads like a second row of the menu bar.

## using it

drag a window by its title bar onto another window's title bar (or onto a tab bar), hold still for a quarter second until the blue outline shows up, then let go. it's a tab now.

on the bar, click a tab to show it, drag tabs sideways to reorder them, or drag one off the bar to pull that window back out. hover a tab for its ×, or middle-click it to close it like in a browser. if you're dragging a file or some text, hold it over a tab for half a second and that tab opens so you can drop into it.

| keys | does |
|---|---|
| ⌥1 to ⌥8 | show that tab |
| ⌥9 | show the last tab |
| ⌥⇥ / ⌥⇧⇥ | next / previous tab |
| ⌥⌘1 to ⌥⌘8 | move the focused window to that spot in the bar |
| ⌥⌘9 | move it to the end |

⌥⌘ on a floating window puts it into the bar at that spot.

⌘-tabbing to an app shows its window. minimizing the shown window minimizes the whole bar, and clicking it in the Dock brings the bar back.

the menu bar icon has the rest: the bar on the top, left or right, a switch for "tab every window", "no tabs" for whichever app is in front, pause and quit.

## how it hides windows

macOS can't hide a single window of an app, so reawm moves hidden tabs past the bottom corner of the screen with one point left showing. quitting or pausing puts every window back where it was before it joined a bar.

windows that can't go full screen, like System Settings or Calculator, stay out of the bars and open on top the normal way. you can still drag a resizable one onto a bar yourself.

## build

```
./scripts/bundle.sh
```

needs Xcode 26 or later, which compiles the Liquid Glass icon; the script uses the first `/Applications/Xcode*.app` it finds. the app itself runs on macOS 14 or later; before macOS 26 it shows a pre-rendered copy of the icon. it builds `build/reawm.app` and signs it with your Apple Development certificate if you have one, so macOS keeps the Accessibility permission between builds. without a certificate it signs ad hoc, and you'll have to allow access again after every build.

## install

grab the zip from the [latest release](https://github.com/jxherc/reawm/releases/latest), unzip it and drag `reawm.app` into `/Applications`. if you built it yourself, copy `build/reawm.app` there instead. it runs on Apple silicon Macs.

the download isn't notarized, so macOS refuses to open it the first time. go to System Settings → Privacy & Security, scroll down to the line about reawm and click Open Anyway, or run `xattr -dr com.apple.quarantine /Applications/reawm.app` once.

then it asks for Accessibility access (System Settings → Privacy & Security → Accessibility), which it needs to move other apps' windows, and it starts working the moment you allow it.

## scripting

`open reawm://next` runs a command from a script or a launcher. the others are `prev`, `tab?n=3`, `put?n=3`, `pause` and `resume`.

## rough edges

- ⌥1 to ⌥9 are global shortcuts, so those keys stop typing ™, £ and • in every app.
- apps that grab the whole keyboard (iPhone mirroring, VMs, remote desktops) swallow the shortcuts while they're in front.
- if reawm crashes, hidden tabs stay parked in the corner until you open it again.
- `~/Library/Logs/reawm.log` records every switch and the reason for it, which helps when something looks off.

## license

MIT
