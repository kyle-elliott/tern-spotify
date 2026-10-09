--!strict
-- Renders the player block's state as Tern view nodes.

local auth = require("./auth")
local config = require("./config")
local field = require("./field")
local model = require("./model")
local session = require("./session")
local state_lib = require("./state")

type State = state_lib.State
type Row = state_lib.Row

local ui = tern.ui

local M = {}

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

-- A clickable chip, drawn like Tern's badge (see `.sp-chip` in spotify.css) so it can also
-- hold an icon and show a tooltip, which a badge can't. An empty label draws the icon alone.
local function button(key: string, label: string, act: string, tone: string?, icon: string?, tip: string?): Node
	local kids: { Node } = {}
	if icon then
		table.insert(kids, ui.node("icon", { name = icon }))
	end
	if label ~= "" then
		table.insert(kids, ui.el("span", { text = label }))
	end
	return ui.el("button", {
		key = key,
		class = "sp-chip",
		tone = if tone == "neutral" then nil else tone,
		title = tip,
		attrs = { ["aria-label"] = tip or label },
		actions = { click = act },
		role = "spotify.button",
	}, kids)
end

local function input(name: string, state: State, placeholder: string, prompt: string?): Node
	local f = state.fields[name]
	return ui.node("input", {
		key = "f_" .. name,
		text = f.text,
		cursor = field.utf16(f),
		placeholder = placeholder,
		prompt = if prompt then { ui.span(prompt, "muted") } else nil,
	})
end

local function list(key: string, rows: { Row }, selected: string?, cx: BlockCx, empty: string, reserve: number, region: string?): Node
	local items: { Node } = {}
	for i, r in rows do
		items[i] = ui.node("item", {
			key = r.key,
			label = r.label,
			detail = r.detail,
			value = r.value,
			icon = r.icon,
			tone = r.tone,
			disabled = r.disabled,
		})
	end
	return ui.node("list", {
		key = key,
		selected = if selected then (region or "main") .. "." .. key .. "." .. selected else nil,
		empty = { ui.span(empty, "muted") },
		-- `reserve` is the cell rows the rest of the view takes. A list row is a line of the
		-- terminal font plus 6 px, about 1.4 cell rows, so the cap is scaled down to fit.
		max = { lines = math.max(4, math.floor((cx.rows - reserve) / 1.4)) },
	}, items)
end

-- A clickable bar drawn like a thin meter: `n` equal segments, each a button that sends
-- `act` with its own value. Tern has no slider node and meters report no click position,
-- so segments are how a click picks a point. `fill` is the filled fraction (0–1).
local function segbar(key: string, kind: string, n: number, fill: number, act: (i: number) -> string, tip: (i: number) -> string): Node
	local segs: { Node } = {}
	for i = 1, n do
		local on = (i - 0.5) / n <= fill
		segs[i] = ui.el("button", {
			key = tostring(i),
			class = if on then "sp-seg on" else "sp-seg",
			title = tip(i),
			attrs = { ["aria-label"] = tip(i) },
			actions = { click = act(i) },
		}, { ui.el("span", { class = "sp-fill" }) })
	end
	return ui.el("div", { key = key, class = "sp-bar sp-" .. kind, grow = 1, attrs = { role = "group" } }, segs)
end

local function status_line(loading: boolean, err: string?, idle: string?): Node?
	if loading then
		return ui.progress(nil, { ui.span("Loading…", "muted") })
	elseif err then
		return ui.text({ ui.span(err, "error") })
	elseif idle then
		return ui.text({ ui.span(idle, "muted") })
	end
	return nil
end

local function push(children: { Node }, node: Node?)
	if node then
		table.insert(children, node)
	end
end

---------------------------------------------------------------------------
-- Sign-in

local INSTRUCTIONS = table.concat({
	"1. Open the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) and **Create app**.",
	"2. Add the Redirect URI `" .. config.REDIRECT_URI .. "` and tick **Web API**. Save.",
	"3. Copy the app's **Client ID** from its Settings and paste it below.",
}, "\n")

local function signin(state: State, step: string): { Node }
	local c: { Node } = {}
	if step == "client" then
		table.insert(c, ui.card({ ui.span("Connect Spotify", "strong") }, { ui.md(INSTRUCTIONS) }))
		table.insert(c, input("client_id", state, "Client ID (32 characters)"))
		table.insert(c, ui.row({ button("go", "Continue", "submit_client", "accent") }))
	elseif step == "start" then
		local id = auth.client_id() or ""
		table.insert(c, ui.card({ ui.span("Connect Spotify", "strong") }, {
			ui.text({ ui.span("Client ID ", "muted"), ui.span("…" .. string.sub(id, -6), "code") }),
			ui.text({ ui.span("Sign in opens Spotify in your browser. Press Enter or click Sign in.", "muted") }),
		}))
		table.insert(c, ui.row({
			button("signin", "Sign in with Spotify", "signin", "accent"),
			button("change", "Change Client ID", "change_client"),
		}))
	else
		table.insert(c, ui.card({ ui.span("Finish signing in", "strong") }, {
			ui.md(table.concat({
				"Spotify opened in your browser. After you approve, the browser lands on a page that **doesn't load** (`127.0.0.1:8888`).",
				"",
				"Copy that page's full address from the address bar and paste it here.",
			}, "\n")),
		}))
		table.insert(c, input("redirect", state, "http://127.0.0.1:8888/callback?code=…", ">"))
		table.insert(c, ui.row({
			button("finish", "Sign in", "submit_redirect", "accent"),
			button("open", "Open link again", "open_link"),
			button("copy", "Copy link", "copy_link"),
			button("restart", "Start over", "restart"),
		}))
	end
	if state.signin.busy then
		table.insert(c, ui.progress(nil, { ui.span(state.signin.busy, "muted") }))
	end
	if state.signin.error then
		table.insert(c, ui.text({ ui.span(state.signin.error, "error") }))
	end
	return c
end

---------------------------------------------------------------------------
-- Now playing

local REPEAT_LABEL = { off = "Repeat off", context = "Repeat all", track = "Repeat one" }

-- Small panes (a floating player, a narrow split) get the compact Now layout.
function M.compact(cx: BlockCx): boolean
	return cx.cols < 60 or cx.rows < 20
end

local function now_playing(state: State, cx: BlockCx): { Node }
	local compact = M.compact(cx)
	local c: { Node } = {}
	local pb = session.playback()
	if not session.loaded() then
		local problem = session.problem()
		if problem then
			table.insert(c, ui.text({ ui.span(problem.message, "error") }))
		else
			table.insert(c, ui.progress(nil, { ui.span("Connecting to Spotify…", "muted") }))
		end
		return c
	end
	local item = if pb then pb.item else nil
	if pb == nil or item == nil then
		table.insert(c, ui.card({ ui.span("Nothing playing", "strong") }, {
			ui.text({ ui.span("Start playback in a Spotify app, or pick a device and something to play.", "muted") }),
			ui.row({
				button("openapp", "Open Spotify app", "openapp", "accent", "open", "Open the Spotify app (o)"),
				button("devices", "Devices", "tab=devices", nil, "monitor", "Devices (5)"),
				button("search", "Search", "tab=search", nil, "search", "Search (/)"),
				button("library", "Library", "tab=library", nil, "list", "Library (3)"),
			}),
		}))
		return c
	end

	local meta: { Node } = {
		with(ui.text({ ui.span(item.name, "strong") }), { key = "title", role = "spotify.title" }),
		with(ui.text(item.artists), { key = "artists", role = "spotify.artists" }),
	}
	if item.album and not compact then
		table.insert(meta, with(ui.text({ ui.span(item.album, "muted") }), { key = "album" }))
	end
	local chips: { Node } = {}
	if item.explicit then
		table.insert(chips, ui.badge("E", "neutral"))
	end
	if pb.device and not compact then
		table.insert(chips, ui.badge(pb.device.name, if pb.playing then "success" else "neutral"))
	end
	if #chips > 0 then
		table.insert(meta, with(ui.row(chips), { key = "chips" }))
	end
	local up = session.next_up()
	if up and not compact then
		table.insert(meta, with(ui.text({ ui.span("Next: ", "muted"), ui.span(up.name), ui.span(if up.artists ~= "" then " · " .. up.artists else "", "muted") }), {
			key = "next",
			role = "spotify.next",
			title = "Up next — see the Queue tab (2)",
		}))
	end

	local top: { Node } = {}
	if item.image then
		local blob = session.art(cx.pane, item.image)
		table.insert(top, ui.node("image", {
			key = "art",
			blob = blob,
			alt = item.album or item.name,
			w = 300,
			h = 300,
			max = if compact then { h = "4lines", w = "8ch" } else { h = "9lines", w = "18ch" },
			role = "spotify.art",
		}))
	end
	table.insert(top, with(ui.col(meta), { key = "meta", grow = 1 }))
	table.insert(c, with(ui.row(top), { key = "np", role = "spotify.np" }))

	-- Progress: a click seeks to that point (50 segments, 2% each, sent in ‰).
	local pos = session.progress()
	local duration = item.duration_ms
	local frac = if duration > 0 then pos / duration else 0
	table.insert(c, with(ui.row({
		segbar("bar", "seek", 50, frac, function(i)
			return "seekto=" .. math.floor((i - 0.5) * 20)
		end, function(i)
			return "Seek to " .. model.duration((i - 0.5) / 50 * duration)
		end),
		with(ui.text({ ui.span(model.duration(pos), "num"), ui.span(" / " .. model.duration(duration), "muted num") }), { key = "time" }),
	}), { key = "progress", role = "spotify.barrow" }))

	local liked = session.liked(item.uri)
	local repeat_word = ({ off = "off", context = "all", track = "one" } :: { [string]: string })[pb.repeat_mode] or "off"
	local repeat_tip = "Repeat: " .. repeat_word .. " — r cycles off, all, one"
	local controls: { Node } = {
		button("prev", "Prev", "prev", nil, "frame-prev", "Previous track (p)"),
		button("toggle", if pb.playing then "Pause" else "Play", "toggle", "accent", if pb.playing then "pause" else "play", if pb.playing then "Pause (space)" else "Play (space)"),
		button("next", "Next", "next", nil, "frame-next", "Next track (n)"),
	}
	if not compact then
		table.insert(controls, button("back10", "10s", "seek=back", nil, "rewind", "Back 10 seconds (←)"))
		table.insert(controls, button("fwd10", "10s", "seek=fwd", nil, "fast-forward", "Forward 10 seconds (→)"))
		table.insert(controls, button("shuffle", if pb.shuffle then "Shuffle on" else "Shuffle off", "shuffle", if pb.shuffle then "success" else nil, "swap", "Shuffle (s)"))
		table.insert(controls, button("repeat", REPEAT_LABEL[pb.repeat_mode] or "Repeat", "repeat", if pb.repeat_mode ~= "off" then "success" else nil, "repeat", repeat_tip))
	end
	table.insert(controls, button("like", if liked then "Liked" else "Like", "like", if liked then "success" else nil, "sparkle", if liked then "Remove from Liked Songs (h)" else "Save to Liked Songs (h)"))
	if not compact then
		table.insert(controls, button("addto", "Add to playlist", "addto", nil, "plus", "Add to one of your playlists (A)"))
	end
	table.insert(c, with(ui.row(controls), { key = "controls", role = "spotify.controls" }))

	-- Volume: 20 segments of 5%; the label mutes and unmutes.
	local dev = pb.device
	if dev and dev.volume and dev.supports_volume then
		local muted = dev.volume == 0
		table.insert(c, with(ui.row({
			button("voldown", "", "vol=down", nil, "minus", "Volume down 5% (−)"),
			segbar("bar", "vol", 20, dev.volume / 100, function(i)
				return "vol=" .. i * 5
			end, function(i)
				return string.format("Volume %d%%", i * 5)
			end),
			button("volup", "", "vol=up", nil, "plus", "Volume up 5% (+)"),
			with(ui.text({ ui.span(if muted then "Muted" else string.format("%d%%", dev.volume), if muted then "warning num" else "muted num") }), {
				key = "level",
				role = "spotify.level",
				title = if muted then "Unmute (m)" else "Mute (m)",
				actions = { click = "mute" },
			}),
		}), { key = "volrow", role = "spotify.barrow" }))
	end

	if not (auth.has_scope("user-library-modify") and auth.has_scope("playlist-modify-private")) then
		table.insert(c, with(ui.row({
			ui.text({ ui.span("Like and Add to playlist need one more Spotify permission.", "muted") }),
			button("reauth", "Sign in again", "reauth"),
		}), { key = "reauth" }))
	end
	return c
end

---------------------------------------------------------------------------
-- Dock

local HINTS = {
	now = "space play/pause · n/p next/prev · ←/→ seek · +/− volume · m mute · h like · A add to playlist · s shuffle · r repeat · / search",
	queue = "↑/↓ select · enter skip ahead to it · a add to queue · A add to playlist · space play/pause · f5 reload",
	library = "↑/↓ select · enter play/open · a add to queue · A add to playlist · esc back · f5 reload",
	search = "/ search · ↓ results · enter play · a add to queue · A add to playlist · esc leave the field",
	devices = "↑/↓ select · enter play on that device · o open the Spotify app · f5 reload",
}

local function dock(state: State, compact: boolean): Node
	local info: { Span | string } = {}
	local pb = session.playback()
	if pb and pb.device then
		table.insert(info, ui.span(if pb.playing then "▶ " else "❚❚ ", if pb.playing then "success" else "muted"))
		table.insert(info, ui.span(pb.device.name))
		if pb.device.volume then
			table.insert(info, ui.span(string.format(" · %d%%", pb.device.volume), "muted"))
		end
	end
	local f = state.flash
	local problem = session.problem()
	if f and f.until_ms > tern.now() then
		table.insert(info, ui.span(if #info > 0 then "   " else ""))
		table.insert(info, ui.span(f.text, f.tone))
	elseif problem then
		table.insert(info, ui.span(if #info > 0 then "   " else ""))
		table.insert(info, ui.span(problem.message, if problem.kind == "rate" then "warning" else "error"))
	end
	if #info == 0 then
		table.insert(info, ui.span("No active device", "muted"))
	end
	local status = with(ui.row({
		with(ui.text(info), { key = "info", grow = 1 }),
		button("signout", "Sign out", "signout"),
	}), { key = "status" })
	if compact then
		return ui.col({ status })
	end
	return ui.col({
		status,
		with(ui.text({ ui.span(HINTS[state.tab] or "", "muted") }), { key = "hints", role = "spotify.hints" }),
	})
end

-- The "Add to playlist" sheet. It takes the place of the tab's content in `main` (a
-- `layer` overlay is see-through and keeps arrow keys from the block). Its list is a
-- direct child of `main`, so its node id is `main.pick`.
local function picker(state: State, cx: BlockCx, rows: { Row }): { Node }?
	local p = state.picker
	if p == nil then
		return nil
	end
	local status: Node? = nil
	if p.uid == nil or (state.playlists.loading and not state.playlists.loaded) then
		status = ui.progress(nil, { ui.span("Loading your playlists…", "muted") })
	elseif state.playlists.error then
		status = ui.text({ ui.span(state.playlists.error, "error") })
	end
	local sel = p.sel or (if rows[1] then rows[1].key else nil)
	local children: { Node } = {
		with(ui.text({ ui.span("Add ", "muted"), ui.span(p.name, "strong"), ui.span(" to a playlist", "muted") }), { key = "head" }),
	}
	push(children, status)
	table.insert(children, list("pick", rows, sel, cx, if p.uid then "No playlists you can edit" else "", 10))
	table.insert(children, with(ui.row({
		ui.text({ ui.span("↑/↓ select · enter add · esc close", "muted") }),
		button("close", "Close", "close_picker"),
	}), { key = "foot" }))
	return children
end

---------------------------------------------------------------------------
-- The whole view

function M.render(state: State, cx: BlockCx, rows: { Row }, selected: string?, step: string, picker_rows: { Row }): BlockView
	if not auth.signed_in() then
		local d: { Node } = {}
		local f = state.flash
		if f and f.until_ms > tern.now() then
			table.insert(d, ui.text({ ui.span(f.text, f.tone) }))
		end
		return { main = ui.col(signin(state, step)), dock = ui.col(d) }
	end

	local tabs: { any } = {}
	for _, t in state_lib.TABS do
		table.insert(tabs, { id = t.id, label = t.label })
	end
	local compact = M.compact(cx)
	local main: { Node } = {}
	if not (compact and state.tab == "now") then
		table.insert(main, ui.node("tabs", { key = "tabs", active = state.tab, items = tabs }))
	end

	local tab = state.tab
	local sheet = picker(state, cx, picker_rows)
	if sheet then
		for _, n in sheet do
			table.insert(main, n)
		end
	elseif tab == "now" then
		for _, n in now_playing(state, cx) do
			table.insert(main, n)
		end
	elseif tab == "queue" then
		local q = state.queue
		push(main, status_line(q.loading and q.data == nil, q.error, nil))
		table.insert(main, list("queue", rows, selected, cx, if q.loading then "Loading…" else "The queue is empty", 7))
	elseif tab == "library" then
		local opened = state.opened
		if opened then
			table.insert(main, with(ui.text({ ui.span(opened.title, "strong"), ui.span(if opened.tracks.total then string.format("  %d tracks", opened.tracks.total) else "", "muted") }), { key = "heading" }))
			push(main, status_line(opened.tracks.loading and not opened.tracks.loaded, opened.tracks.error, nil))
		else
			push(main, status_line(state.playlists.loading and not state.playlists.loaded, state.playlists.error, nil))
		end
		table.insert(main, list("library", rows, selected, cx, "Nothing here yet", 8))
	elseif tab == "search" then
		local s = state.search
		table.insert(main, input("query", state, "Songs, albums, artists, playlists", "/"))
		local idle = if s.ran == nil then "Type to search Spotify" elseif s.results and #rows == 0 then "No results" else nil
		push(main, status_line(s.loading, s.error, idle))
		table.insert(main, list("results", rows, selected, cx, "", 9))
	elseif tab == "devices" then
		local d = state.devices
		push(main, status_line(d.loading and not d.loaded, d.error, nil))
		table.insert(main, list("devices", rows, selected, cx, "No devices. Open Spotify on a computer, phone or speaker first (o opens it here).", 8))
	end

	return { main = ui.col(main), dock = dock(state, compact) }
end

return M
