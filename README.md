# MiddleMove

A tiny native macOS menu-bar app: hold the **middle mouse button** (the scroll-wheel click)
over any window and move the mouse to drag that window, from anywhere in it, not only
its title bar.

A plain middle click (press and release without moving) still works normally in every
app: closing a browser tab, opening a link in a new tab, pasting in a terminal, and so on.

- Menu-bar icon only (no Dock icon, no window).
- Works with every app that lets macOS move its windows, including while a password
  field has focus (Secure Input only hides keystrokes, not mouse buttons).
- Back/forward and other extra mouse buttons are never touched.

## How click and drag are told apart

When the middle button goes down, nobody can know yet whether it's a click or the start
of a drag, so MiddleMove holds the press back for a moment:

- **The pointer moves 6 points or more while the button is held → drag.** The window
  follows the pointer (keeping the same offset) and the app never receives the press or
  the release. If the app did receive them, a drag that starts on a browser tab would
  close that tab when you let go, because the tab moves with the window and is still
  under the pointer. That is why simpler setups never work properly.
- **The button comes up before that → click.** The held-back press and the release are
  handed to the app together, so it gets an ordinary middle click, just at release time.
  The small wobble of pressing a stiff scroll wheel still counts as a click.

Presses on things that aren't ordinary windows (the Dock, the menu bar, open menus, the
desktop) pass straight through untouched. If a window can't be moved (it's full screen,
or its app fixes its position), the press is handed back to the app as soon as you start
dragging, so that app's own middle-drag behaviour still works.

## Install

```sh
./build.sh release
ditto build/MiddleMove.app /Applications/MiddleMove.app
open /Applications/MiddleMove.app
```

Then grant Accessibility permission when asked:
**System Settings → Privacy & Security → Accessibility** → turn on **MiddleMove**.
It starts working within a second of the grant; no relaunch needed. Builds are signed
with the stable local identity `me.arabinda.codesign` (as JumpBack is), so the grant
survives rebuilds.

## Menu

- **Move Windows with Middle-Drag**: on/off switch. When off, every middle-button event
  passes through untouched.
- **Bring Dragged Window to Front**: a dragged window comes forward and its app becomes
  active, like a title-bar drag. Turn off to move background windows without focusing them.
- **Launch at Login**: registers the app with macOS (`SMAppService`).
- **Open Accessibility Settings…**

## Build

A Swift Package Manager project, no dependencies. `./build.sh [debug|release] [universal]`
builds `build/MiddleMove.app`. Requires the Xcode command-line tools; macOS 13 or later.

The icon is drawn by `tools/make_icon.swift`:

```sh
swift tools/make_icon.swift Resources
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
rm -rf Resources/AppIcon.iconset
```

## Self-test

With MiddleMove running and allowed in Accessibility, this starts a second copy that
opens a small test window, posts synthetic middle-button clicks and drags over it, checks
what the window actually received and where it ended up, writes a PASS/FAIL report and
quits. It moves the pointer for about five seconds, so don't touch the mouse meanwhile.

```sh
open -n -a /Applications/MiddleMove.app --args --self-test /tmp/MiddleMove-self-test.txt
cat /tmp/MiddleMove-self-test.txt
```

## Logs

One line per middle click or drag (which app, and how a drag ended):

```sh
/usr/bin/log show --last 10m --style compact --predicate 'subsystem == "arabinda.me.middlemove"'
```

## How it works

- A session-level `CGEventTap` on its own thread watches `otherMouseDown/Dragged/Up` for
  button 2. Holding the press means returning `nil` from the tap; a click is replayed with
  `CGEventTapPostEvent`, which delivers it in order ahead of anything the callback returns.
- The window under the pointer comes from the window server's own hit test
  (`NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`), so click-through overlays
  are skipped. Only window levels below the Dock count.
- The Accessibility window is matched by window-server ID (`_AXUIElementGetWindow`, the
  same private call Rectangle and Hammerspoon use), with an Accessibility hit test as the
  fallback for sheets and child windows. All Accessibility calls run on one background
  queue with a 1-second timeout, so a slow or hung app can never stall the mouse.
- Moves are coalesced: while one position change is in flight only the newest pointer
  position is kept, so the window never lags behind building up stale moves.
- macOS switches off any event tap that answers too slowly; MiddleMove switches its tap
  straight back on, and opts out of App Nap so it stays responsive while idle.
