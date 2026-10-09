--!strict
-- The host half's single coordinator: one poller of GET /me/player for every
-- player block on this host, the album-art cache, and the `now` record the
-- window half's status segment reads from tern.kv.
--
-- Blocks register with `attach` and are dropped when their pane disappears
-- from tern.pane.list() (blocks get no close callback). A reload drops this
-- module with its VM; host.luau calls `start` again and blocks re-attach from
-- their new `init`.

local auth = require("./auth")
local api = require("./api")
local model = require("./model")
local config = require("./config")

type Playback = model.Playback

export type Problem = { kind: string, message: string }

-- `kind` says why: "playback" (a poll or command changed it), "auth" (signed in or out),
-- "tick" (one second passed while playing), "art" (album art arrived).
export type Listener = {
	cx: BlockCx,
	update: (kind: string) -> (),
	sent: { [string]: string }, -- image URL -> blob id sent to this pane
}

type Art = { bytes: string, mime: string, used: number }

local M = {}
local ART_MAX = 12
local PUBLISH_HEARTBEAT_S = 60

local listeners: { [number]: Listener } = {}
local playback: Playback? = nil
local fetched_at = 0 -- tern.now() when `playback` was read
local loaded = false -- a poll has answered since the last sign-in
local problem: Problem? = nil
local polling = false
local epoch = 0 -- bumped by reset(); a poll answer from an older epoch is ignored
local again = false
local poll_timer: TimerHandle? = nil
local poll_due = 0
local tick_timer: TimerHandle? = nil
local rate_until = 0
local published: string? = nil
local heartbeat = 0
local art_cache: { [string]: Art } = {}
local art_loading: { [string]: boolean } = {}
local art_used = 0
local liked: { [string]: boolean } = {} -- track URI -> saved in the user's library
local liked_checking: { [string]: boolean } = {}
local user_id: string? = nil
local user_waiting: { (id: string?) -> () }? = nil
local unmute_to: number? = nil -- the volume `m` restores
local next_up: model.Track? = nil -- the first queue entry, for the Now tab's "Next:" line
local next_for: string? = nil -- the playback (track, shuffle, repeat) next_up was read for

-- Drops listeners whose pane is gone; answers whether any remain.
local function prune(): boolean
	if next(listeners) == nil then
		return false
	end
	local live: { [number]: boolean } = {}
	for _, p in tern.pane.list() do
		live[p.pane] = true
	end
	for pane in listeners do
		if not live[pane] then
			listeners[pane] = nil
		end
	end
	return next(listeners) ~= nil
end

local function notify(kind: string)
	for _, l in listeners do
		local ok, err = pcall(function()
			l.update(kind)
		end)
		if not ok then
			tern.log.warn("spotify: block update failed", err)
		end
	end
end

-- Playback position now, advanced locally since the last poll while playing.
function M.progress(): number
	local pb = playback
	if pb == nil then
		return 0
	end
	local p = pb.progress_ms
	if pb.playing then
		p += tern.now() - fetched_at
	end
	local item = pb.item
	if item and item.duration_ms > 0 then
		p = math.min(p, item.duration_ms)
	end
	return math.max(p, 0)
end

local function publish()
	local pb = playback
	local rec: { [string]: any }? = nil
	if pb and pb.item then
		rec = {
			uri = pb.item.uri,
			title = pb.item.name,
			artist = pb.item.artists,
			playing = pb.playing,
			device = if pb.device then pb.device.name else nil,
		}
	end
	local key = if rec then tern.json.encode(rec) else ""
	local t = os.time()
	if key == published and (rec == nil or t - heartbeat < PUBLISH_HEARTBEAT_S) then
		return
	end
	if rec then
		-- Lets the window half tell a live record from one a stopped host left behind.
		rec.seen = t
	end
	local ok, err = pcall(function()
		tern.kv.set(config.KEY_NOW, rec)
	end)
	if ok then
		published, heartbeat = key, t
	else
		tern.log.warn("spotify: could not publish now playing", err)
	end
end

-- Milliseconds until the next poll: quicker while a block watches and near a track's end.
local function interval(): number
	if problem and problem.kind == "network" then
		return 15000
	end
	local watching = next(listeners) ~= nil
	local pb = playback
	local ms: number
	if pb and pb.playing then
		ms = if watching then 5000 else 15000
	else
		ms = if watching then 8000 else 30000
	end
	if pb and pb.playing and pb.item and pb.item.duration_ms > 0 then
		local left = pb.item.duration_ms - M.progress()
		ms = math.min(ms, math.max(left + 800, 1000))
	end
	return ms
end

local function schedule(ms: number)
	local due = tern.now() + ms
	if poll_timer and poll_due <= due then
		return -- an earlier poll is already due
	end
	if poll_timer then
		poll_timer:cancel()
	end
	poll_due = due
	poll_timer = tern.timer(ms, function()
		poll_timer = nil
		M.poll()
	end)
end

local function ensure_tick()
	if tick_timer then
		return
	end
	local pb = playback
	if pb == nil or not pb.playing or next(listeners) == nil then
		return
	end
	tick_timer = tern.timer(1000, function()
		tick_timer = nil
		if not prune() then
			return
		end
		notify("tick")
		ensure_tick()
	end)
end

local function reset()
	-- Answers to requests started before this point are dropped (see `epoch` in M.poll).
	epoch += 1
	liked, liked_checking, user_id, user_waiting = {}, {}, nil, nil
	next_up, next_for = nil, nil
	playback, problem, loaded, again, rate_until, polling = nil, nil, false, false, 0, false
	if poll_timer then
		poll_timer:cancel()
		poll_timer = nil
	end
	if tick_timer then
		tick_timer:cancel()
		tick_timer = nil
	end
	publish()
end

local function send_art(l: Listener, src: string)
	local a = art_cache[src]
	if a == nil or l.sent[src] ~= nil then
		return
	end
	local ok, id = pcall(function()
		return l.cx:blob(a.bytes, a.mime)
	end)
	if ok then
		l.sent[src] = id
	end
end

local function evict()
	local count = 0
	local oldest: string? = nil
	local oldest_used = math.huge
	for src, a in art_cache do
		count += 1
		if a.used < oldest_used then
			oldest, oldest_used = src, a.used
		end
	end
	if count > ART_MAX and oldest then
		art_cache[oldest] = nil
	end
end

local function load_art()
	local pb = playback
	local src = if pb and pb.item then pb.item.image else nil
	if src == nil then
		return
	end
	local cached = art_cache[src]
	if cached then
		art_used += 1
		cached.used = art_used
		for _, l in listeners do
			send_art(l, src)
		end
		return
	end
	if art_loading[src] then
		return
	end
	art_loading[src] = true
	api.image(src, function(bytes, mime)
		art_loading[src] = nil
		if bytes == nil or mime == nil or string.sub(mime, 1, 6) ~= "image/" then
			return
		end
		art_used += 1
		art_cache[src] = { bytes = bytes, mime = mime, used = art_used }
		evict()
		prune()
		for _, l in listeners do
			send_art(l, src)
		end
		notify("art")
	end)
end

-- Asks once per track whether it is in the user's library (needs user-library-read).
local function check_liked(uri: string)
	if liked[uri] ~= nil or liked_checking[uri] or not auth.has_scope("user-library-read") then
		return
	end
	liked_checking[uri] = true
	local started = epoch
	api.request("GET", "/me/library/contains", { query = { uris = uri } }, function(res)
		if started ~= epoch then
			return
		end
		liked_checking[uri] = nil
		if res.ok and type(res.data) == "table" and type(res.data[1]) == "boolean" then
			liked[uri] = res.data[1]
			notify("playback")
		end
	end)
end

-- Reads what plays next (GET /me/player/queue) when the track, shuffle or repeat changed,
-- only while a block is open to show it.
local function load_next(force: boolean?)
	local pb = playback
	if pb == nil or pb.item == nil or next(listeners) == nil then
		return
	end
	local key = pb.item.uri .. "|" .. tostring(pb.shuffle) .. "|" .. pb.repeat_mode
	if key == next_for and not force then
		return
	end
	next_for = key
	local started = epoch
	api.request("GET", "/me/player/queue", nil, function(res)
		if started ~= epoch or next_for ~= key then
			return
		end
		if res.ok then
			next_up = model.queue(res.data).items[1]
			notify("playback")
		end
	end)
end

-- What plays after the current track, when known.
function M.next_up(): model.Track?
	return next_up
end

-- Reads the queue again (after the user changed it, e.g. Add to queue).
function M.refresh_next()
	load_next(true)
end

-- Whether track `uri` is liked, when known.
function M.liked(uri: string): boolean?
	return liked[uri]
end

function M.set_liked(uri: string, on: boolean?)
	liked[uri] = on :: any -- nil forgets the answer
	notify("playback")
end

-- The signed-in user's id (GET /me, asked once), for telling which playlists they can edit.
function M.user_id(cb: (id: string?) -> ())
	if user_id then
		cb(user_id)
		return
	end
	if user_waiting then
		table.insert(user_waiting, cb)
		return
	end
	local list = { cb }
	user_waiting = list
	local started = epoch
	api.request("GET", "/me", nil, function(res)
		if started ~= epoch then
			return
		end
		user_waiting = nil
		if res.ok and type(res.data) == "table" and type(res.data.id) == "string" then
			user_id = res.data.id
		end
		for _, fn in list do
			fn(user_id)
		end
	end)
end

function M.unmute_to(): number?
	return unmute_to
end

function M.set_unmute_to(v: number?)
	unmute_to = v
end

-- Polls GET /me/player now (or right after the poll in flight).
function M.poll()
	if polling then
		again = true
		return
	end
	if not auth.signed_in() then
		-- Signed out elsewhere (the window half's command, or another VM): tell the blocks.
		local was = loaded or playback ~= nil
		reset()
		if was then
			notify("auth")
		end
		return
	end
	local now = tern.now()
	if now < rate_until then
		schedule(rate_until - now)
		return
	end
	polling = true
	local started = epoch
	api.request("GET", "/me/player", { query = { additional_types = "episode" } }, function(res)
		if started ~= epoch then
			return -- reset (sign-out) since this poll started
		end
		polling = false
		if res.ok and not auth.signed_in() then
			-- Signed out while the request was in flight: don't republish playback.
			reset()
			notify("auth")
			return
		end
		if res.ok then
			playback = model.playback(res.data)
			fetched_at = tern.now()
			loaded, problem = true, nil
			load_art()
			local pb = playback
			if pb and pb.item then
				check_liked(pb.item.uri)
				load_next()
			else
				next_up, next_for = nil, nil
			end
		elseif res.kind == "signed_out" then
			reset()
			notify("auth")
			return
		elseif res.kind == "rate" then
			rate_until = tern.now() + (res.retry_after or 5) * 1000
			problem = { kind = "rate", message = res.message or "Rate limited" }
		else
			problem = { kind = res.kind or "http", message = res.message or "Spotify request failed" }
		end
		publish()
		prune()
		notify("playback")
		ensure_tick()
		if again then
			again = false
			schedule(0)
		else
			schedule(math.max(interval(), rate_until - tern.now()))
		end
	end)
end

-- Registers a player block. `update` runs after every change; it should end with cx:render().
function M.attach(cx: BlockCx, update: (kind: string) -> ())
	local l: Listener = { cx = cx, update = update, sent = {} }
	listeners[cx.pane] = l
	local pb = playback
	if pb and pb.item and pb.item.image then
		send_art(l, pb.item.image)
	end
	if auth.signed_in() and not polling and (not loaded or poll_timer == nil or poll_due - tern.now() > 1500) then
		schedule(0)
	end
	ensure_tick()
end

function M.detach(pane: number)
	listeners[pane] = nil
end

function M.playback(): Playback?
	return playback
end

function M.loaded(): boolean
	return loaded
end

function M.problem(): Problem?
	return problem
end

-- The blob id of image `src` in `pane`, once it was sent there.
function M.art(pane: number, src: string?): string?
	local l = listeners[pane]
	if l == nil or src == nil then
		return nil
	end
	return l.sent[src]
end

-- Applies an optimistic change to the current playback and redraws every block.
function M.patch(fn: (pb: Playback) -> ())
	local pb = playback
	if pb == nil then
		return
	end
	pb.progress_ms = M.progress()
	fetched_at = tern.now()
	fn(pb)
	publish()
	notify("playback")
	ensure_tick()
end

-- Sends a playback command. A poll follows shortly either way, so every block sees
-- the result and a failed command undoes any optimistic `patch`.
function M.command(method: string, path: string, opts: api.Options?, cb: (res: api.Result) -> ())
	api.request(method, path, opts, function(res)
		if res.kind == "signed_out" then
			reset()
			notify("auth")
		else
			if res.kind == "rate" then
				rate_until = tern.now() + (res.retry_after or 5) * 1000
			end
			schedule(400)
		end
		cb(res)
	end)
end

-- Starts polling when signed in, so the status segment stays current with no block open.
function M.start()
	auth.on_change(function()
		if auth.signed_in() then
			loaded = false
			schedule(0)
		else
			reset()
		end
		notify("auth")
	end)
	if auth.signed_in() then
		schedule(0)
	end
end

return M
