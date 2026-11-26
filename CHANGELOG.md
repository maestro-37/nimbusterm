# Changelog

## 1.1.0 — 2026-11-26

### Passwords
- Saved passwords are unlocked with **Touch ID** once per launch instead of the
  "enter the login keychain password" dialog. Items written by another build are
  dropped at launch, so the system dialog can no longer appear.
- One password is reused for sessions with the same host/port/user (SSH, SFTP,
  tunnels, monitoring).

### SFTP
- One long-lived `sftp` session per tab: folder listings now cost a single round
  trip instead of a new process plus authentication for every command.
- Fixed the embedded editor failing to open files with
  `open local "...": No such file or directory`.
- Local list and editor share the right pane, so switching does not reset the
  split; added **Reconnect**; `Fetching…` progress lines no longer show up as
  errors.

### Tabs and panes
- Drag tabs to reorder — the strip rearranges live while dragging.
- Drop a tab onto a terminal pane to split it there.
- **4 panes** preset (tab menu, pane menu, Session menu).
- The tab strip no longer scrolls away vertically.

### Terminal
- Font size with `⌘=` / `⌘-` (9–28 pt), applied to all tabs and saved.
