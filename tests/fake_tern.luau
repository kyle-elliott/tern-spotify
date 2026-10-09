-- A scripted stand-in for the `tern` global, for unit tests bundled by run.py.
-- Requests are recorded, not sent: a test answers them with `fake.answer`.

local fake = {}

-- JSON: bodies are registry keys, so tests describe responses as Lua tables.
local registry: { [string]: any } = {}
local seq = 0
function fake.body(value: any): string
	seq += 1
	local key = "@json" .. seq
	registry[key] = value
	return key
end

local null = newproxy()

local json = {
	null = null,
	decode = function(text: string): any
		local v = registry[text]
		if v == nil then
			error("tern.json.decode: not JSON: " .. text)
		end
		return v
	end,
	encode = function(value: any): string
		return fake.body(value)
	end,
	array = function(t: any?): any
		return t or {}
	end,
}

-- Base64 (standard alphabet; `url = true` URL-safe without padding).
local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64encode(bytes: string, opts: { url: boolean? }?): string
	local out = {}
	for i = 1, #bytes, 3 do
		local a, b, c = string.byte(bytes, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local chunk = {}
		for j = 3, 0, -1 do
			local idx = (n // (64 ^ j)) % 64
			table.insert(chunk, string.sub(ALPHA, idx + 1, idx + 1))
		end
		if c == nil then
			chunk[4] = "="
		end
		if b == nil then
			chunk[3] = "="
		end
		table.insert(out, table.concat(chunk))
	end
	local s = table.concat(out)
	if opts and opts.url then
		s = string.gsub(string.gsub(string.gsub(s, "%+", "-"), "/", "_"), "=", "")
	end
	return s
end
local function b64decode(text: string): string
	local s = string.gsub(string.gsub(string.gsub(text, "%s", ""), "-", "+"), "_", "/")
	s = string.gsub(s, "=", "")
	local out = {}
	local bits, nbits = 0, 0
	for i = 1, #s do
		local idx = string.find(ALPHA, string.sub(s, i, i), 1, true)
		if idx == nil then
			error("tern.base64.decode: invalid character")
		end
		bits = bits * 64 + (idx - 1)
		nbits += 6
		if nbits >= 8 then
			nbits -= 8
			local byte = bits // (2 ^ nbits)
			table.insert(out, string.char(byte))
			bits -= byte * (2 ^ nbits)
		end
	end
	return table.concat(out)
end

local kv_store: { [string]: any } = {}
fake.kv_store = kv_store

-- Pending fetches: { url, opts, cb } in call order.
fake.fetches = {} :: { any }
fake.processes = {} :: { any }

-- Answers the oldest pending fetch (or the one at `index`).
function fake.answer(status: number, body: any?, headers: { [string]: string }?, index: number?)
	local req = table.remove(fake.fetches, index or 1)
	assert(req, "no pending fetch to answer")
	req.cb({
		status = status,
		headers = headers or {},
		body = if body == nil then "" else fake.body(body),
		error = nil,
		timed_out = false,
	}, nil)
	return req
end

function fake.network_error(message: string)
	local req = table.remove(fake.fetches, 1)
	assert(req, "no pending fetch")
	req.cb({ status = 0, headers = {}, body = "", error = message, timed_out = false }, nil)
end

function fake.reset()
	table.clear(kv_store)
	table.clear(fake.fetches)
	table.clear(fake.processes)
	fake.timers = {}
	fake.panes = {}
end

-- Timers fire only when a test calls fake.run_timers(); panes come from fake.panes.
fake.timers = {} :: { any }
fake.panes = {} :: { any }
function fake.run_timers()
	local due = fake.timers
	fake.timers = {}
	for _, t in due do
		if not t.cancelled then
			t.fn(nil)
		end
	end
end

local tern = {
	context = "host",
	runtime = { os = "linux", jit = false },
	plugin = { id = "spotify", name = "Spotify", dir = ".", data = "." },
	log = {
		debug = function(...) end,
		info = function(...) end,
		warn = function(...) end,
		error = function(...) end,
	},
	json = json,
	base64 = { encode = b64encode, decode = b64decode },
	getenv = function(_name: string): string?
		return nil
	end,
	now = function(): number
		return os.clock() * 1000
	end,
	kv = {
		get = function(key: string): any
			return kv_store[key]
		end,
		set = function(key: string, value: any)
			kv_store[key] = value
		end,
	},
	fetch = function(url: string, opts: any, cb: any)
		table.insert(fake.fetches, { url = url, opts = opts, cb = cb })
	end,
	timer = function(ms: number, fn: any): any
		local t = { ms = ms, fn = fn, cancelled = false }
		table.insert(fake.timers, t)
		return {
			cancel = function(_self)
				t.cancelled = true
			end,
		}
	end,
	pane = {
		list = function(): { any }
			return fake.panes
		end,
	},
	process = {
		run = function(argv: { string }, opts: any, cb: any)
			table.insert(fake.processes, { argv = argv, opts = opts, cb = cb })
		end,
	},
	fake = fake,
}

return tern
