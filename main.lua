-- gio-paste.yazi
--
-- Paste yanked files through GIO (`gio copy` / `gio move`) when the source or
-- the destination lives on a GVFS mount (/run/user/<uid>/gvfs/...).
--
-- Why: the gvfs FUSE path is fine for reading, but writes through it fail for
-- MTP (EIO, 0-byte objects) and are slower/less reliable for SMB/SFTP/etc.
-- `gio` talks to the GVFS daemon over D-Bus and bypasses the FUSE layer.
--
-- `gio copy` refuses directories entirely ("Can't recursively copy directory"),
-- so the source tree is walked here and recreated with `gio mkdir -p` plus one
-- `gio copy` per destination directory. That also gives merge semantics for
-- free: existing directories are left alone and files are overwritten.
--
-- Usage:
--   plugin gio-paste --          -- like `p`: conflicting names get `_1`
--   plugin gio-paste -- --force  -- like `P`: overwrite files, merge dirs
--
-- Progress is reported through notifications (each `gio copy -p` line is one
-- finished file); the run can be cancelled from the task manager (`w`), which
-- kills the running `gio` child. Local-only pastes fall back to yazi's native
-- `paste` action.

local M = {}

local uid = ya.uid()
local RUNTIME_DIR = os.getenv("XDG_RUNTIME_DIR") or ("/run/user/" .. tostring(uid))
local GVFS_ROOT = RUNTIME_DIR .. "/gvfs/"
local CHUNK = 128

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

local function basename(path)
	return (path:gsub("/+$", ""):match("([^/]+)$")) or path
end

--- Identity of the storage a path lives on; only equal GVFS mounts may be
--- renamed with `gio move` instead of copied.
local function location(path)
	if not is_gvfs(path) then
		return "local"
	end
	local mount = path:sub(#GVFS_ROOT + 1):match("^([^/]+)")
	return mount and ("gvfs:" .. mount) or nil
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

local function last_line(s)
	return (s:gsub("%s+$", ""))
end

local function run_ok(program, args)
	local out = Command(program):arg(args):output()
	return out ~= nil and out.status.success
end

local function exists(path)
	return run_ok("test", { "-e", path })
end

local function is_dir(path)
	return run_ok("test", { "-d", path })
end

local function is_link(path)
	return run_ok("test", { "-L", path })
end

local function split_nul(s)
	local parts, i = {}, 1
	while true do
		local j = s:find("\0", i, true)
		if not j then
			if i <= #s then
				parts[#parts + 1] = s:sub(i)
			end
			return parts
		end
		parts[#parts + 1] = s:sub(i, j - 1)
		i = j + 1
	end
end

--- List a directory through the FUSE view: `find` yields type and name pairs.
--- Returns an array of `{ name, kind }` where kind is `d`, `l` or anything else
--- for regular entries, or nil plus an error message.
local function list_dir(path)
	local args = { "-P", path, "-mindepth", "1", "-maxdepth", "1", "-printf", "%y\\0%f\\0" }
	local out = Command("find"):arg(args):output()
	if not out then
		return nil, "failed to spawn find"
	end
	if not out.status.success then
		return nil, last_line(out.stderr or "find failed")
	end

	local parts = split_nul(out.stdout or "")
	local entries = {}
	for i = 1, #parts - 1, 2 do
		local kind, name = parts[i], parts[i + 1]
		if name and name ~= "" then
			entries[#entries + 1] = { name = name, kind = kind }
		end
	end
	return entries
end

--- One short `gio` call (mkdir/remove/move).
local function exec(args, ctx)
	local out, err = Command("gio"):arg(args):output()
	if not out then
		return false, tostring(err or "failed to spawn gio")
	end
	if not out.status.success then
		local msg = (out.stderr or ""):gsub("%s+$", "")
		if msg == "" then
			msg = ("gio %s exited with code %s"):format(args[1], tostring(out.status.code))
		end
		return false, msg
	end
	return true
end

--- Run `gio copy -p` and count finished files from its progress lines.
--- Cancellation is handled by yazi itself: cancelling the task drops this
--- future, and the child was spawned with `kill_on_drop`, so `gio` dies with it.
local function stream(args, ctx)
	local cmd = Command("gio"):arg(args):stdout(Command.PIPED):stderr(Command.PIPED)
	local child, err = cmd:spawn()
	if not child then
		return false, tostring(err or "failed to spawn gio")
	end

	local stderr_buf = {}
	while true do
		local line, event = child:read_line()
		if not line then
			break
		end
		if event == 0 then
			ctx.tick()
		elseif event == 1 then
			stderr_buf[#stderr_buf + 1] = line
		end
	end

	local status = child:wait()
	if not status then
		return false, "gio process disappeared"
	end
	if not status.success then
		local msg = last_line(table.concat(stderr_buf, ""))
		if msg == "" then
			msg = ("gio %s exited with code %s"):format(args[1], tostring(status.code))
		end
		return false, msg
	end
	return true
end

--- `gio copy SRC... DEST_DIR`, chunked so arg lists stay bounded.
--- `--preserve` is dropped for the rest of the run if the backend rejects it.
local function copy_into(sources, dest, ctx)
	for i = 1, #sources, CHUNK do
		local args = { "copy", "-p" }
		if ctx.preserve then
			args[#args + 1] = "--preserve"
		end
		for j = i, math.min(i + CHUNK - 1, #sources) do
			args[#args + 1] = sources[j]
		end
		args[#args + 1] = dest

		local ok, err = stream(args, ctx)
		if not ok and ctx.preserve then
			ctx.preserve = false
			return copy_into(sources, dest, ctx)
		end
		if not ok then
			return false, err
		end
	end
	return true
end

local function run(prefix, items, ctx)
	for i = 1, #items, CHUNK do
		local args = {}
		for _, a in ipairs(prefix) do
			args[#args + 1] = a
		end
		for j = i, math.min(i + CHUNK - 1, #items) do
			args[#args + 1] = items[j]
		end

		local ok, err = exec(args, ctx)
		if not ok then
			return false, err
		end
	end
	return true
end

--- Unique name, mirroring yazi's `unique_file`: `dir_1`, `file_1.txt`.
local function split_stem(name, is_dir)
	if is_dir then
		return name, ""
	end
	local stem, ext = name:match("^(.*)%.([^%.]+)$")
	if stem and stem ~= "" then
		return stem, "." .. ext
	end
	return name, ""
end

local function unique_target(dest_path, name, is_dir, taken)
	local function free(candidate)
		return not taken[dest_path .. "/" .. candidate] and not exists(dest_path .. "/" .. candidate)
	end

	if free(name) then
		return name
	end

	local stem, dot_ext = split_stem(name, is_dir)
	for i = 1, 1000 do
		local candidate = is_dir and ("%s%s_%d"):format(stem, dot_ext, i) or ("%s_%d%s"):format(stem, i, dot_ext)
		if free(candidate) then
			return candidate
		end
	end
	return nil
end

local function new_plan()
	local plan = { dirs = {}, batches = {}, order = {}, links = {}, renamed = {} }
	local seen_dir, seen_batch = {}, {}

	function plan.add_dir(uri)
		if not seen_dir[uri] then
			seen_dir[uri] = true
			plan.dirs[#plan.dirs + 1] = uri
		end
	end

	function plan.add_file(src_uri, dst_dir_uri)
		local batch = plan.batches[dst_dir_uri]
		if not batch then
			batch = {}
			plan.batches[dst_dir_uri] = batch
			plan.order[#plan.order + 1] = dst_dir_uri
		end
		batch[#batch + 1] = src_uri
	end

	--- Symlinks: tried as links first, dereferenced if the backend can't hold them.
	function plan.add_link(src_uri, dst_uri)
		plan.links[#plan.links + 1] = { src_uri, dst_uri }
	end

	--- Copies that need an explicit destination path (renamed top-level items).
	function plan.add_renamed(src_uri, dst_uri)
		plan.renamed[#plan.renamed + 1] = { src_uri, dst_uri }
	end

	function plan.files()
		local n = #plan.links + #plan.renamed
		for _, batch in pairs(plan.batches) do
			n = n + #batch
		end
		return n
	end

	return plan
end

--- Recursively walk `src_path` and append work items to the plan.
--- `fresh` means the destination directory does not exist yet, so its children
--- cannot exist either and the existence probe can be skipped.
--- Symlinks to directories are dereferenced (GVFS backends such as MTP cannot
--- store links); symlinks to files are copied as links when possible.
local function walk(src_path, dst_path, plan, fresh)
	local entries, err = list_dir(src_path)
	if not entries then
		return false, ("can't read %s: %s"):format(src_path, tostring(err))
	end

	for _, ent in ipairs(entries) do
		local name = ent.name
		if name ~= "" then
			local src = src_path .. "/" .. name
			local dst = dst_path .. "/" .. name
			local link = ent.kind == "l"
			local dir = ent.kind == "d" or (link and is_dir(src))

			if dir then
				local created = fresh or not exists(dst)
				if created then
					local uri = to_uri(dst)
					if not uri then
						return false, "can't resolve GIO URI: " .. dst
					end
					plan.add_dir(uri)
				end
				local ok, werr = walk(src, dst, plan, created)
				if not ok then
					return false, werr
				end
			else
				local src_uri, dst_uri = to_uri(src), to_uri(dst_path)
				if not src_uri or not dst_uri then
					return false, "can't resolve GIO URI for " .. src
				end
				if link then
					local target_uri = to_uri(dst)
					if not target_uri then
						return false, "can't resolve GIO URI: " .. dst
					end
					plan.add_link(src_uri, target_uri)
				else
					plan.add_file(src_uri, dst_uri)
				end
			end
		end
	end
	return true
end

--- Collect a tree for deletion: files first, then directories deepest-first.
local function collect_delete(path, depth, files, dirs, max_depth)
	local entries, err = list_dir(path)
	if not entries then
		return false, ("can't read %s: %s"):format(path, tostring(err))
	end

	for _, ent in ipairs(entries) do
		local name = ent.name
		if name ~= "" then
			local child = path .. "/" .. name
			if ent.kind == "d" then
				local ok, derr = collect_delete(child, depth + 1, files, dirs, max_depth)
				if not ok then
					return false, derr
				end
			else
				local uri = to_uri(child)
				if not uri then
					return false, "can't resolve GIO URI: " .. child
				end
				files[#files + 1] = uri
			end
		end
	end

	local uri = to_uri(path)
	if not uri then
		return false, "can't resolve GIO URI: " .. path
	end
	dirs[depth] = dirs[depth] or {}
	dirs[depth][#dirs[depth] + 1] = uri
	if depth > max_depth.value then
		max_depth.value = depth
	end
	return true
end

--- `gio remove` is not recursive, so the tree is deleted leaf-first.
local function delete_tree(path, ctx)
	local files, dirs, max_depth = {}, {}, { value = 0 }
	local ok, err = collect_delete(path, 0, files, dirs, max_depth)
	if not ok then
		return false, err
	end

	ok, err = run({ "remove", "-f" }, files, ctx)
	if not ok then
		return false, err
	end
	for depth = max_depth.value, 0, -1 do
		if dirs[depth] then
			ok, err = run({ "remove", "-f" }, dirs[depth], ctx)
			if not ok then
				return false, err
			end
		end
	end
	return true
end

--- Execute one planned item: directories, then file batches, then links.
local function execute(item, ctx)
	local plan = item.plan

	local ok, err = run({ "mkdir", "-p" }, plan.dirs, ctx)
	if not ok then
		return false, err
	end

	for _, dst in ipairs(plan.order) do
		ok, err = copy_into(plan.batches[dst], dst, ctx)
		if not ok then
			return false, err
		end
	end

	for _, pair in ipairs(plan.renamed) do
		-- `gio copy` always keeps the source name, so a renamed copy is staged in
		-- a private temp directory first: copying straight into the destination
		-- would overwrite the very file the new name is being created for.
		local tmp = item.dest_path .. "/.gio-paste-tmp-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000))
		local tmp_uri = to_uri(tmp)
		if not tmp_uri then
			return false, "can't resolve GIO URI: " .. tmp
		end

		ok, err = exec({ "mkdir", "-p", tmp_uri }, ctx)
		if ok then
			ok, err = copy_into({ pair[1] }, tmp_uri, ctx)
		end
		if ok then
			ok, err = exec({ "move", (tmp_uri:gsub("/+$", "") .. "/" .. basename(pair[1])), pair[2] }, ctx)
		end
		exec({ "remove", "-f", tmp_uri }, ctx)
		if not ok then
			return false, err
		end
	end

	for _, pair in ipairs(plan.links) do
		ok, err = exec({ "copy", "-P", pair[1], pair[2] }, ctx)
		if not ok then
			-- Backend without symlink support: copy the dereferenced target.
			ok, err = copy_into({ pair[1] }, (pair[2]:gsub("/[^/]+$", "")), ctx)
		end
		if not ok then
			return false, err
		end
	end

	return true
end

function M:entry(job)
	local force = job.args and job.args.force == true

	local state = snapshot()
	if state.dest == "" then
		notify("error", "gio paste", "current directory is unknown")
		return
	end

	local dest_path = state.dest:gsub("/+$", "")
	local dest_uri = to_uri(dest_path)
	if not dest_uri then
		notify("error", "gio paste", "can't resolve GIO URI: " .. dest_path)
		return
	end

	local sources = {}
	local use_gio = is_gvfs(dest_path)
	for _, path in ipairs(state.paths) do
		local src_uri = to_uri(path)
		if not src_uri then
			notify("error", "gio paste", "can't resolve GIO URI: " .. path)
			return
		end
		use_gio = use_gio or src_uri ~= path
		sources[#sources + 1] = path
	end

	if #sources == 0 or not use_gio then
		ya.emit("paste", { force = force })
		return
	end

	local title = state.cut and "gio move" or "gio copy"
	local ctx = { title = title, preserve = true, total = 0, done = 0, step = 1 }
	function ctx.tick()
		ctx.done = ctx.done + 1
		if ctx.done % ctx.step == 0 or ctx.done == ctx.total then
			notify("info", ctx.title, ("%d/%d files (%d%%)"):format(ctx.done, ctx.total, math.floor(ctx.done * 100 / math.max(ctx.total, 1))))
		end
	end

	-- Phase 1: plan everything, so the total file count is known up front.
	notify("info", title, ("%d item(s) -> %s"):format(#sources, dest_path))

	local items, taken = {}, {}
	for _, src_path in ipairs(sources) do
		local ok, err = (function()
			if not exists(src_path) then
				return false, "can't stat " .. src_path
			end
			local src_is_dir = is_dir(src_path)
			local name = basename(src_path)
			local target_name = name

			if not force then
				target_name = unique_target(dest_path, name, src_is_dir, taken)
				if not target_name then
					return false, "can't find a free name for " .. name
				end
			end

			local target = dest_path .. "/" .. target_name
			local target_uri = to_uri(target)
			if not target_uri then
				return false, "can't resolve GIO URI: " .. target
			end
			taken[target] = true

			if state.cut and not force and location(src_path) == location(dest_path) then
				items[#items + 1] = { src = src_path, move = target_uri }
				return true
			end

			local plan = new_plan()
			local src_uri = to_uri(src_path)
			if src_is_dir then
				local created = not exists(target)
				if created then
					plan.add_dir(target_uri)
				end
				local wok, werr = walk(src_path, target, plan, created)
				if not wok then
					return false, werr
				end
			elseif is_link(src_path) then
				plan.add_link(src_uri, target_uri)
			elseif target_name == name then
				plan.add_file(src_uri, dest_uri)
			else
				plan.add_renamed(src_uri, target_uri)
			end

			items[#items + 1] = { src = src_path, plan = plan, dest_path = dest_path }
			return true
		end)()

		if not ok then
			notify("error", title, err)
			return
		end
	end

	for _, item in ipairs(items) do
		ctx.total = ctx.total + (item.plan and item.plan.files() or 0)
	end
	ctx.step = math.max(1, math.floor(ctx.total / 4))

	-- Phase 2: execute.
	local done, failed = 0, {}
	for _, item in ipairs(items) do
		local ok, err
		if item.move then
			ok, err = exec({ "move", to_uri(item.src), item.move }, ctx)
			if ok then
				done = done + 1
			end
		else
			ok, err = execute(item, ctx)
			if ok and state.cut then
				local dok, derr
				if is_dir(item.src) then
					dok, derr = delete_tree(item.src, ctx)
				else
					dok, derr = run({ "remove", "-f" }, { to_uri(item.src) }, ctx)
				end
				if dok then
					done = done + 1
				else
					ok, err = false, ("delete %s: %s"):format(basename(item.src), tostring(derr))
				end
			elseif ok then
				done = done + 1
			end
		end

		if not ok then
			failed[#failed + 1] = ("%s: %s"):format(basename(item.src), tostring(err))
		end
	end

	if state.cut and #failed == 0 then
		ya.emit("unyank", {})
	end
	ya.emit("refresh", {})

	if #failed == 0 then
		notify("info", title, ("done: %d item(s) -> %s"):format(done, dest_path))
	else
		notify("error", title, ("%d done, %d failed (first: %s)"):format(done, #failed, failed[1]))
	end
end

return M
