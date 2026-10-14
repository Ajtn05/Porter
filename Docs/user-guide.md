# Using Porter

Porter browses and copies files between a Mac and an Android phone over USB.
Requires macOS 14 or later and a USB cable that carries data.

## Connect a phone

1. Open Porter before connecting the phone.
2. Connect the phone with a data-capable USB cable and unlock it.
3. Select **File Transfer** in Android's USB options.
4. Select a storage volume in Porter's sidebar, then open a destination folder
   in the Mac or Android pane.
5. Drag files between panes, or copy with Command-C and paste with Command-V
   in the other pane.

USB debugging is optional. When an authorized USB debugging connection is
available, Porter prefers ADB for resumable, checksum-verified transfers.
Release builds bundle ADB, so no separate ADB installation is needed.

## Browser views and previews

The Mac and Android panes have separate saved view modes, sort orders,
hidden-file rules, and icon-preview toggles. Use the controls in each pane's
header to switch between list and icon view independently.

Click a pane to make it active; its header has an accent underline. File and
navigation commands target that pane. Return renames the selection, Command-Down
opens it, Command-Up opens the parent folder, and Shift-Command-N creates a folder
on either the Mac or the phone. Space or Command-Y opens Quick Look. Command-1
and Command-2 switch the active pane to icons and list, and Shift-Command-P
toggles its preview sidebar.

Command-C copies the active pane's selection to the clipboard. Navigate to a
destination folder in the other pane and use Command-V to enqueue the copy,
with the same conflict choices and preflight checks as dragging files. Files
copied in Finder can also be pasted into the Android pane. Copy and Paste are
available in the row menus, and Paste is available on the pane background.
Phone copies retain the original phone and paths across folder and selection
changes; the source phone must be connected when pasting into Porter's Mac
pane. Phone clipboard entries are usable within Porter, while Mac file URLs
can also be pasted into Finder. Text fields retain their normal clipboard
shortcuts.

On the Mac, New Folder and Rename keep the name dialog open when an operation
fails and show the reason beside the editable name. Invalid names and existing
destinations are reported. Move to Trash processes the full selection, reports
each failed item, and keeps remaining files selected for another attempt.

Each pane has independent Back and Forward buttons and Command-[ / Command-]
history. Returning to a folder restores its selection and scroll position;
refresh preserves selections of files still present. Phone history resets when
switching devices or storage volumes and commits only after a folder loads.
List view uses native, resizable Name, Date Modified, Size, and Kind columns.
Click a header to sort; each pane saves its own widths and sorting preferences.

Each pane has an optional preview sidebar showing the selected file's thumbnail
and metadata, with Quick Look and a summary for multiple selections. Its width
can be resized, and each pane's sidebar button hides or shows its own preview.
Settings saves the Mac and Android sidebar toggles independently. The Mac
sidebar previews local files directly and shares the Mac icon thumbnail cache.
Icon view also shows thumbnails for supported images, movies, PDFs, text, and documents
when macOS can generate them. Unsupported files keep their file-type icons.

MTP icon previews prefer native thumbnails supplied by the phone, including
for large originals, instead of downloading full files. Missing thumbnails keep
the file-type icon. Settings can enable slower full-file icon fallbacks, capped
at 16 MB per file and 64 MB per folder visit. Selection previews can use a
bounded full-file fallback; Quick Look explicitly loads larger files.

Fetches run one at a time and pause during directory loading and transfers.
A bounded memory cache shares images between the sidebar and icons and reuses
them across folder visits. File bytes used for fallbacks are deleted after
rendering. Refresh and device changes clear the remote image cache. Settings
also contains the preview/sidebar options, each pane's preferences, and the
menu bar button toggle; choices persist across launches.

## File Transfer mode (MTP)

MTP is the fallback for a wired phone that is in File Transfer mode but has not
enabled USB debugging. Porter implements the MTP wire protocol, USB bulk pipe,
and session layer directly. Its transactions are serialised, so a quick folder
change cannot consume another request's reply.

MTP has protocol limits that Porter exposes rather than conceals: one transfer
runs at a time; interrupted transfers restart rather than resume; device-side
checksums are unavailable, so completed transfers are marked unverified; and
modification-date preservation and free-space or file-size reports are best
effort. Enable USB debugging when resumable, checksum-verified transfers are
more important than avoiding the developer option.

macOS normally gives the MTP interface to `ptpcamerad`, and that exclusive
claim cannot be taken back. Porter starts an interface claimer with the app and
races it when the phone is attached. Start Porter before connecting the phone.
If another app wins, Porter prompts you to ask it to quit, then reconnect the
phone so Porter can claim MTP. If macOS's `ptpcamerad` wins, Porter explains
that the system service cannot be closed and prompts you to reconnect instead.
`porterctl mtp` identifies
the process holding the interface, and `porterctl mtp-watch` reports the result
of each attach. Porter only claims known Android phones, never cameras. While
it holds a phone's MTP interface, Photos and Image Capture cannot use that
phone until it is unplugged.

## Finder access

**Add to Finder** registers an experimental, read-only File Provider. Signed
Finder browsing and real-device downloads still need validation. Use Porter's
browser for transfers; keep Porter open if trying Finder access.

## Release status

Version 1.1.0 is in preparation. Distribution signing and notarization remain
pending; see the [release notes](releases/v1.1.0.md) for installation and known
limits, and the [implementation status](status.md) for validation boundaries.

[Back to Porter](../README.md)
