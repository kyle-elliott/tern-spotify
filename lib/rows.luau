--!strict
-- The rows each list tab shows (Queue, Library, Search, Devices) with what Enter does on
-- them, and moving the selection.

local model = require("./model")
local state_lib = require("./state")
local lists = require("./lists")
local controls = require("./controls")
local jump = require("./jump")

type State = state_lib.State
type Row = state_lib.Row
type Load<T> = state_lib.Load<T>

local M = {}

local DEVICE_ICONS = {
	Computer = "laptop",
	Smartphone = "vibrate",
	Speaker = "broadcast",
	TV = "monitor",
	CastVideo = "monitor",
	CastAudio = "broadcast",
	Tablet = "vibrate",
}

local function track_row(key: string, t: model.Track, activate: (State) -> ()): Row
	return {
		key = key,
		label = t.name,
		detail = if t.album then t.artists .. " · " .. t.album else t.artists,
		value = model.duration(t.duration_ms),
		icon = if t.kind == "episode" then "mic" else "wave",
		activate = activate,
		queue_uri = t.uri,
	}
end

local function header_row(key: string, text: string): Row
	return { key = key, label = { tern.ui.span(text, "strong") }, disabled = true }
end

local function more_row<T>(load: Load<T>, parse: (any) -> model.Page<T>): Row?
	if load.next == nil then
		return nil
	end
	return {
		key = "more",
		label = { tern.ui.span(if load.loading then "Loading…" else "Load more", "muted") },
		value = if load.total then string.format("%d of %d", #load.items, load.total) else nil,
		icon = "more",
		activate = function(state)
			lists.load_more(state, load, parse)
		end,
	}
end

local function queue_rows(state: State): { Row }
	local rows: { Row } = {}
	local data = state.queue.data
	if data == nil then
		return rows
	end
	if data.current then
		local r = track_row("current", data.current, function() end)
		r.activate = nil
		r.queue_uri = nil
		r.tone = "accent"
		r.icon = "play"
		r.label = { tern.ui.span(data.current.name, "strong") }
		table.insert(rows, r)
	end
	for i, t in data.items do
		local count = i
		local r = track_row("q" .. i, t, function(s)
			jump.skip_to(s, count, t)
		end)
		table.insert(rows, r)
	end
	return rows
end

local function library_rows(state: State): { Row }
	local rows: { Row } = {}
	local opened = state.opened
	if opened == nil then
		table.insert(rows, {
			key = "liked",
			label = "Liked Songs",
			icon = "sparkle",
			tone = "accent",
			activate = lists.open_liked,
		})
		for _, p in state.playlists.items do
			table.insert(rows, {
				key = "pl_" .. p.id,
				label = p.name,
				detail = p.owner,
				value = if p.total then tostring(p.total) .. " tracks" else nil,
				icon = "list",
				activate = function(s)
					lists.open_playlist(s, p)
				end,
			})
		end
		local more = more_row(state.playlists, model.playlists)
		if more then
			table.insert(rows, more)
		end
		return rows
	end
	table.insert(rows, { key = "back", label = { tern.ui.span("All playlists", "muted") }, icon = "back", activate = function(s)
		s.opened = nil
		s.sel.library = nil
	end })
	local whole = opened.playlist
	if whole then
		-- Plays the playlist as a context: works even when its items can't be listed.
		table.insert(rows, { key = "playall", label = "Play playlist", icon = "play", tone = "accent", activate = function(s)
			controls.play(s, { context_uri = whole.uri }, whole.name)
		end })
	end
	local items = opened.tracks.items
	for i, t in items do
		local index = i
		table.insert(rows, track_row("t" .. i, t, function(s)
			if opened.kind == "playlist" and opened.playlist then
				-- By URI, not position: the list skips local and unavailable entries,
				-- so its positions can differ from the playlist's.
				controls.play(s, { context_uri = opened.playlist.uri, offset = { uri = t.uri } }, t.name)
			else
				-- Liked Songs has no context URI the API accepts: play the loaded tracks from here.
				local uris = {}
				for j = index, math.min(#items, index + 99) do
					table.insert(uris, items[j].uri)
				end
				controls.play(s, { uris = uris }, t.name)
			end
		end))
	end
	local more = more_row(opened.tracks, model.track_page)
	if more then
		table.insert(rows, more)
	end
	return rows
end

local function search_rows(state: State): { Row }
	local rows: { Row } = {}
	local r = state.search.results
	if r == nil then
		return rows
	end
	if #r.tracks > 0 then
		table.insert(rows, header_row("h_tracks", "Tracks"))
		for i, t in r.tracks do
			table.insert(rows, track_row("st" .. i, t, function(s)
				controls.play_track_in_album(s, t)
			end))
		end
	end
	if #r.albums > 0 then
		table.insert(rows, header_row("h_albums", "Albums"))
		for i, a in r.albums do
			table.insert(rows, { key = "sa" .. i, label = a.name, detail = a.artists, icon = "layers", activate = function(s)
				controls.play(s, { context_uri = a.uri }, a.name)
			end })
		end
	end
	if #r.artists > 0 then
		table.insert(rows, header_row("h_artists", "Artists"))
		for i, a in r.artists do
			table.insert(rows, { key = "sr" .. i, label = a.name, icon = "user", activate = function(s)
				controls.play(s, { context_uri = a.uri }, a.name)
			end })
		end
	end
	if #r.playlists > 0 then
		table.insert(rows, header_row("h_playlists", "Playlists"))
		for i, p in r.playlists do
			table.insert(rows, { key = "sp" .. i, label = p.name, detail = p.owner, icon = "list", activate = function(s)
				controls.play(s, { context_uri = p.uri }, p.name)
			end })
		end
	end
	return rows
end

local function device_rows(state: State): { Row }
	local rows: { Row } = {}
	for i, d in state.devices.items do
		local unusable = d.id == nil or d.restricted
		table.insert(rows, {
			key = "d" .. i,
			label = if d.active then { tern.ui.span(d.name, "strong") } else d.name,
			detail = d.type .. (if d.active then " · playing here" else "") .. (if d.restricted then " · can't be controlled" else ""),
			value = if d.volume then tostring(d.volume) .. "%" else nil,
			icon = DEVICE_ICONS[d.type] or "monitor",
			tone = if d.active then "success" else nil,
			disabled = unusable,
			activate = if unusable then nil else function(s)
				controls.transfer(s, d)
			end,
		})
	end
	return rows
end

-- The rows of a list tab (none for "now").
function M.rows_for(state: State, tab: string): { Row }
	if tab == "queue" then
		return queue_rows(state)
	elseif tab == "library" then
		return library_rows(state)
	elseif tab == "search" then
		return search_rows(state)
	elseif tab == "devices" then
		return device_rows(state)
	end
	return {}
end

-- The selected row and its index, defaulting to the first enabled row.
function M.selected_row(state: State, rows: { Row }): (Row?, number?)
	local key = state.sel[state.tab]
	local first: number? = nil
	for i, r in rows do
		if not r.disabled then
			if r.key == key then
				return r, i
			end
			first = first or i
		end
	end
	if first then
		return rows[first], first
	end
	return nil, nil
end

function M.move(state: State, rows: { Row }, delta: number, to: string?)
	local _, index = M.selected_row(state, rows)
	local n = #rows
	if n == 0 then
		return
	end
	local i = index or 0
	if to == "first" then
		i, delta = 0, 1
	elseif to == "last" then
		i, delta = n + 1, -1
	end
	local step = if delta > 0 then 1 else -1
	local remaining = math.abs(delta)
	local target = index
	local j = i
	while remaining > 0 do
		j += step
		if j < 1 or j > n then
			break
		end
		if not rows[j].disabled then
			target = j
			remaining -= 1
		end
	end
	if target then
		state.sel[state.tab] = rows[target].key
	end
end

function M.row_by_key(state: State, key: string): Row?
	for _, r in M.rows_for(state, state.tab) do
		if r.key == key then
			return r
		end
	end
	return nil
end

return M
