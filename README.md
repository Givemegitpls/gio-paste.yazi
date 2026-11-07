# gio-paste.yazi

A [Yazi](https://github.com/sxyazi/yazi) plugin that pastes through **GIO** (`gio copy` / `gio move`) instead of writing through the gvfs FUSE mount.

It complements [gvfs.yazi](https://github.com/boydaihungst/gvfs.yazi): that plugin mounts and unmounts GVFS locations (MTP, SMB, SFTP, NFS, FTP, WebDAV, …), and this one makes transfers to and from those mounts actually work.

## Why

GVFS mounts are exposed as FUSE paths under `/run/user/<uid>/gvfs/`. Reading through them is fine, but **writing** is not:

- MTP: writes fail with `EIO` and may leave a 0-byte object behind (`cp`, `rsync`, `touch` — all unusable).
- SMB/SFTP/NFS: works, but goes through an extra FUSE layer.

`gio` talks to the GVFS daemon over D-Bus and bypasses FUSE entirely, so it uses the native backend for each protocol.

`gio copy` also refuses directories outright:

```console
$ gio copy some-dir /run/user/1000/gvfs/mtp:host=.../dest
gio: file:///…/some-dir: Can’t recursively copy directory
```

So the source tree is walked here and rebuilt with `gio mkdir -p` (batched) plus one `gio copy` per destination directory (batched). Merge then falls out naturally: existing directories are kept and files are overwritten.

## Requirements

- Yazi **26.9.1** (tested with this version; uses `ya.sync`, `cx.yanked`, async `Command`)
- Linux
- `glib2` / `gvfs` with the protocol packages you need (`gio` in `PATH`)
- `find` (findutils) and `test` (coreutils) — used to walk the FUSE view

## Installation

```console
$ ya pkg add Givemegitpls/gio-paste.yazi:gio-paste
```

The `:gio-paste` suffix is required: `ya pkg add` only accepts kebab-case package names, while this repository is named `gio-paste.yazi`.

Manual alternative:

```console
$ git clone https://github.com/Givemegitpls/gio-paste.yazi ~/.config/yazi/plugins/gio-paste.yazi
```

## Keybindings

Bind `p` / `P` in `~/.config/yazi/keymap.toml` — they replace Yazi's default `paste` so that GVFS destinations are handled by `gio`:

```toml
[mgr]
prepend_keymap = [
  { on = "p", run = "plugin gio-paste", desc = "Paste yanked files (gio for GVFS mounts)" },
  { on = "P", run = "plugin gio-paste -- --force", desc = "Paste yanked files, overwrite (gio for GVFS mounts)" },
]
```

Note the `--` separator: plugin flags must come as a separate positional argument string (`plugin <name> -- --force`), not as `plugin <name> --force`.

## Behaviour

Semantics mirror Yazi's own paste:

| Action | Name conflict | Directories |
| --- | --- | --- |
| `p` (no flag) | renamed to `_1`, `_2`, … (`dir_1`, `file_1.txt`), as Yazi does |
| `P` (`--force`) | overwritten (files) or merged (directories) |

- Applies when the current directory **or** at least one yanked file lives under `$XDG_RUNTIME_DIR/gvfs/`.
- Everything else — including an empty yank — falls back to Yazi's native `paste`, so local workflows are unaffected.
- Copy: the tree is planned first (`gio mkdir -p` for the directories that are missing), then files are copied per destination directory with `gio copy -p`.
- Cut: a same-mount move is done with `gio move` (a rename, instant); cross-storage moves are copy + recursive delete, because `gio remove` is not recursive.
- After a successful run: `refresh`, and for a cut also `unyank`.
- Mount URIs are resolved once per mount with `gio info` on the mount root, then the percent-encoded relative path is appended. The FUSE directory name (`mtp:host=…`, `smb-share:server=…,share=…`) is not a reversible URI encoding, so it cannot be parsed directly.
- Failures are reported as notifications with `gio`'s own stderr.

## Progress and cancellation

`gio copy -p` prints one line per finished file, so the plugin reports progress through notifications at roughly 25 %, 50 %, 75 % and 100 % of the files, plus a summary at the end.

Progress is per file: a single huge file produces no intermediate updates, because `gio` does not stream byte-level progress.

To cancel, open the task manager (`w` by default) and press `x` on the `Run plugin 'gio-paste'` task. Yazi drops the plugin's future and the running `gio` child is killed with it (`kill_on_drop`), so no orphan processes are left. There is no rollback: files copied before the cancel stay on the destination, and for a cut the source of an unfinished item is not deleted.

## Limitations

- An error in the middle of a run leaves a partially copied tree (the rest of the items still run; the summary names the first failure).
- Symlinks are followed (`find -L`, matching `gio copy`'s default behaviour).
- Special files (FIFOs, sockets, device nodes) are not supported by `gio` and will fail the run.
- Only copy/move. Remove/trash still goes through Yazi's own remover, which writes through FUSE and therefore fails on MTP.
- Only GVFS paths are special-cased; other Yazi VFS engines are left to Yazi.

## License

MIT
