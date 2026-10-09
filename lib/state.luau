--!strict
-- The player block's per-pane state. Playback itself lives in lib/session
-- (shared by every block); this is what one pane shows and has loaded.

local field = require("./field")
local model = require("./model")

export type Field = field.Field

-- A list loaded page by page. `seq` identifies the newest request, so an older
-- answer arriving late is ignored.
export type Load<T> = {
	items: { T },
	next: string?,
	total: number?,
	loading: boolean,
	error: string?,
	loaded: boolean,
	seq: number,
}

export type Opened = {
	kind: string, -- "liked" | "playlist"
	title: string,
	playlist: model.Playlist?,
	tracks: Load<model.Track>,
}

export type Flash = { text: string, tone: string, until_ms: number }

export type State = {
	cx: BlockCx,
	tab: string, -- "now" | "queue" | "library" | "search" | "devices"
	sel: { [string]: string? }, -- selected row key per tab
	focus: string?, -- the text field taking keys: "client_id" | "redirect" | "query"
	fields: { client_id: Field, redirect: Field, query: Field },
	signin: { busy: string?, error: string? },
	flash: Flash?,
	queue: { data: model.Queue?, for_uri: string?, loading: boolean, error: string?, seq: number },
	devices: Load<model.Device>,
	playlists: Load<model.Playlist>,
	opened: Opened?,
	search: { results: model.SearchResults?, ran: string?, loading: boolean, error: string?, seq: number },
	search_timer: TimerHandle?,
	-- "Add to playlist" sheet (shown in place of the tab): the track being added and the selected row.
	picker: { uri: string, name: string, sel: string?, uid: string? }?,
	-- A Queue-tab jump in progress (it skips forward one track at a time).
	skipping: boolean,
}

-- A list row. `activate` runs on Enter or double-click; `queue_uri` enables "a" (add to queue).
export type Row = {
	key: string,
	label: { Span | string } | string,
	detail: ({ Span | string } | string)?,
	value: ({ Span | string } | string)?,
	icon: string?,
	tone: string?,
	disabled: boolean?,
	activate: ((state: State) -> ())?,
	queue_uri: string?,
}

local M = {}

M.TABS = {
	{ id = "now", label = "Now" },
	{ id = "queue", label = "Queue" },
	{ id = "library", label = "Library" },
	{ id = "search", label = "Search" },
	{ id = "devices", label = "Devices" },
}

-- The `input` nodes' ids: direct children of `main`, keyed f_<name>.
local FIELD_IDS: { [string]: string } = {
	client_id = "main.f_client_id",
	redirect = "main.f_redirect",
	query = "main.f_query",
}
M.FIELD_IDS = FIELD_IDS

function M.load<T>(): Load<T>
	return { items = {}, next = nil, total = nil, loading = false, error = nil, loaded = false, seq = 0 }
end

function M.new(cx: BlockCx): State
	return {
		cx = cx,
		tab = "now",
		sel = {},
		focus = nil,
		fields = { client_id = field.new(), redirect = field.new(), query = field.new() },
		signin = {},
		flash = nil,
		queue = { data = nil, for_uri = nil, loading = false, error = nil, seq = 0 },
		devices = M.load(),
		playlists = M.load(),
		opened = nil,
		search = { results = nil, ran = nil, loading = false, error = nil, seq = 0 },
		search_timer = nil,
		picker = nil,
		skipping = false,
	}
end

-- Shows a short message in the dock (it fades after six seconds).
function M.flash(state: State, text: string, tone: string?)
	state.flash = { text = text, tone = tone or "info", until_ms = tern.now() + 6000 }
end

-- Gives the text field `name` the keys (nil: none), and moves Tern's caret focus to it.
function M.set_focus(state: State, name: string?)
	state.focus = name
	local id: any = if name then FIELD_IDS[name] else tern.json.null
	local cx = state.cx
	-- After the render that adds the field: a focus op naming a node not yet sent does nothing.
	tern.timer(0, function()
		cx:frame({ { "focus", id } })
	end)
end

return M
