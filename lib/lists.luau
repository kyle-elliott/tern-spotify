--!strict
-- The player block's lists: loading pages (Queue, Library, Devices, Search) and switching
-- tabs, which loads what a tab shows.

local auth = require("./auth")
local api = require("./api")
local model = require("./model")
local session = require("./session")
local state_lib = require("./state")
local text = require("./text")

type State = state_lib.State
type Load<T> = state_lib.Load<T>

local M = {}

local SEARCH_DEBOUNCE_MS = 450

local function load_page<T>(state: State, load: Load<T>, path: string, query: { [string]: any }?, parse: (any) -> model.Page<T>, append: boolean)
	load.seq += 1
	local seq = load.seq
	load.loading, load.error = true, nil
	api.request("GET", path, { query = query }, function(res)
		if seq ~= load.seq then
			return
		end
		load.loading = false
		if res.ok then
			local page = parse(res.data)
			if append then
				for _, item in page.items do
					table.insert(load.items, item)
				end
			else
				load.items = page.items
			end
			load.next, load.total, load.loaded = page.next, page.total, true
		elseif res.status == 403 and string.find(path, "^/playlists/") then
			-- Since February 2026 Spotify lists items only of playlists you own or collaborate on.
			load.error = "Spotify only lists the tracks of playlists you own or collaborate on. Play it with “Play playlist”."
		else
			load.error = res.message or "Spotify request failed"
		end
		state.cx:render()
	end)
end

function M.load_more<T>(state: State, load: Load<T>, parse: (any) -> model.Page<T>)
	if load.next and not load.loading then
		load_page(state, load, load.next, nil, parse, true)
	end
end

function M.load_queue(state: State)
	local q = state.queue
	q.seq += 1
	local seq = q.seq
	q.loading, q.error = true, nil
	local pb = session.playback()
	q.for_uri = if pb and pb.item then pb.item.uri else nil
	api.request("GET", "/me/player/queue", nil, function(res)
		if seq ~= q.seq then
			return
		end
		q.loading = false
		if res.ok then
			q.data = model.queue(res.data)
		else
			q.error = res.message or "Could not load the queue"
		end
		state.cx:render()
	end)
end

function M.load_devices(state: State)
	load_page(state, state.devices, "/me/player/devices", nil, function(data)
		return { items = model.devices(data), next = nil, total = nil }
	end, false)
end

function M.load_playlists(state: State)
	load_page(state, state.playlists, "/me/playlists", { limit = 50 }, model.playlists, false)
end

function M.open_liked(state: State)
	local opened: state_lib.Opened = { kind = "liked", title = "Liked Songs", playlist = nil, tracks = state_lib.load() }
	state.opened = opened
	state.sel.library = nil
	load_page(state, opened.tracks, "/me/tracks", { limit = 50 }, model.track_page, false)
end

function M.open_playlist(state: State, p: model.Playlist)
	local opened: state_lib.Opened = { kind = "playlist", title = p.name, playlist = p, tracks = state_lib.load() }
	state.opened = opened
	state.sel.library = nil
	-- GET /playlists/{id}/items (the /tracks form is deprecated); at most 50 per page.
	load_page(state, opened.tracks, "/playlists/" .. p.id .. "/items", { limit = 50, additional_types = "track,episode" }, model.track_page, false)
end

function M.run_search(state: State)
	if state.search_timer then
		state.search_timer:cancel()
		state.search_timer = nil
	end
	local q = text.trim(state.fields.query.text)
	local s = state.search
	if q == "" then
		s.seq += 1
		s.results, s.ran, s.loading, s.error = nil, nil, false, nil
		return
	end
	if q == s.ran and (s.results ~= nil or s.loading) then
		return
	end
	s.seq += 1
	local seq = s.seq
	s.ran, s.loading, s.error = q, true, nil
	api.request("GET", "/search", { query = { q = q, type = "track,album,artist,playlist", limit = 8 } }, function(res)
		if seq ~= s.seq then
			return
		end
		s.loading = false
		if res.ok then
			s.results = model.search(res.data)
			state.sel.search = nil
		else
			s.error = res.message or "Search failed"
		end
		state.cx:render()
	end)
end

function M.schedule_search(state: State)
	if state.search_timer then
		state.search_timer:cancel()
	end
	state.search_timer = tern.timer(SEARCH_DEBOUNCE_MS, function()
		state.search_timer = nil
		M.run_search(state)
		state.cx:render()
	end)
end

function M.switch_tab(state: State, tab: string)
	if state.focus == "query" and tab ~= "search" then
		state_lib.set_focus(state, nil)
	end
	state.tab = tab
	if not auth.signed_in() then
		return
	end
	if tab == "queue" then
		M.load_queue(state)
	elseif tab == "library" then
		if not state.playlists.loaded and not state.playlists.loading then
			M.load_playlists(state)
		end
	elseif tab == "devices" then
		M.load_devices(state)
	elseif tab == "search" then
		if state.search.results == nil then
			state_lib.set_focus(state, "query")
		end
	end
end

function M.reload(state: State)
	local tab = state.tab
	if tab == "library" then
		local opened = state.opened
		if opened and opened.kind == "liked" then
			M.open_liked(state)
		elseif opened and opened.playlist then
			M.open_playlist(state, opened.playlist)
		else
			M.load_playlists(state)
		end
	elseif tab == "search" then
		state.search.ran = nil
		M.run_search(state)
	elseif tab == "now" then
		session.poll()
	else
		M.switch_tab(state, tab)
	end
end

function M.cycle_tab(state: State, delta: number)
	local tabs = state_lib.TABS
	local current = 1
	for i, t in tabs do
		if t.id == state.tab then
			current = i
		end
	end
	local next_index = ((current - 1 + delta) % #tabs) + 1
	M.switch_tab(state, tabs[next_index].id)
end

return M
