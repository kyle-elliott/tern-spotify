--!strict
-- The "Add to playlist" sheet: which playlists can take a track, its keys, and adding.

local auth = require("./auth")
local model = require("./model")
local session = require("./session")
local state_lib = require("./state")
local lists = require("./lists")
local controls = require("./controls")
local row_lib = require("./rows")

type State = state_lib.State
type Row = state_lib.Row

local M = {}

-- Opens the "Add to playlist" sheet for track `uri`.
function M.open(state: State, uri: string, name: string)
	if not (auth.has_scope("playlist-modify-public") and auth.has_scope("playlist-modify-private")) then
		state_lib.flash(state, controls.RESIGN, "warning")
		return
	end
	local picker: { uri: string, name: string, sel: string?, uid: string? } = { uri = uri, name = name, sel = nil, uid = nil }
	state.picker = picker
	if not state.playlists.loaded and not state.playlists.loading then
		lists.load_playlists(state)
	end
	session.user_id(function(id)
		picker.uid = id
		state.cx:render()
	end)
end

local function add_to_playlist(state: State, p: model.Playlist)
	local picker = state.picker
	if picker == nil then
		return
	end
	state.picker = nil
	controls.command(state, "POST", "/playlists/" .. p.id .. "/items", { body = { uris = { picker.uri } } }, "Added to " .. p.name)
end

-- Rows of the sheet: playlists the user owns or collaborates on (others can't be edited).
function M.rows_for(state: State): { Row }
	local rows: { Row } = {}
	local picker = state.picker
	if picker == nil or picker.uid == nil then
		return rows
	end
	for _, p in state.playlists.items do
		if p.owner_id == picker.uid or p.collaborative then
			table.insert(rows, {
				key = "pl_" .. p.id,
				label = p.name,
				value = if p.total then tostring(p.total) else nil,
				icon = "list",
				activate = function(s)
					add_to_playlist(s, p)
				end,
			})
		end
	end
	if state.playlists.next then
		table.insert(rows, {
			key = "more",
			label = { tern.ui.span(if state.playlists.loading then "Loading…" else "Load more playlists", "muted") },
			icon = "more",
			activate = function(s)
				lists.load_more(s, s.playlists, model.playlists)
			end,
		})
	end
	return rows
end

-- Keys while the "Add to playlist" sheet is open: it takes them all.
function M.on_key(state: State, key: Key): boolean
	local picker = state.picker
	if picker == nil then
		return false
	end
	local rows = M.rows_for(state)
	local index = 1 -- with nothing chosen yet the view shows the first row selected
	for i, r in rows do
		if r.key == picker.sel then
			index = i
		end
	end
	local n = #rows
	if key.name == "escape" or key.name == "backspace" then
		state.picker = nil
	elseif key.name == "down" or key.name == "j" then
		if n > 0 then
			picker.sel = rows[math.min(index + 1, n)].key
		end
	elseif key.name == "up" or key.name == "k" then
		if n > 0 then
			picker.sel = rows[math.max(index - 1, 1)].key
		end
	elseif key.name == "enter" then
		local row = rows[index]
		if row and row.activate then
			row.activate(state)
		end
	else
		return false
	end
	return true
end

-- The track "A" adds: the selected row's in a list tab, else what's playing.
function M.track_for_picker(state: State, rows: { Row }): (string?, string)
	if state.tab ~= "now" then
		local row = row_lib.selected_row(state, rows)
		if row and row.queue_uri then
			return row.queue_uri, if type(row.label) == "string" then row.label else "track"
		end
	end
	local pb = session.playback()
	if pb and pb.item then
		return pb.item.uri, pb.item.name
	end
	return nil, ""
end

return M
