--!strict
-- Window half: palette commands with default keys, and the status-line
-- segment. It reads what the host half writes to tern.kv (the now-playing
-- record and the access token) and never refreshes tokens itself. kv is
-- per machine, so this only sees a session host running on this machine.

local api = require("./lib/api")
local auth = require("./lib/auth")
local config = require("./lib/config")
local text = require("./lib/text")

-- A record the host hasn't refreshed for this long is left over from a stopped host.
local STALE_S = 180
local SEGMENT_MAX = 48

local segment: { StatusSegment }? = nil
local segment_key = ""

local function read_now(): { [string]: any }?
	local ok, v = pcall(function()
		return tern.kv.get(config.KEY_NOW)
	end)
	if not ok or type(v) ~= "table" or type(v.title) ~= "string" then
		return nil
	end
	if type(v.seen) == "number" and os.time() - v.seen > STALE_S then
		return nil
	end
	return v
end

local function set_segment(seg: { StatusSegment }?)
	local key = if seg then tern.json.encode(seg) else ""
	if key ~= segment_key then
		segment, segment_key = seg, key
		tern.chrome.refresh()
	end
end

local function segment_for(now: { [string]: any }?, playing: boolean?): { StatusSegment }?
	if now == nil then
		return nil
	end
	local on = if playing == nil then now.playing == true else playing
	local artist = if type(now.artist) == "string" and now.artist ~= "" then " — " .. now.artist else ""
	return {
		{
			text = text.truncate(now.title .. artist, SEGMENT_MAX),
			icon = if on then "play" else "pause",
			tone = if on then nil else "muted",
			command = "plugin.spotify.open",
		},
	}
end

-- Sign-in opens Spotify through the window's link handling, often in a Tern browser
-- block. When that block lands on the redirect address (a page that can't load), hand
-- the address to a player block and close the browser block, so nobody has to paste.
local delivered: { [string]: boolean } = {}

local function capture_redirect(cx: WindowCx)
	if auth.pending() == nil then
		return
	end
	local player: number? = nil
	local browser: PaneInfo? = nil
	for _, p in cx.session:panes() do
		if p.block == config.BLOCK and player == nil then
			player = p.pane
		end
		local u = p.url
		if p.kind == "browser" and type(u) == "string" and string.sub(u, 1, #config.REDIRECT_URI) == config.REDIRECT_URI then
			if string.find(u, "[?&]code=") or string.find(u, "[?&]error=") then
				browser = p
			end
		end
	end
	if player == nil or browser == nil then
		return
	end
	local u = browser.url :: string
	if delivered[u] then
		return
	end
	delivered[u] = true
	cx.session:event(player, { ev = "action", id = "main", act = "redirect", value = u })
	cx.layout:close(browser.pane)
	cx.layout:focus(player)
end

local function watch(cx: WindowCx?)
	local ok, err = pcall(function()
		set_segment(segment_for(read_now()))
		if cx then
			capture_redirect(cx)
		end
	end)
	if not ok then
		tern.log.warn("spotify: window watch failed", err)
	end
	tern.timer(1000, watch)
end

tern.chrome.status(function(_pane)
	return segment
end)

---------------------------------------------------------------------------
-- Commands

-- The player block type isn't defined where this window's panes run.
local function unavailable(cx: WindowCx)
	cx:toast("error", "Spotify is not available on this host", "Install the plugin where the session runs")
end

local function player_pane(cx: WindowCx): number?
	for _, p in cx.session:panes() do
		if p.block == config.BLOCK then
			return p.pane
		end
	end
	return nil
end

local function open_player(cx: WindowCx)
	local pane = player_pane(cx)
	if pane then
		cx.layout:focus(pane)
		return
	end
	if cx:new_block(config.BLOCK, nil, "beside") == nil then
		unavailable(cx)
	end
end

-- Sends a control request with the token the host keeps fresh; never refreshes.
local function control(cx: WindowCx, method: string, path: string, done: (() -> ())?)
	local t = auth.tokens()
	if t == nil then
		cx:toast("info", "Spotify: not signed in", "Run “Open Spotify” to sign in")
		return
	end
	if t.expires_at <= os.time() + 5 then
		cx:toast("info", "Spotify: sign-in needs refreshing", "Open the Spotify player to reconnect")
		return
	end
	api.send(t.access_token, method, path, nil, function(res, fresh)
		-- `fresh` is the callback's own cx; the command's `cx` is only valid while it runs
		-- (it still is when send fails synchronously, which is when `fresh` is nil).
		local tcx = fresh or cx
		if res.ok then
			if done then
				done()
			end
		elseif res.kind == "auth" then
			tcx:toast("info", "Spotify: sign-in expired", "Open the Spotify player to reconnect")
		else
			tcx:toast(if res.kind == "rate" then "info" else "error", "Spotify", res.message)
		end
	end)
end

tern.command({
	id = "open",
	title = "Open Spotify",
	icon = "wave",
	keys = { "ctrl+alt+shift+m" },
	run = open_player,
})

-- Floats the player as a picture-in-picture in the bottom-right corner, or docks a floating
-- one back into the layout (opening a player first when none is open). A small floating
-- player draws the compact Now layout.
tern.command({
	id = "float",
	title = "Spotify: Open floating player / dock it",
	icon = "pip",
	run = function(cx)
		local pane = player_pane(cx) or cx:new_block(config.BLOCK, nil, "beside")
		if pane == nil then
			unavailable(cx)
			return
		end
		local target: number = pane
		local info = cx.session:pane(target)
		local ok, err
		if info and info.floating then
			ok, err = cx.layout:dock(target)
		else
			ok, err = cx.layout:float(target, nil, "br")
		end
		if not ok then
			cx:toast("error", "Spotify: couldn't move the player", err)
		end
	end,
})

local function signed_in(_cx: WindowCx): boolean
	return auth.tokens() ~= nil
end

tern.command({
	id = "play_pause",
	title = "Spotify: Play/Pause",
	icon = "play",
	keys = { "ctrl+alt+shift+space" },
	available = signed_in,
	run = function(cx)
		local now = read_now()
		local playing = now ~= nil and now.playing == true
		control(cx, "PUT", if playing then "/me/player/pause" else "/me/player/play", function()
			-- Show the change now; the host's next poll publishes the real state.
			set_segment(segment_for(now, not playing))
		end)
	end,
})

tern.command({
	id = "next",
	title = "Spotify: Next track",
	icon = "frame-next",
	keys = { "ctrl+alt+shift+f9" },
	available = signed_in,
	run = function(cx)
		control(cx, "POST", "/me/player/next")
	end,
})

tern.command({
	id = "previous",
	title = "Spotify: Previous track",
	icon = "frame-prev",
	keys = { "ctrl+alt+shift+f7" },
	available = signed_in,
	run = function(cx)
		control(cx, "POST", "/me/player/previous")
	end,
})

tern.command({
	id = "sign_out",
	title = "Spotify: Sign out",
	icon = "log-out",
	available = signed_in,
	run = function(cx)
		-- The host owns the tokens: hand the sign-out to a player block (the dock's Sign out
		-- action), so no window ever writes tern.kv and races the host's writes.
		local signout = { ev = "action", id = "dock.status.signout", act = "signout" }
		local pane = player_pane(cx)
		if pane then
			cx.session:event(pane, signout)
			set_segment(nil)
			return
		end
		local opened = cx:new_block(config.BLOCK, nil, "beside")
		if opened == nil then
			unavailable(cx)
			return
		end
		local target: number = opened
		-- Give the new block time to start before it receives the action.
		tern.timer(1500, function(fresh)
			if fresh then
				fresh.session:event(target, signout)
			end
			set_segment(nil)
		end)
	end,
})

watch()
