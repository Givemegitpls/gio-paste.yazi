-- gio-paste.yazi
--
-- Paste yanked files through GIO (`gio copy` / `gio move`) when the source or
-- the destination lives on a GVFS mount (/run/user/<uid>/gvfs/...).
--
-- Why: the gvfs FUSE path is fine for reading, but writes through it fail for
-- MTP (EIO, 0-byte objects) and are slower/less reliable for SMB/SFTP/etc.
-- `gio` talks to the GVFS daemon over D-Bus and bypasses the FUSE layer.
--
-- Local-only pastes fall back to yazi's native `paste` action, so behaviour is
-- unchanged unless a GVFS mount is involved.
--
-- Usage:
--   plugin gio-paste            -- same as `p`
--   plugin gio-paste --force    -- same as `P`; accepted for keymap symmetry.
--                                  `gio copy` always overwrites existing files,
--                                  but it cannot copy a directory over another
--                                  directory (merge), while yazi's native paste
--                                  can. That case reports a clear error.

local M = {}

local uid = ya.uid()
local RUNTIME_DIR = os.getenv("XDG_RUNTIME_DIR") or ("/run/user/" .. tostring(uid))
local GVFS_ROOT = RUNTIME_DIR .. "/gvfs/"

-- mount directory name -> GIO URI of its root, filled lazily
local uri_cache = {}

--- Read the editor state. `cx` only exists in the main Lua thread, so it has to
--- be touched from a `ya.sync` block; the entry job runs in a separate runner.
local snapshot = ya.sync(function()
	local cwd = cx.active.current.cwd
	local dest = cwd and tostring(cwd.path) or ""
	if dest == "" then
		return { dest = "", cut = false, paths = {} }
	end

	local paths = {}
	for _, f in pairs(cx.yanked) do
		paths[#paths + 1] = tostring(f.path)
	end
	return { dest = dest, cut = cx.yanked.is_cut == true, paths = paths }
end)

local function notify(level, title, body)
	ya.notify { title = title, content = body, level = level, timeout = 5 }
end

--- Percent-encode raw path bytes (UTF-8 is encoded byte by byte, `/` kept).
local function percent_encode(s)
	return (s:gsub("[^%w%-%._~/]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function is_gvfs(path)
	return path:sub(1, #GVFS_ROOT) == GVFS_ROOT
end

--- `uri:` field from `gio info` for the given path, or nil.
local function gio_uri_of(path)
	local out = Command("gio"):arg { "info", "-a", "standard::name", path }:output()
	if not out or not out.status.success then
		return nil
	end
	return out.stdout:match("\nuri: ([^\r\n]+)") or out.stdout:match("^uri: ([^\r\n]+)")
end

--- Map a local path (possibly inside a GVFS mount) to something `gio` accepts.
--- Paths outside GVFS mounts are returned as-is; gio treats them as `file://`.
local function to_uri(path)
	if not is_gvfs(path) then
		return path
	end

	local rest = path:sub(#GVFS_ROOT + 1)
	local mount = rest:match("^([^/]+)")
	if not mount then
		return nil
	end

	local base = uri_cache[mount]
	if not base then
		base = gio_uri_of(GVFS_ROOT .. mount)
		if not base then
			return nil
		end
		uri_cache[mount] = base
	end

	local sub = rest:sub(#mount + 1)
	if sub == "" then
		return base
	end
	return (base:gsub("/+$", "")) .. percent_encode(sub)
end

function M:entry(job)
	-- `--force` is accepted for keymap symmetry, but `gio copy` already
	-- overwrites existing files; only directory-over-directory conflicts fail.
	local force = job.args and job.args.force == true

	local state = snapshot()
	if state.dest == "" then
		notify("error", "gio paste", "current directory is unknown")
		return
	end

	local dest_path = state.dest
	local sources = {}
	local use_gio = is_gvfs(dest_path)
	for _, path in ipairs(state.paths) do
		local uri = to_uri(path)
		if not uri then
			notify("error", "gio paste", "can't resolve GIO URI: " .. path)
			return
		end
		use_gio = use_gio or uri ~= path
		sources[#sources + 1] = uri
	end

	if #sources == 0 or not use_gio then
		ya.emit("paste", { force = force })
		return
	end

	local dest_uri = to_uri(dest_path)
	if not dest_uri then
		notify("error", "gio paste", "can't resolve GIO URI: " .. dest_path)
		return
	end

	local sub = state.cut and "move" or "copy"

	local args = { sub }
	for _, uri in ipairs(sources) do
		args[#args + 1] = uri
	end
	args[#args + 1] = dest_uri

	local out, err = Command("gio"):arg(args):output()
	if not out then
		notify("error", "gio " .. sub, tostring(err or "failed to spawn gio"))
		return
	end
	if not out.status.success then
		local msg = (out.stderr or ""):gsub("%s+$", "")
		if msg == "" then
			msg = ("gio %s exited with code %s"):format(sub, tostring(out.status.code))
		end
		notify("error", "gio " .. sub, msg)
		return
	end

	if state.cut then
		ya.emit("unyank", {})
	end
	ya.emit("refresh", {})
	notify("info", "gio " .. sub, ("%d item(s) %s %s"):format(#sources, state.cut and "moved to" or "copied to", (dest_path:gsub("/+$", ""))))
end

return M
