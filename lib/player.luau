--!strict
-- The `spotify.player` block definition: keys, view events, and the block's lifecycle.
-- What the keys and events do lives in the neighbouring modules; rendering in lib/view.

local auth = require("./auth")
local field = require("./field")
local session = require("./session")
local state_lib = require("./state")
local view = require("./view")
local signin = require("./signin")
local lists = require("./lists")
local controls = require("./controls")
local row_lib = require("./rows")
local picker = require("./picker")

type State = state_lib.State

local M = {}

local function on_field_key(state: State, name: string, key: Key): boolean
	local f = state.fields[name]
	if key.name == "enter" then
		if name == "query" then
			lists.run_search(state)
			state_lib.set_focus(state, nil)
		elseif name == "client_id" then
			signin.submit_client(state)
		elseif name == "redirect" then
			signin.submit_redirect(state)
		end
		return true
	elseif key.name == "escape" or key.name == "tab" or (name == "query" and key.name == "down") then
		state_lib.set_focus(state, nil)
		if name == "query" and key.name == "down" then
			state.sel.search = nil
			row_lib.move(state, row_lib.rows_for(state, "search"), 0, "first")
		end
		return true
	end
	if not field.key(f, key) then
		return false
	end
	if name == "query" then
		lists.schedule_search(state)
	elseif key.name == "paste" then
		-- A pasted Client ID or redirect address needs no Enter.
		if name == "client_id" and #(string.match(f.text, "^%s*(%x+)%s*$") or "") == 32 then
			signin.submit_client(state)
		elseif name == "redirect" and (string.find(f.text, "code=", 1, true) or string.find(f.text, "error=", 1, true)) then
			signin.submit_redirect(state)
		end
	end
	return true
end

local function on_key(state: State, key: Key): boolean
	if state.focus then
		return on_field_key(state, state.focus, key)
	end

	if not auth.signed_in() then
		local target = signin.field_for_step()
		if key.name == "paste" and target then
			state_lib.set_focus(state, target)
			return on_field_key(state, target, key)
		elseif key.name == "enter" then
			if target then
				state_lib.set_focus(state, target)
			else
				signin.begin_signin(state)
			end
			return true
		end
		return false
	end

	if key.ctrl or key.meta then
		return false
	end
	local name, text = key.name, key.text
	local rows = row_lib.rows_for(state, state.tab)

	if state.picker then
		return picker.on_key(state, key)
	end

	if name == "space" then
		controls.toggle(state)
	elseif name == "n" then
		controls.skip(state, true)
	elseif name == "p" then
		controls.skip(state, false)
	elseif name == "right" and (state.tab == "now" or key.shift) then
		if key.shift then
			controls.skip(state, true)
		else
			controls.seek(state, controls.SEEK_MS)
		end
	elseif name == "left" and (state.tab == "now" or key.shift) then
		if key.shift then
			controls.skip(state, false)
		else
			controls.seek(state, -controls.SEEK_MS)
		end
	elseif text == "+" or text == "=" then
		controls.volume(state, controls.VOLUME_STEP)
	elseif text == "-" or text == "_" then
		controls.volume(state, -controls.VOLUME_STEP)
	elseif text == "A" then
		local uri, title = picker.track_for_picker(state, rows)
		if uri == nil then
			return false
		end
		picker.open(state, uri, title)
	elseif name == "h" then
		controls.toggle_like(state)
	elseif name == "m" then
		controls.toggle_mute(state)
	elseif name == "o" then
		controls.open_app(state)
	elseif name == "s" then
		controls.shuffle(state)
	elseif name == "r" then
		controls.cycle_repeat(state)
	elseif text and string.match(text, "^[1-5]$") then
		lists.switch_tab(state, state_lib.TABS[tonumber(text) :: number].id)
	elseif name == "tab" then
		lists.cycle_tab(state, if key.shift then -1 else 1)
	elseif text == "/" then
		lists.switch_tab(state, "search")
		state_lib.set_focus(state, "query")
	elseif name == "f5" then
		lists.reload(state)
	elseif name == "down" or name == "j" then
		row_lib.move(state, rows, 1)
	elseif name == "up" or name == "k" then
		row_lib.move(state, rows, -1)
	elseif name == "page_down" then
		row_lib.move(state, rows, 10)
	elseif name == "page_up" then
		row_lib.move(state, rows, -10)
	elseif name == "home" or text == "g" then
		row_lib.move(state, rows, 0, "first")
	elseif name == "end" or text == "G" then
		row_lib.move(state, rows, 0, "last")
	elseif name == "enter" then
		if state.tab == "now" then
			controls.toggle(state)
		else
			local row = row_lib.selected_row(state, rows)
			if row and row.activate then
				row.activate(state)
			end
		end
	elseif name == "a" then
		local row = row_lib.selected_row(state, rows)
		if row and row.queue_uri then
			controls.add_to_queue(state, row.queue_uri)
		else
			return false
		end
	elseif (name == "escape" or name == "backspace") and state.tab == "library" and state.opened then
		state.opened = nil
		state.sel.library = nil
	elseif name == "escape" and state.flash then
		state.flash = nil
	else
		return false
	end
	return true
end

local function on_event(state: State, ev: UiEvent)
	if ev.ev == "select" and ev.id == "main.tabs" then
		lists.switch_tab(state, tostring(ev.item))
		return
	end
	if (ev.ev == "select" or ev.ev == "activate") and ev.id == "main.pick" and type(ev.item) == "string" then
		local key = string.sub(ev.item, #"main.pick." + 1)
		for _, r in picker.rows_for(state) do
			if r.key == key and state.picker then
				state.picker.sel = key
				if ev.ev == "activate" and r.activate then
					r.activate(state)
				end
			end
		end
		return
	end
	if (ev.ev == "select" or ev.ev == "activate") and type(ev.id) == "string" and type(ev.item) == "string" then
		local prefix = ev.id .. "."
		if string.sub(ev.item, 1, #prefix) ~= prefix then
			return
		end
		local key = string.sub(ev.item, #prefix + 1)
		local row = row_lib.row_by_key(state, key)
		if row == nil or row.disabled then
			return
		end
		state.sel[state.tab] = key
		if ev.ev == "activate" and row.activate then
			row.activate(state)
		end
		return
	end
	if ev.ev == "focus" then
		for name, id in state_lib.FIELD_IDS do
			if ev.id == id then
				state_lib.set_focus(state, name)
			end
		end
		return
	end
	if ev.ev ~= "action" then
		return
	end
	local act, value = ev.act, ev.value
	if act == "toggle" then
		controls.toggle(state)
	elseif act == "next" then
		controls.skip(state, true)
	elseif act == "prev" then
		controls.skip(state, false)
	elseif act == "shuffle" then
		controls.shuffle(state)
	elseif act == "repeat" then
		controls.cycle_repeat(state)
	elseif act == "vol" then
		local level = tonumber(value)
		if level then
			controls.set_volume(state, level) -- a segment of the volume bar
		else
			controls.volume(state, if value == "up" then controls.VOLUME_STEP else -controls.VOLUME_STEP)
		end
	elseif act == "seek" then
		controls.seek(state, if value == "fwd" then controls.SEEK_MS else -controls.SEEK_MS)
	elseif act == "seekto" and tonumber(value) then
		controls.seek_to(state, (tonumber(value) :: number) / 1000) -- a segment of the progress bar, in ‰
	elseif act == "openapp" then
		controls.open_app(state)
	elseif act == "mute" then
		controls.toggle_mute(state)
	elseif act == "like" then
		controls.toggle_like(state)
	elseif act == "addto" then
		local pb = session.playback()
		if pb and pb.item then
			picker.open(state, pb.item.uri, pb.item.name)
		end
	elseif act == "close_picker" then
		state.picker = nil
	elseif act == "reauth" then
		-- Grants the newer permissions: a fresh sign-in (the Client ID is kept).
		auth.sign_out()
		signin.begin_signin(state)
	elseif act == "tab" and type(value) == "string" then
		lists.switch_tab(state, value)
	elseif act == "reload" then
		lists.reload(state)
	elseif act == "redirect" then
		-- Sent by the window half when a browser block reached the redirect address.
		if type(value) == "string" and not auth.signed_in() and auth.pending() and not state.signin.busy then
			state.fields.redirect = field.new(value)
			signin.submit_redirect(state)
		end
	elseif act == "signout" then
		auth.sign_out()
	elseif act == "dismiss" then
		state.flash = nil
	else
		signin.signin_action(state, act)
	end
end

local def: BlockDef<State> = {
	init = function(cx, _args, saved)
		local state = state_lib.new(cx)
		if type(saved) == "table" then
			if type(saved.tab) == "string" then
				for _, t in state_lib.TABS do
					if t.id == saved.tab then
						state.tab = saved.tab
					end
				end
			end
			if type(saved.query) == "string" then
				state.fields.query = field.new(saved.query)
			end
		end
		session.attach(cx, function(kind)
			if kind == "auth" then
				if auth.signed_in() then
					if state.focus == "client_id" or state.focus == "redirect" then
						state.focus = nil
					end
					state.signin = {}
					lists.switch_tab(state, state.tab)
				else
					state.queue = { data = nil, for_uri = nil, loading = false, error = nil, seq = state.queue.seq + 1 }
					state.devices, state.playlists, state.opened = state_lib.load(), state_lib.load(), nil
					state.search.results, state.search.ran = nil, nil
					state_lib.set_focus(state, signin.field_for_step())
				end
			elseif kind == "playback" and state.tab == "queue" then
				local pb = session.playback()
				local uri = if pb and pb.item then pb.item.uri else nil
				if uri ~= state.queue.for_uri and not state.queue.loading then
					lists.load_queue(state)
				end
			elseif kind == "tick" and state.tab ~= "now" then
				return -- progress only shows on Now playing
			end
			cx:render()
		end)
		if auth.signed_in() then
			lists.switch_tab(state, state.tab)
			if state.tab == "search" and state.fields.query.text ~= "" then
				lists.run_search(state)
			end
		else
			state_lib.set_focus(state, signin.field_for_step())
		end
		return state
	end,

	title = function(state)
		local pb = session.playback()
		if auth.signed_in() and pb and pb.item then
			return (if pb.playing then "▶ " else "❚❚ ") .. pb.item.name .. " — " .. pb.item.artists
		end
		return "Spotify"
	end,

	view = function(state, cx)
		local rows = row_lib.rows_for(state, state.tab)
		local selected = row_lib.selected_row(state, rows)
		return view.render(state, cx, rows, if selected then selected.key else nil, signin.step(), picker.rows_for(state))
	end,

	key = function(state, key, _cx)
		return on_key(state, key)
	end,

	event = function(state, ev, _cx)
		on_event(state, ev)
	end,

	save = function(state)
		return { tab = state.tab, query = state.fields.query.text }
	end,
}

M.def = def

return M
