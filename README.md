# Claude Profiles

Run several Claude Desktop profiles on one Mac (personal, work, side project…) and make sure every `claude://` link lands in the right one.

Claude Desktop is an Electron app, so launching it with `--user-data-dir=<folder>` gives a fully separate profile: its own account, chats and settings. The catch is links: sign-in callbacks, connector OAuth and deep links come back as `claude://…`, and macOS hands them to whichever Claude instance it picks — often the wrong account.

Claude Profiles is a tiny menu bar helper that takes over the `claude://` scheme and routes each link:

- **one profile running** → the link goes straight there, no questions;
- **several running** → a chooser asks which profile started it;
- **chosen profile closed** → it is opened first, then gets the link.

The menu bar icon also lists your profiles, shows which are running and opens or focuses any of them.

## Install

Needs macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone <this repo> && cd claude-profiles
./install.sh
```

The script builds the helper from source, installs it to `~/Applications/Claude Profiles.app`, writes a starter config and starts it at login. Nothing outside your home folder is changed.

## Configure

`~/Library/Application Support/Claude Profiles/profiles.json` (menu bar icon → *Edit Profiles…*):

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
- `icon` (optional) is a path to an `.app` or image used in the chooser.
- `alwaysAsk: true` shows the chooser even when only one profile is open.

To start a profile by hand: `open -n -a Claude --args --user-data-dir="$HOME/Library/Application Support/Claude-Work"`.

## Commands

```sh
CP="$HOME/Applications/Claude Profiles.app/Contents/MacOS/ClaudeProfiles"
"$CP" --status            # handler owner and which profiles are running
"$CP" --preview           # show the chooser without sending anything
"$CP" --restore-handler   # give claude:// back to Claude Desktop
"$CP" --open work         # focus the profile, or start it if closed

# A Dock-friendly app for a profile (optional .icns for its icon):
"$CP" --make-launcher work "/Applications/Claude Work.app" ~/Pictures/work.icns
```

A launcher focuses the profile when it is already running instead of starting a second copy.

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
