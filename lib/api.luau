--!strict
-- Spotify Web API requests: Bearer auth, one refresh-and-retry on 401, and
-- responses classified into the cases the UI explains differently.

local url = require("./url")
local config = require("./config")
local auth = require("./auth")

export type Result = {
	ok: boolean,
	status: number,
	data: any, -- decoded JSON body, nil for empty bodies (204)
	kind: string?, -- on failure: signed_out, network, rate, premium, no_device, restricted, not_found, auth, http
	message: string?,
	retry_after: number?, -- seconds, for kind = "rate"
}

export type Options = {
	query: { [string]: any }?,
	body: any?, -- JSON-encoded when present
}

type Callback = (res: Result) -> ()

local M = {}

local function fail(kind: string, message: string, status: number?): Result
	return { ok = false, status = status or 0, data = nil, kind = kind, message = message }
end

-- Turns a fetch result into a Result.
function M.classify(r: FetchResult): Result
	if r.error then
		return fail("network", "Can't reach Spotify: " .. r.error)
	end
	local data: any = nil
	if r.body ~= "" then
		local ok, decoded = pcall(tern.json.decode, r.body)
		if ok then
			data = decoded
		end
	end
	if r.status >= 200 and r.status < 300 then
		return { ok = true, status = r.status, data = data }
	end
	local message = string.format("Spotify answered HTTP %d", r.status)
	local reason: string? = nil
	if type(data) == "table" and type(data.error) == "table" then
		if type(data.error.message) == "string" then
			message = data.error.message
		end
		if type(data.error.reason) == "string" then
			reason = data.error.reason
		end
	end
	local res = fail("http", message, r.status)
	if r.status == 429 then
		res.kind = "rate"
		res.retry_after = tonumber(r.headers["retry-after"]) or 5
		res.message = string.format("Spotify is rate limiting requests; retrying in %ds.", res.retry_after :: number)
	elseif r.status == 401 then
		res.kind = "auth"
	elseif reason == "PREMIUM_REQUIRED" then
		res.kind = "premium"
		res.message = "Controlling playback needs Spotify Premium."
	elseif reason == "NO_ACTIVE_DEVICE" or (r.status == 404 and string.find(string.lower(message), "no active device", 1, true)) then
		res.kind = "no_device"
		res.message = "No active Spotify device. Pick one in Devices, or start playing in a Spotify app."
	elseif r.status == 403 then
		res.kind = "restricted"
	elseif r.status == 404 then
		res.kind = "not_found"
	end
	return res
end

-- The absolute URL for `path` (a path under the API, or an absolute `next` URL the API returned).
-- Refuses absolute URLs elsewhere, so the token is never sent to another host.
function M.resolve(path: string, query: { [string]: any }?): string?
	local full: string
	if string.sub(path, 1, 1) == "/" then
		full = config.API .. path
	elseif string.sub(path, 1, #config.API + 1) == config.API .. "/" or string.sub(path, 1, #config.API + 1) == config.API .. "?" then
		full = path
	else
		return nil
	end
	return url.with_query(full, query)
end

-- Sends one request with `token`; no refresh. In the window half `cb` also gets the fresh
-- `cx` the fetch callback received (a handler's own `cx` is invalid once it returned).
function M.send(token: string, method: string, path: string, opts: Options?, cb: (res: Result, cx: WindowCx?) -> ())
	local o: Options = opts or {}
	local target = M.resolve(path, o.query)
	if target == nil then
		cb(fail("http", "Refusing to send the token to " .. path), nil)
		return
	end
	local headers: { [string]: string } = { Authorization = "Bearer " .. token, Accept = "application/json" }
	local body: string? = nil
	if o.body ~= nil then
		headers["Content-Type"] = "application/json"
		body = tern.json.encode(o.body)
	elseif method ~= "GET" then
		body = "" -- Spotify wants Content-Length on bodiless PUT/POST
	end
	local ok, err = pcall(function()
		tern.fetch(target, { method = method, headers = headers, body = body, timeout_ms = 15000 }, function(r: FetchResult, fresh: WindowCx?)
			cb(M.classify(r), fresh)
		end)
	end)
	if not ok then
		cb(fail("http", tostring(err)), nil)
	end
end

-- Host half: sends with the current token, refreshing first when needed and once more on a 401.
function M.request(method: string, path: string, opts: Options?, cb: Callback)
	auth.token(function(token, err)
		if token == nil then
			if err == auth.SIGNED_OUT then
				cb(fail("signed_out", "Not signed in to Spotify."))
			else
				cb(fail("auth", err or "Could not refresh the Spotify sign-in."))
			end
			return
		end
		M.send(token, method, path, opts, function(res)
			if res.kind ~= "auth" then
				cb(res)
				return
			end
			auth.refresh(function(fresh, ferr)
				if fresh == nil then
					cb(if ferr == auth.SIGNED_OUT then fail("signed_out", "Not signed in to Spotify.") else fail("auth", ferr or "Sign-in expired."))
					return
				end
				M.send(fresh, method, path, opts, cb)
			end, token)
		end)
	end)
end

-- Downloads an image (album art); no token is sent.
function M.image(src: string, cb: (bytes: string?, mime: string?) -> ())
	local ok = pcall(function()
		tern.fetch(src, { timeout_ms = 15000 }, function(r: FetchResult, _cx: WindowCx?)
			if r.error or r.status ~= 200 or r.body == "" then
				cb(nil, nil)
				return
			end
			local mime = string.match(r.headers["content-type"] or "", "^%s*([%w%-%.%+/]+)") or "image/jpeg"
			cb(r.body, mime)
		end)
	end)
	if not ok then
		cb(nil, nil)
	end
end

return M
