--!strict
-- Playback commands from the player block (play/pause, skip, seek, volume, shuffle,
-- repeat, Like, playing a context) and how their outcome shows in the dock.

local auth = require("./auth")
local api = require("./api")
local model = require("./model")
local session = require("./session")
local state_lib = require("./state")
local lists = require("./lists")

type State = state_lib.State

local M = {}

M.SEEK_MS = 10000
M.VOLUME_STEP = 5

-- Shows a command's outcome in the dock (and moves to Devices when no device is active).
function M.report(state: State, res: api.Result, done: string?)
	if res.ok then
		if done then
			state_lib.flash(state, done, "success")
		end
	else
		state_lib.flash(state, res.message or "Spotify refused the command", if res.kind == "rate" then "warning" else "error")
		if res.kind == "no_device" then
			state.tab = "devices"
			lists.load_devices(state)
		end
	end
	state.cx:render()
end

function M.command(state: State, method: string, path: string, opts: api.Options?, done: string?)
	session.command(method, path, opts, function(res)
		M.report(state, res, done)
	end)
end

function M.toggle(state: State)
	local pb = session.playback()
	if pb and pb.playing then
		session.patch(function(p)
			p.playing = false
		end)
		M.command(state, "PUT", "/me/player/pause")
	else
		session.patch(function(p)
			p.playing = true
		end)
		M.command(state, "PUT", "/me/player/play")
	end
end

function M.skip(state: State, forward: boolean)
	M.command(state, "POST", if forward then "/me/player/next" else "/me/player/previous")
end

function M.seek(state: State, delta: number)
	local pb = session.playback()
	if pb == nil or pb.item == nil then
		return
	end
	local duration = pb.item.duration_ms
	local pos = math.clamp(session.progress() + delta, 0, math.max(duration - 1000, 0))
	session.patch(function(p)
		p.progress_ms = pos
	end)
	M.command(state, "PUT", "/me/player/seek", { query = { position_ms = math.floor(pos) } })
end

-- Sets the volume to `v` percent (0–100).
-- The active device when its volume can be set remotely; otherwise says so and answers nil.
local function volume_device(state: State): model.Device?
	local pb = session.playback()
	local dev = if pb then pb.device else nil
	if dev == nil or dev.volume == nil or not dev.supports_volume then
		state_lib.flash(state, "This device's volume can't be changed remotely.", "warning")
		return nil
	end
	return dev
end

function M.set_volume(state: State, v: number)
	if volume_device(state) == nil then
		return
	end
	local level = math.clamp(math.floor(v + 0.5), 0, 100)
	if level > 0 then
		session.set_unmute_to(nil)
	end
	session.patch(function(p)
		if p.device then
			p.device.volume = level
		end
	end)
	M.command(state, "PUT", "/me/player/volume", { query = { volume_percent = level } })
end

function M.volume(state: State, delta: number)
	local pb = session.playback()
	local dev = if pb then pb.device else nil
	-- From mute, + starts again from the remembered level.
	local from = if dev and dev.volume == 0 and delta > 0 then session.unmute_to() or 0 else (if dev then dev.volume else nil) or 0
	M.set_volume(state, from + delta)
end

-- The Web API has no mute: mute is volume 0, and unmute restores the level it had.
function M.toggle_mute(state: State)
	local dev = volume_device(state)
	if dev == nil or dev.volume == nil then
		return
	end
	if dev.volume > 0 then
		local before = dev.volume
		M.set_volume(state, 0)
		session.set_unmute_to(before)
	else
		M.set_volume(state, session.unmute_to() or 50)
	end
end

-- Seeks to `fraction` (0–1) of the current track.
function M.seek_to(state: State, fraction: number)
	local pb = session.playback()
	if pb == nil or pb.item == nil or pb.item.duration_ms <= 0 then
		return
	end
	local pos = math.floor(math.clamp(fraction, 0, 1) * pb.item.duration_ms)
	session.patch(function(p)
		p.progress_ms = pos
	end)
	M.command(state, "PUT", "/me/player/seek", { query = { position_ms = pos } })
end

function M.shuffle(state: State)
	local pb = session.playback()
	if pb == nil then
		return
	end
	local on = not pb.shuffle
	session.patch(function(p)
		p.shuffle = on
	end)
	M.command(state, "PUT", "/me/player/shuffle", { query = { state = if on then "true" else "false" } })
end

local REPEAT_NEXT = { off = "context", context = "track", track = "off" }

function M.cycle_repeat(state: State)
	local pb = session.playback()
	if pb == nil then
		return
	end
	local mode = REPEAT_NEXT[pb.repeat_mode] or "off"
	session.patch(function(p)
		p.repeat_mode = mode
	end)
	M.command(state, "PUT", "/me/player/repeat", { query = { state = mode } })
end

-- Starts playback with `body` and answers the result. While shuffle is on Spotify ignores
-- `offset` and reshuffles `uris`, so a picked track would not be the one that starts: start
-- with shuffle off, then turn it back on (the chosen track keeps playing and the rest of
-- the context is reshuffled).
function M.start(body: { [string]: any }, cb: (res: api.Result) -> ())
	local pb = session.playback()
	local picked = body.offset ~= nil or body.uris ~= nil
	if not (pb and pb.shuffle and picked) then
		session.command("PUT", "/me/player/play", { body = body }, cb)
		return
	end
	session.command("PUT", "/me/player/shuffle", { query = { state = "false" } }, function(off)
		if not off.ok then
			cb(off)
			return
		end
		session.command("PUT", "/me/player/play", { body = body }, function(res)
			-- Let the device load the new context before reshuffling it.
			tern.timer(if res.ok then 600 else 0, function()
				session.command("PUT", "/me/player/shuffle", { query = { state = "true" } }, function(on)
					cb(if res.ok then on else res)
				end)
			end)
		end)
	end)
end

function M.play(state: State, body: { [string]: any }, what: string)
	M.start(body, function(res)
		M.report(state, res, if res.ok then "Playing " .. what else nil)
	end)
end

function M.play_track_in_album(state: State, t: model.Track)
	if t.album_uri and t.kind == "track" then
		M.play(state, { context_uri = t.album_uri, offset = { uri = t.uri } }, t.name)
	else
		M.play(state, { uris = { t.uri } }, t.name)
	end
end

function M.add_to_queue(state: State, uri: string)
	session.command("POST", "/me/player/queue", { query = { uri = uri } }, function(res)
		if res.ok then
			session.refresh_next()
		end
		M.report(state, res, "Added to queue")
	end)
end

-- Opens the Spotify desktop app through its `spotify:` link (the window hands it to the OS).
function M.open_app(state: State)
	state.cx:open("spotify:")
	state_lib.flash(state, "Opening Spotify…", "info")
end

M.RESIGN = "Sign in again to allow this (Spotify needs one more permission)."

-- Likes or unlikes the current track (PUT/DELETE /me/library, February 2026 endpoints).
function M.toggle_like(state: State)
	local pb = session.playback()
	local item = if pb then pb.item else nil
	if item == nil then
		return
	end
	if not auth.has_scope("user-library-modify") then
		state_lib.flash(state, M.RESIGN, "warning")
		return
	end
	local uri = item.uri
	local was = session.liked(uri)
	local on = not was
	session.set_liked(uri, on)
	session.command(if on then "PUT" else "DELETE", "/me/library", { query = { uris = uri } }, function(res)
		if not res.ok then
			session.set_liked(uri, was)
		end
		M.report(state, res, if on then "Added to Liked Songs" else "Removed from Liked Songs")
	end)
end

function M.transfer(state: State, d: model.Device)
	if d.id == nil then
		return
	end
	local id = d.id
	M.command(state, "PUT", "/me/player", { body = { device_ids = { id }, play = true } }, "Playing on " .. d.name)
	tern.timer(1500, function()
		lists.load_devices(state)
	end)
end

return M
