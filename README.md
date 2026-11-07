# gio-paste.yazi

A [Yazi](https://github.com/sxyazi/yazi) plugin that pastes through **GIO** (`gio copy` / `gio move`) instead of writing through the gvfs FUSE mount.

It complements [gvfs.yazi](https://github.com/boydaihungst/gvfs.yazi) — that plugin mounts and unmounts GVFS locations (MTP, SMB, SFTP, NFS, FTP, WebDAV, …), and this one makes file transfers to and from those mounts actually work.

## Why

GVFS mounts are exposed as FUSE paths under `/run/user/<uid>/gvfs/`. Reading through them is fine, but **writing** is not:

- MTP: writes fail with `EIO` and may leave a 0-byte object behind (`cp`, `rsync`, `touch` — all unusable).
- SMB/SFTP/NFS: works, but goes through an extra FUSE layer.

`gio` talks to the GVFS daemon over D-Bus and bypasses FUSE entirely, so it uses the native backend for each protocol.

## Requirements

- Tested with Yazi **26.9.1** (uses `ya.sync`, `cx.yanked`, async `Command`)
- `glib2` / `gvfs` with the protocol packages you need (`gio` must be in `PATH`)
- Linux

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
  { on = "p", run = "plugin gio-paste", desc = "Paste yanked files (gio copy for GVFS mounts)" },
  { on = "P", run = "plugin gio-paste --force", desc = "Paste yanked files, overwrite (gio copy for GVFS mounts)" },
]
```

`--force` is accepted for symmetry with Yazi's `paste --force`; `gio copy` overwrites existing files on its own (see [Limitations](#limitations)).

## Behaviour

- Applies when the current directory **or** at least one yanked file lives under `$XDG_RUNTIME_DIR/gvfs/`.
- Yanked cut (`x`) → `gio move`; otherwise → `gio copy`.
- After a successful run: `refresh`, and for a cut also `unyank`.
- Anything else — including an empty yank — falls back to Yazi's native `paste`, so local workflows are unaffected.
- Mount URIs are resolved once per mount by running `gio info` on the mount root, then appending the percent-encoded relative path. This matters because the FUSE directory name (`mtp:host=…`, `smb-share:server=…,share=…`) is not a reversible URI encoding.
- Failures are reported as notifications with `gio`'s own stderr.

## Limitations

- `gio copy` cannot copy a directory over an existing directory (no merge), while Yazi's native paste can ask and merge. That case fails with `Can't copy directory over directory`.
- Only copy/move. Remove/trash still goes through Yazi's own remover, which writes through FUSE and therefore fails on MTP.
- Only GVFS paths are special-cased; other Yazi VFS engines are left to Yazi.

## License

MIT
