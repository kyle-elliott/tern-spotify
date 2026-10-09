-- The session coordinator against the fake `tern`: a poll in flight when the user
-- signs out must not republish playback. Bundled by run.py.

local auth = require("./auth")
local session = require("./session")
local fake = (tern :: any).fake

local check = require("./check")
local eq = check.eq

local PLAYING = {
	is_playing = true,
	progress_ms = 1000,
	device = { id = "d", name = "Desk", type = "Computer", is_active = true, volume_percent = 30 },
	item = { uri = "spotify:track:1", name = "Song", type = "track", duration_ms = 200000, artists = { { name = "A" } }, album = { name = "Al", images = {} } },
}

local function signed_in()
	tern.kv.set("client_id", "0123456789abcdef0123456789abcdef")
	tern.kv.set("auth", { access_token = "A", refresh_token = "R", expires_at = os.time() + 3600 })
end

-- The pending GET /me/player (not /me/player/queue, which the session also asks for).
local function pending_poll(): (any, number?)
	for i, f in fake.fetches do
		if string.find(f.url, "/me/player?", 1, true) or string.sub(f.url, -#"/me/player") == "/me/player" then
			return f, i
		end
	end
	return nil, nil
end

-- Answers the pending poll with `body`.
local function answer_poll(body: any)
	local _, i = pending_poll()
	assert(i, "no pending poll")
	fake.answer(200, body, nil, i)
end

-- A block registers; updates are counted by kind.
local seen: { [string]: number } = {}
fake.panes = { { pane = 7 } }
local cx = {
	pane = 7,
	render = function() end,
	blob = function()
		return "blob"
	end,
}
session.start()
signed_in()
session.attach(cx :: any, function(kind)
	seen[kind] = (seen[kind] or 0) + 1
end)

-- First poll publishes playback.
fake.run_timers()
assert(pending_poll(), "a poll was sent")
answer_poll(PLAYING)
eq("playback loaded", session.playback() and session.playback().item and session.playback().item.name, "Song")
eq("now published", tern.kv.get("now") and tern.kv.get("now").title, "Song")

-- Sign-out (this VM) while the next poll is in flight: its answer is dropped.
fake.run_timers()
assert(pending_poll(), "second poll sent")
local before = seen.auth or 0
auth.sign_out()
eq("blocks told about sign-out", (seen.auth or 0) > before, true)
answer_poll(PLAYING)
eq("late poll ignored: playback", session.playback(), nil)
eq("late poll ignored: now", tern.kv.get("now"), nil)

-- Sign-out by another VM (the auth key deleted in kv) while a poll is in flight.
signed_in()
session.poll()
assert(pending_poll(), "third poll sent")
answer_poll(PLAYING)
eq("signed in again", session.playback() ~= nil, true)
session.poll()
assert(pending_poll(), "fourth poll sent")
tern.kv.set("auth", nil)
before = seen.auth or 0
answer_poll(PLAYING)
eq("external sign-out: playback dropped", session.playback(), nil)
eq("external sign-out: now not republished", tern.kv.get("now"), nil)
eq("external sign-out: blocks told", (seen.auth or 0) > before, true)

-- A scheduled poll that finds the tokens gone tells the blocks once.
signed_in()
session.poll()
answer_poll(PLAYING)
tern.kv.set("auth", nil)
before = seen.auth or 0
session.poll()
eq("scheduled poll after external sign-out notifies", (seen.auth or 0) > before, true)
eq("no request when signed out", pending_poll(), nil)

-- Up next: one queue read per track (or shuffle/repeat) change, none for an unchanged poll.
local function queue_requests(): { number }
	local out = {}
	for i, f in fake.fetches do
		if string.find(f.url, "/me/player/queue", 1, true) then
			table.insert(out, i)
		end
	end
	return out
end
table.clear(fake.fetches)
signed_in()
session.poll()
answer_poll(PLAYING)
eq("queue read after a new playback", #queue_requests(), 1)
local NEXT = { uri = "spotify:track:2", name = "After", type = "track", duration_ms = 1000, artists = { { name = "B" } }, album = { name = "X", images = {} } }
fake.answer(200, { currently_playing = PLAYING.item, queue = { NEXT } }, nil, queue_requests()[1])
eq("next up known", session.next_up() and session.next_up().name, "After")
session.poll()
answer_poll(PLAYING)
eq("same track: no new queue read", #queue_requests(), 0)
local OTHER = table.clone(PLAYING)
OTHER.item = NEXT
session.poll()
answer_poll(OTHER)
eq("track changed: queue read again", #queue_requests(), 1)
auth.sign_out()
fake.answer(200, { queue = { PLAYING.item } }, nil, queue_requests()[1])
eq("queue answer after sign-out ignored", session.next_up(), nil)

check.done("session")
