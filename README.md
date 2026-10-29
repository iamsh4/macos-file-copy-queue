# FileQueue

A macOS app that runs file copies and moves **one at a time** (or N at a time) instead of all at once. Built for copying to and from a NAS, where Finder's habit of running every transfer at the same time makes the whole batch slower.

## Using it

- **Right side: destination.** Drop a folder anywhere on the right side, type or paste a path (`~` works), or click **Choose…**. Star a folder to pin it to Favorites; recently used folders are listed below.
- **Left side: the queue.** Drag files or folders onto it. While you drag, the pane splits in two:
  - **upper half: Queue Copy.** Originals stay where they are.
  - **lower half: Queue Move.** Each original is removed only after its copy has finished and been verified.
- Each item keeps the destination that was set when it was queued, so you can switch destinations between drops.
- Other ways to add items:
  - Finder right-click › Services: **Queue Copy/Move with FileQueue**
  - Drop items on the Dock icon
  - Copy items in Finder (⌘C), then use **Paste Items as Copy** (⇧⌘V) or **Paste Items as Move** (⌥⇧⌘V)
  - ⌘O or ⌥⌘O to choose items in an open panel
- Reorder upcoming items by dragging them; right-click for Retry, Move to Top, Change To Copy/Move, and Show in Finder; press Delete to remove the selected items.
- **Speed:** the status bar shows the current transfer speed. The chart button next to it shows or hides a speed graph covering the last 10 minutes, with one point every 5 seconds and average/peak values; hover over it to read any point.
- **Menu bar icon:** a ring that fills as the queue progresses and turns into a checkmark when everything is done (an exclamation mark if something failed). Its menu has **Show FileQueue Window**, Pause/Resume, Paste, Settings, and Quit. Clicking the Dock icon also brings the window back.

## How transfers work

- **Built-in engine (default)** uses `copyfile(3)` with `COPYFILE_ALL`. That keeps the same metadata Finder keeps: extended attributes, Finder tags, ACLs/permissions, resource forks, dates, and symlinks. On APFS, single files are cloned. It shows live speed and ETA, and transfers can be cancelled.
- **Finder engine** (Settings) asks Finder itself to `duplicate` each item over Apple Events, so you get exactly Finder's behaviour and its progress window. Running items can't be cancelled from FileQueue.
- Either way, the copy is written under a hidden temporary name (`.filequeue-…`). It only gets its real name after an optional check that the size and file count match the source. You never see a half-copied file under the real name.
- **Moves** within one volume are a simple rename, as in Finder. Across volumes, FileQueue copies, verifies, then deletes the original (or puts it in the Trash, if you choose that in Settings).
- **If an item already exists** at the destination: Keep Both (`name 2.ext`), Replace (the old item is removed only after the new copy is complete), or Skip.
- **NAS disconnects:** if a share isn't mounted, or unmounts mid-transfer, the item goes back to waiting and the queue pauses with a banner, instead of every remaining item failing.
- Other behaviour:
  - Idle sleep is prevented while transferring.
  - The Dock icon shows a progress bar and a count of remaining items.
  - You get notifications when the queue finishes or an item fails.
  - The queue is saved, so it survives quitting and relaunching.

## Why not modify Finder's own drag and drop?

The first idea was to hold a modifier key while dragging in Finder. macOS has no public API for this: Finder's drag-and-drop can't be extended, and Finder Sync extensions can add menu items and badges but can't intercept drops. Changing Finder's behaviour would mean injecting code into Finder, which requires disabling System Integrity Protection. So FileQueue offers the closest supported options instead:

- its own two-pane window
- a Services entry in Finder's right-click menu
- ⌘C in Finder, then paste into FileQueue

## Building

Requires macOS 14+ and the Swift toolchain (the Command Line Tools are enough; Xcode isn't required).

```sh
./build.sh           # → build/FileQueue.app
./build.sh install   # also copies it to ~/Applications and refreshes the Services menu
```

With only the Command Line Tools installed, the script builds against the macOS 26 SDK. The macOS 27 SDK's SwiftUI needs a macro plugin that ships only with Xcode.

## License

MIT. See [LICENSE](LICENSE).
