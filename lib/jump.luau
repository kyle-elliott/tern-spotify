--!strict
-- Queue jumps: playing an upcoming queue entry. The Web API can't jump into the queue or
-- skip several tracks at once, so this restarts the playing album or playlist at the song
-- when it belongs to it, and otherwise skips forward one track at a time.

local api = require("./api")
local model = require("./model")
local session = require("./session")
local state_lib = require("./state")
local controls = require("./controls")

type State = state_lib.State

local M = {}

local SKIP_MAX = 30
local SKIP_GAP_MS = 250
local CONTEXT_TTL_MS = 5 * 60 * 1000
local CONTEXT_MAX = 2000

-- Track URIs of playlists listed for queue jumps; `tracks` is nil when Spotify won't list
-- the playlist (not the user's own) or it is too long to list.
local contexts: { [string]: { at: number, tracks: { [string]: boolean }? } } = {}

-- Answers whether track `uri` is part of context `ctx` (an album or a playlist). Unknown
-- counts as no: restarting a context at a track it doesn't hold is accepted by Spotify and
-- leaves the player with nothing playing.
local function context_has(ctx: string, uri: string, album: string?, cb: (yes: boolean) -> ())
	local kind, id = string.match(ctx, "^spotify:(%a+):(%w+)$")
	if kind == "album" then
		cb(album == ctx)
		return
	end
	if kind ~= "playlist" or id == nil then
		cb(false)
		return
	end
	local known = contexts[ctx]
	if known and tern.now() - known.at < CONTEXT_TTL_MS then
		cb(known.tracks ~= nil and known.tracks[uri] == true)
		return
	end
	local tracks: { [string]: boolean } = {}
	local count = 0
	local function page(path: string, query: { [string]: any }?)
		api.request("GET", path, { query = query }, function(res)
			if not res.ok then
				contexts[ctx] = { at = tern.now(), tracks = nil }
				cb(false)
				return
			end
			local p = model.track_page(res.data)
			for _, t in p.items do
				tracks[t.uri] = true
				count += 1
			end
			if p.next and count < CONTEXT_MAX then
				page(p.next, nil)
				return
			end
			local listed: { [string]: boolean }? = if p.next then nil else tracks
			contexts[ctx] = { at = tern.now(), tracks = listed }
			cb(listed ~= nil and listed[uri] == true)
		end)
	end
	page("/playlists/" .. id .. "/items", { limit = 50, additional_types = "track,episode" })
end

-- After a jump, the poll that follows shows the real track; say so when it isn't the one asked for.
local function verify_landing(state: State, t: model.Track)
	tern.timer(1500, function()
		local pb = session.playback()
		if pb and pb.item and pb.item.uri ~= t.uri then
			state_lib.flash(state, "Spotify is playing " .. pb.item.name .. " instead; the queue changed.", "warning")
			state.cx:render()
		end
	end)
end

-- Skips forward `count` times, one request after another. The tracks in between count as
-- skipped in the user's history, and songs the user queued are skipped too.
local function skip_forward(state: State, count: number, t: model.Track)
	if count > SKIP_MAX then
		state.skipping = false
		state_lib.flash(state, string.format("That's %d tracks ahead; skip at most %d at once.", count, SKIP_MAX), "warning")
		state.cx:render()
		return
	end
	local done = 0
	local function step()
		session.command("POST", "/me/player/next", nil, function(res)
			if not res.ok then
				state.skipping = false
				controls.report(state, res)
				return
			end
			done += 1
			if done < count then
				state_lib.flash(state, string.format("Skipping to %s… %d/%d", t.name, done, count), "info")
				state.cx:render()
				tern.timer(SKIP_GAP_MS, step)
				return
			end
			state.skipping = false
			controls.report(state, res, "Playing " .. t.name)
			verify_landing(state, t)
		end)
	end
	step()
end

-- Plays queue entry `count` (1 = next up). The Web API can't jump into the queue or skip
-- several tracks at once. When the song belongs to the album or playlist playing, the
-- context restarts at it: one request, nothing marked skipped, and songs the user queued
-- stay queued (checked live). Otherwise (a queued song, a followed playlist Spotify won't
-- list, no context) it skips forward one track at a time.
function M.skip_to(state: State, count: number, t: model.Track)
	if state.skipping then
		return
	end
	state.skipping = true
	local pb = session.playback()
	local ctx = if pb then pb.context_uri else nil
	if count == 1 or ctx == nil then
		skip_forward(state, count, t)
		return
	end
	local context: string = ctx
	state_lib.flash(state, "Jumping to " .. t.name .. "…", "info")
	state.cx:render()
	context_has(context, t.uri, t.album_uri, function(yes)
		if not yes then
			skip_forward(state, count, t)
			return
		end
		controls.start({ context_uri = context, offset = { uri = t.uri } }, function(res)
			state.skipping = false
			controls.report(state, res, if res.ok then "Playing " .. t.name else nil)
			if res.ok then
				verify_landing(state, t)
			end
		end)
	end)
end

return M
