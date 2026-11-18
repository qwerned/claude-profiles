# Claude Profiles

Run several Claude Desktop profiles on one Mac (personal, work, side project…) and make sure every `claude://` link lands in the right one.

Claude Desktop is an Electron app, so launching it with `--user-data-dir=<folder>` gives a fully separate profile: its own account, chats and settings. The catch is links: sign-in callbacks, connector OAuth and deep links come back as `claude://…`, and macOS hands them to whichever Claude instance it picks — often the wrong account.

Claude Profiles is a tiny menu bar helper that takes over the `claude://` scheme and routes each link:

- **one profile running** → the link goes straight there, no questions;
- **several running** → a chooser asks which profile started it;
- **chosen profile closed** → it is opened first, then gets the link.

The menu bar icon also lists your profiles, shows which are running and opens or focuses any of them, and every profile gets a global shortcut (⌃⌥1, ⌃⌥2, …).

## Install

Needs macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone <this repo> && cd claude-profiles
./install.sh
```

The script builds the helper from source, installs it to `~/Applications/Claude Profiles.app`, writes a starter config and starts it at login. Nothing outside your home folder is changed.

## Configure

Menu bar icon → **Settings…** (⌘,):

- rename a profile by clicking its name;
- click a profile's icon to pick its colour: each new profile gets the next one automatically (orange, blue, green, yellow, purple, pink, teal, graphite), and its Dock icon is repainted to match;
- click a shortcut and press new keys (Delete turns it off, Esc cancels);
- **Add Profile…** creates a new profile with its own data folder, `~/Library/Application Support/Claude-<name>`; start it once and sign in;
- **Add to Dock** makes a small launcher app for the profile (`/Applications/Claude <name>.app`) and pins it; click again to unpin;
- the − button removes a profile from the list and moves its Dock launcher to the Trash, but keeps its data folder, so nothing is lost;
- choose whether links should always ask, even with one profile running.

Changes apply immediately. The standard profile is the Claude you already have: it uses Claude's usual data folder and cannot be removed.

Everything is stored in `~/Library/Application Support/Claude Profiles/profiles.json`, which you can also edit by hand:

```json
{
  "appPath": "/Applications/Claude.app",
  "alwaysAsk": false,
  "profiles": [
    { "id": "default", "name": "Personal" },
    { "id": "work", "name": "Work", "userDataDir": "~/Library/Application Support/Claude-Work" }
  ]
}
```

- A profile without `userDataDir` is Claude's stock profile.
- `color` (optional) is one of `orange`, `blue`, `green`, `yellow`, `purple`, `pink`, `teal`, `graphite`; without it profiles take the palette in order.
- `icon` (optional) is a path to an `.app` or `.icns` that replaces the coloured Claude icon.
- `alwaysAsk: true` shows the chooser even when only one profile is open.
- `hotkey` sets a global shortcut for the profile, for example `"ctrl+opt+1"` or `"ctrl+opt+w"`; `"none"` turns it off. Without it, the first nine profiles get **⌃⌥1 … ⌃⌥9** in list order: three keys under one hand, and macOS itself assigns nothing to ⌃⌥ with a digit. Modifiers: `ctrl`, `opt`, `cmd`, `shift`; keys: letters, digits, `f1`–`f12`, `space`.

Changes to the file are picked up within a few seconds, no restart needed.

## Shortcuts

Press a profile's shortcut from anywhere:

- profile closed → it starts;
- open in the background → its window comes to the front;
- already in front → it hides, so the same keys toggle it.

The menu bar menu shows each profile's shortcut and a green dot next to the profiles that are running. If another app already owns a shortcut, the menu and Settings show it in red; pick a different one in Settings. No Accessibility permission is needed.

To start a profile by hand: `open -n -a Claude --args --user-data-dir="$HOME/Library/Application Support/Claude-Work"`.

## Commands

```sh
CP="$HOME/Applications/Claude Profiles.app/Contents/MacOS/ClaudeProfiles"
"$CP" --status            # handler owner and which profiles are running
"$CP" --preview           # show the link chooser without sending anything
"$CP" --restore-handler   # give claude:// back to Claude Desktop
"$CP" --open work         # focus the profile, or start it if closed

# A Dock-friendly app for a profile (optional .icns for its icon):
"$CP" --make-launcher work "/Applications/Claude Work.app" ~/Pictures/work.icns
```

A launcher focuses the profile when it is already running instead of starting a second copy.

## Dock setup

Use **Add to Dock** in Settings for **every** profile, including the standard one, and unpin `Claude.app` itself. From the command line:

```sh
"$CP" --make-launcher default "/Applications/Claude Personal.app" /Applications/Claude.app/Contents/Resources/electron.icns
"$CP" --make-launcher work    "/Applications/Claude Work.app"     ~/Pictures/work.icns
```

Then drag them into the Dock and remove the `Claude.app` pin.

Why: all profiles are instances of the same `Claude.app`, so its Dock icon cannot tell them apart. With two profiles open, clicking it may do nothing or bring up the wrong one. A launcher targets its profile's exact process, so each Dock icon always opens its own window. While a profile is running, macOS also shows a regular Claude icon for it in the Dock. That is expected.

## Uninstall

```sh
./uninstall.sh
```

Restores Claude Desktop as the `claude://` handler and removes the helper. Your profiles and their data are not touched.

## How it works

- Registers as the default `claude://` handler and re-claims it every few seconds, because Claude Desktop re-registers itself on launch. On quit it hands the scheme back.
- Finds running Claude processes and reads each one's exact arguments (`sysctl KERN_PROCARGS2`) to match `--user-data-dir` to a profile. If a profile matches more than one process, it is treated as unavailable, so a link is never sent to an ambiguous target.
- Delivers the link with the same `GURL` Apple Event macOS would send, addressed to the chosen process ID.

## Credits

The routing idea comes from [multi-codex-app](https://github.com/am-will/multi-codex-app), which does the same for the Codex desktop app. This is an independent implementation for Claude.

Not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic.
