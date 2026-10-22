# Installing Earl

You need a Mac with Apple silicon and macOS 26. No admin rights needed.

## One command

Open **Terminal** (⌘Space, type Terminal) and paste:

    curl -fsSL https://github.com/IhsenBouallegue/earl/releases/latest/download/install.sh | bash

It downloads the latest Earl, puts it in the **Applications** folder inside your
home folder and opens it. Earl's setup window takes it from there. Earl lives in
the menu bar (the little face at the top of the screen) and updates itself.

Why Terminal: Earl isn't notarized by Apple (that costs a developer account), so
macOS blocks a copy downloaded with a browser. A download made by `curl` isn't
marked that way, so there is nothing to click through. The script checks the
download is signed with Earl's certificate before it installs it.

## Without Terminal

1. Download **Earl-….zip** from the [latest release](https://github.com/IhsenBouallegue/earl/releases/latest) and unzip it.
2. In Finder, press ⇧⌘H (your home folder), make a folder **Applications** if
   there isn't one, and move **Earl** into it.
3. Double-click Earl and click **Done**. Then open System Settings → Privacy &
   Security, scroll down and click **Open Anyway** next to Earl.

## Updating and removing

Earl checks for updates by itself and asks before installing one. To remove it,
drag Earl out of the Applications folder; your meetings stay in the **Meetings**
folder in your home folder.

Before recording a call, tell the others you're taking notes.
