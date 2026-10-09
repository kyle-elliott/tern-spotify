--!strict
-- Spotify Web API JSON -> plain Lua values the views use. Every reader
-- tolerates missing fields and JSON nulls (which decode to tern.json.null
-- inside arrays and are dropped from objects).

export type Track = {
	uri: string,
	name: string,
	artists: string, -- joined with ", "; the show for an episode
	album: string?,
	album_uri: string?,
	duration_ms: number,
	image: string?,
	kind: string, -- "track" | "episode"
	explicit: boolean,
}

export type Device = {
	id: string?,
	name: string,
	type: string,
	active: boolean,
	restricted: boolean,
	volume: number?,
	supports_volume: boolean,
}

export type Playback = {
	device: Device?,
	playing: boolean,
	shuffle: boolean,
	repeat_mode: string, -- "off" | "context" | "track"
	progress_ms: number,
	item: Track?,
	context_uri: string?,
}

export type Playlist = {
	uri: string,
	id: string,
	name: string,
	owner: string?,
	owner_id: string?,
	collaborative: boolean,
	total: number?,
	image: string?,
}

export type Album = { uri: string, name: string, artists: string, image: string? }
export type Artist = { uri: string, name: string, image: string? }

export type Page<T> = { items: { T }, next: string?, total: number? }

export type SearchResults = {
	tracks: { Track },
	albums: { Album },
	artists: { Artist },
	playlists: { Playlist },
}

export type Queue = { current: Track?, items: { Track } }

local M = {}

local function obj(v: any): { [string]: any }?
	return if type(v) == "table" then v else nil
end

-- `v` when it is a table, else an empty one.
local function tbl(v: any): { [string]: any }
	return if type(v) == "table" then v else {}
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function num(v: any): number?
	return if type(v) == "number" then v else nil
end

local function list(v: any): { any }
	local out = {}
	if type(v) == "table" then
		for _, item in ipairs(v) do
			if type(item) == "table" then
				table.insert(out, item)
			end
		end
	end
	return out
end

-- The URL of the smallest image at least 250 px wide, else the largest, else the first.
function M.image(images: any): string?
	local best: { [string]: any }? = nil
	local best_w = 0
	local fallback: string? = nil
	for _, img in list(images) do
		local src = str(img.url)
		if src then
			fallback = fallback or src
			local w = num(img.width) or 0
			if best == nil then
				best, best_w = img, w
			elseif best_w < 250 and w > best_w then
				best, best_w = img, w
			elseif w >= 250 and w < best_w then
				best, best_w = img, w
			end
		end
	end
	return if best then str(best.url) else fallback
end

local function names(artists: any): string
	local out = {}
	for _, a in list(artists) do
		local n = str(a.name)
		if n then
			table.insert(out, n)
		end
	end
	return table.concat(out, ", ")
end

function M.track(v: any): Track?
	local t = obj(v)
	if t == nil then
		return nil
	end
	local uri = str(t.uri)
	if uri == nil then
		return nil
	end
	local kind = str(t.type) or "track"
	if kind == "episode" then
		local show = tbl(t.show)
		return {
			uri = uri,
			name = str(t.name) or "Untitled episode",
			artists = str(show.name) or "",
			album = nil,
			album_uri = str(show.uri),
			duration_ms = num(t.duration_ms) or 0,
			image = M.image(t.images) or M.image(show.images),
			kind = "episode",
			explicit = t.explicit == true,
		}
	end
	local album = tbl(t.album)
	return {
		uri = uri,
		name = str(t.name) or "Untitled",
		artists = names(t.artists),
		album = str(album.name),
		album_uri = str(album.uri),
		duration_ms = num(t.duration_ms) or 0,
		image = M.image(album.images),
		kind = "track",
		explicit = t.explicit == true,
	}
end

function M.device(v: any): Device?
	local d = obj(v)
	if d == nil then
		return nil
	end
	return {
		id = str(d.id),
		name = str(d.name) or "Unknown device",
		type = str(d.type) or "Unknown",
		active = d.is_active == true,
		restricted = d.is_restricted == true,
		volume = num(d.volume_percent),
		supports_volume = d.supports_volume ~= false and num(d.volume_percent) ~= nil,
	}
end

-- GET /me/player (nil body, a 204, means nothing is playing anywhere).
function M.playback(v: any): Playback?
	local p = obj(v)
	if p == nil then
		return nil
	end
	local context = obj(p.context)
	return {
		device = M.device(p.device),
		playing = p.is_playing == true,
		shuffle = p.shuffle_state == true,
		repeat_mode = str(p.repeat_state) or "off",
		progress_ms = num(p.progress_ms) or 0,
		item = M.track(p.item),
		context_uri = if context then str(context.uri) else nil,
	}
end

function M.devices(v: any): { Device }
	local out = {}
	local d = obj(v)
	for _, item in list(if d then d.devices else nil) do
		local dev = M.device(item)
		if dev then
			table.insert(out, dev)
		end
	end
	return out
end

function M.queue(v: any): Queue
	local q = tbl(v)
	local items = {}
	for _, item in list(q.queue) do
		local t = M.track(item)
		if t then
			table.insert(items, t)
		end
	end
	return { current = M.track(q.currently_playing), items = items }
end

function M.playlist(v: any): Playlist?
	local p = obj(v)
	if p == nil then
		return nil
	end
	local uri, id = str(p.uri), str(p.id)
	if uri == nil or id == nil then
		return nil
	end
	local owner = obj(p.owner)
	-- `tracks` was renamed `items` in newer API responses; read either.
	local counts = obj(p.tracks) or obj(p.items)
	return {
		uri = uri,
		id = id,
		name = str(p.name) or "Untitled playlist",
		owner = if owner then str(owner.display_name) or str(owner.id) else nil,
		owner_id = if owner then str(owner.id) else nil,
		collaborative = p.collaborative == true,
		total = if counts then num(counts.total) else nil,
		image = M.image(p.images),
	}
end

-- GET /me/playlists
function M.playlists(v: any): Page<Playlist>
	local page = tbl(v)
	local items = {}
	for _, item in list(page.items) do
		local p = M.playlist(item)
		if p then
			table.insert(items, p)
		end
	end
	return { items = items, next = str(page.next), total = num(page.total) }
end

-- GET /playlists/{id}/tracks and GET /me/tracks: entries wrap the track (local and
-- unavailable tracks come back null and are skipped).
function M.track_page(v: any): Page<Track>
	local page = tbl(v)
	local items = {}
	for _, entry in list(page.items) do
		local t = M.track(entry.track or entry.item)
		if t and entry.is_local ~= true then
			table.insert(items, t)
		end
	end
	return { items = items, next = str(page.next), total = num(page.total) }
end

-- GET /search
function M.search(v: any): SearchResults
	local s = tbl(v)
	local out: SearchResults = { tracks = {}, albums = {}, artists = {}, playlists = {} }
	for _, item in list(tbl(s.tracks).items) do
		local t = M.track(item)
		if t then
			table.insert(out.tracks, t)
		end
	end
	for _, item in list(tbl(s.albums).items) do
		local uri = str(item.uri)
		if uri then
			table.insert(out.albums, {
				uri = uri,
				name = str(item.name) or "Untitled album",
				artists = names(item.artists),
				image = M.image(item.images),
			})
		end
	end
	for _, item in list(tbl(s.artists).items) do
		local uri = str(item.uri)
		if uri then
			table.insert(out.artists, { uri = uri, name = str(item.name) or "Unknown artist", image = M.image(item.images) })
		end
	end
	for _, item in list(tbl(s.playlists).items) do
		local p = M.playlist(item)
		if p then
			table.insert(out.playlists, p)
		end
	end
	return out
end

-- "3:07", or "1:02:03" past an hour.
function M.duration(ms: number): string
	local total = math.max(0, math.floor(ms / 1000))
	local h, m, s = total // 3600, (total // 60) % 60, total % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%d:%02d", m, s)
end

return M
