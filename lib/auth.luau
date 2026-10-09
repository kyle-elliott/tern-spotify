--!strict
-- Spotify sign-in (Authorization Code with PKCE) and the access token.
--
-- Host half only writes tokens. All refreshes go through `refresh`, which keeps
-- at most one refresh request in flight: Spotify may rotate the refresh token
-- on every refresh, so two concurrent refreshes could invalidate each other.
--
-- The refresh token (the long-lived credential) is stored sealed by the OS (lib/vault)
-- when this machine can, else in plain kv as a fallback. The access token stays plain:
-- it expires within the hour and the window half reads it for its controls.

local sha256 = require("./sha256")
local url = require("./url")
local config = require("./config")
local proc = require("./proc")
local text = require("./text")
local vault = require("./vault")

export type Tokens = {
	access_token: string,
	refresh_token: string?, -- plain fallback
	refresh_sealed: vault.Sealed?, -- or sealed by the OS
	expires_at: number, -- Unix seconds
	scope: string?,
}

export type Pending = {
	verifier: string,
	state: string,
	client_id: string,
	created: number, -- Unix seconds
}

type TokenCallback = (token: string?, err: string?) -> ()

local M = {}

-- `token`/`refresh` report this error when nobody is signed in (or a refresh was refused).
M.SIGNED_OUT = "signed_out"
-- Refresh this many seconds before the access token expires, so the window half
-- (which never refreshes) always reads a token with minutes left.
M.MARGIN = 300
-- A sign-in not finished within this many seconds is refused locally (Spotify's codes expire too).
M.PENDING_TTL = 15 * 60
-- Seconds since the epoch; tests replace it.
M.clock = os.time

local listeners: { () -> () } = {}
-- Bumped by sign-in and sign-out, so a refresh that finishes afterwards doesn't
-- write back tokens that were replaced or removed meanwhile.
local generation = 0
local waiting: { TokenCallback }? = nil
-- The plain refresh token behind the stored sealed one, once read (this VM only).
local remembered: { sealed: string, token: string }? = nil
local warned_plain = false

-- Calls `fn` whenever the signed-in state changes (sign-in, sign-out, refused refresh).
function M.on_change(fn: () -> ())
	table.insert(listeners, fn)
end

local function changed()
	for _, fn in listeners do
		local ok, err = pcall(function()
			fn()
		end)
		if not ok then
			tern.log.warn("spotify: auth listener failed", err)
		end
	end
end

-- tern.kv.set raises on I/O errors; callers in callbacks must still answer.
local function store(key: string, value: any): string?
	local ok, err = pcall(function()
		tern.kv.set(key, value)
	end)
	if ok then
		return nil
	end
	return "Could not save sign-in data: " .. tostring(err)
end

-- Identifies a stored sealed value, to tell whether `remembered` belongs to it.
local function sealed_key(t: Tokens): string?
	local sealed = t.refresh_sealed
	return if sealed then sealed.scheme .. ":" .. sealed.data else nil
end

-- The plain refresh token of `t` when known without a process: stored plain, or read before.
local function known_refresh(t: Tokens): string?
	if t.refresh_token then
		return t.refresh_token
	end
	local key = sealed_key(t)
	if key and remembered and remembered.sealed == key then
		return remembered.token
	end
	return nil
end

-- Removes a sealed secret kept outside kv (keychain, libsecret) and the in-memory copy.
local function drop_sealed(t: Tokens?)
	if t then
		vault.forget(t.refresh_sealed)
	end
	remembered = nil
end

local function warn_plain(why: string?)
	if not warned_plain then
		warned_plain = true
		tern.log.warn("spotify: storing the refresh token unencrypted:", why or "no OS protection available")
	end
end

-- Answers the plain refresh token of `t`, unsealing it when needed.
local function read_refresh(t: Tokens, cb: (token: string?, err: string?) -> ())
	local known = known_refresh(t)
	if known then
		cb(known, nil)
		return
	end
	local sealed = t.refresh_sealed
	local key = sealed_key(t)
	if sealed == nil or key == nil then
		cb(nil, M.SIGNED_OUT)
		return
	end
	local sealed_value: vault.Sealed = sealed
	local key_value: string = key
	vault.open(sealed_value, function(secret, err)
		if secret and secret ~= "" then
			remembered = { sealed = key_value, token = secret }
			cb(secret, nil)
		else
			cb(nil, "Could not unlock the stored Spotify sign-in (" .. (err or "empty") .. "). Sign out and in again if this keeps happening.")
		end
	end)
end

local CANCELLED = "cancelled"

-- Writes new tokens, sealing the refresh token when this machine can (else storing it plain).
-- `still` is asked right before writing; when it answers false nothing is written and `cb`
-- gets CANCELLED. An unchanged, already sealed refresh token is reused without a process.
local function persist(access: string, refresh: string, expires_at: number, scope: string?, previous: Tokens?, still: () -> boolean, cb: (err: string?) -> ())
	local function write(t: Tokens)
		if not still() then
			cb(CANCELLED)
			return
		end
		local failed = store(config.KEY_AUTH, t)
		if failed == nil then
			local key = sealed_key(t)
			remembered = if key then { sealed = key, token = refresh } else nil
			if t.refresh_sealed == nil and previous and previous.refresh_sealed then
				vault.forget(previous.refresh_sealed) -- went plain: don't leave the old secret behind
			end
		end
		cb(failed)
	end
	if previous and previous.refresh_sealed and known_refresh(previous) == refresh then
		write({ access_token = access, refresh_sealed = previous.refresh_sealed, expires_at = expires_at, scope = scope })
		return
	end
	vault.seal(refresh, function(sealed, why)
		if sealed then
			write({ access_token = access, refresh_sealed = sealed, expires_at = expires_at, scope = scope })
		else
			warn_plain(why)
			write({ access_token = access, refresh_token = refresh, expires_at = expires_at, scope = scope })
		end
	end)
end

-- Moves a refresh token stored plain (older versions, or a machine where sealing failed
-- before) under OS protection. Verified by vault.seal; on failure it stays plain.
function M.migrate()
	local t = M.tokens()
	if t == nil or t.refresh_token == nil or vault.scheme() == nil then
		return
	end
	local plain: string = t.refresh_token
	local gen = generation
	vault.seal(plain, function(sealed, why)
		local now = M.tokens()
		if gen ~= generation or now == nil or known_refresh(now) ~= plain or now.refresh_token == nil then
			return -- replaced, refreshed or signed out meanwhile
		end
		if sealed == nil then
			warn_plain(why)
			return
		end
		local migrated: Tokens = { access_token = now.access_token, refresh_sealed = sealed, expires_at = now.expires_at, scope = now.scope }
		if store(config.KEY_AUTH, migrated) == nil then
			remembered = { sealed = sealed.scheme .. ":" .. sealed.data, token = plain }
		end
	end)
end

function M.client_id(): string?
	local v = tern.kv.get(config.KEY_CLIENT)
	return if type(v) == "string" and v ~= "" then v else nil
end

-- Saves a pasted or typed Client ID; returns an error message when it isn't one.
function M.set_client_id(input: string): string?
	local id = string.lower(text.trim(input))
	if #id ~= 32 or string.match(id, "^%x+$") == nil then
		return "A Client ID is 32 hexadecimal characters (Spotify Developer Dashboard › your app › Settings)."
	end
	if id ~= M.client_id() then
		-- Tokens and a pending sign-in belong to the app that issued them.
		generation += 1
		drop_sealed(M.tokens())
		store(config.KEY_AUTH, nil)
		store(config.KEY_PENDING, nil)
		store(config.KEY_NOW, nil)
	end
	return store(config.KEY_CLIENT, id)
end

function M.clear_client_id()
	store(config.KEY_CLIENT, nil)
	store(config.KEY_PENDING, nil)
end

function M.tokens(): Tokens?
	local t = tern.kv.get(config.KEY_AUTH)
	if type(t) ~= "table" then
		return nil
	end
	if type(t.access_token) ~= "string" or type(t.expires_at) ~= "number" then
		return nil
	end
	local sealed = t.refresh_sealed
	local has_sealed = type(sealed) == "table" and type(sealed.scheme) == "string" and type(sealed.data) == "string"
	if type(t.refresh_token) ~= "string" and not has_sealed then
		return nil
	end
	return t :: Tokens
end

function M.signed_in(): boolean
	return M.tokens() ~= nil
end

-- Whether the stored sign-in granted `scope` (sign-ins from older versions lack newer ones).
function M.has_scope(scope: string): boolean
	local t = M.tokens()
	if t == nil or type(t.scope) ~= "string" then
		return false
	end
	for s in string.gmatch(t.scope, "%S+") do
		if s == scope then
			return true
		end
	end
	return false
end

function M.pending(): Pending?
	local p = tern.kv.get(config.KEY_PENDING)
	if type(p) ~= "table" or type(p.verifier) ~= "string" or type(p.state) ~= "string" or type(p.client_id) ~= "string" then
		return nil
	end
	return p :: Pending
end

-- The authorize URL for a pending sign-in (deterministic, so a restarted block can show it again).
function M.authorize_url(p: Pending): string
	local challenge = tern.base64.encode(sha256.digest(p.verifier), { url = true })
	return url.with_query(config.ACCOUNTS .. "/authorize", {
		client_id = p.client_id,
		response_type = "code",
		redirect_uri = config.REDIRECT_URI,
		code_challenge_method = "S256",
		code_challenge = challenge,
		state = p.state,
		scope = table.concat(config.SCOPES, " "),
	})
end

-- `n` random bytes from the OS's secure generator (math.random is not one), via a short process.
function M.random_bytes(n: number, cb: (bytes: string?, err: string?) -> ())
	local argv = if tern.runtime.os == "windows"
		then proc.powershell_argv(string.format(
			"$b = New-Object byte[] %d; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b)",
			n
		))
		else { "/bin/sh", "-c", string.format("head -c %d /dev/urandom | base64 | tr -d '\\n'", n) }
	proc.run(argv, nil, function(out, err)
		local decoded, bytes = pcall(tern.base64.decode, out or "")
		if out == nil or not decoded or type(bytes) ~= "string" or #bytes ~= n then
			cb(nil, "Could not get random bytes: " .. (err or "unexpected output"))
			return
		end
		cb(bytes, nil)
	end)
end

-- Starts a sign-in: makes a PKCE verifier and state, stores them, and answers the authorize URL.
function M.begin(cb: (authorize: string?, err: string?) -> ())
	local client = M.client_id()
	if client == nil then
		cb(nil, "Enter your Client ID first.")
		return
	end
	M.random_bytes(64, function(bytes, err)
		if bytes == nil then
			cb(nil, err)
			return
		end
		local p: Pending = {
			verifier = tern.base64.encode(string.sub(bytes, 1, 48), { url = true }), -- 64 characters
			state = tern.base64.encode(string.sub(bytes, 49, 64), { url = true }),
			client_id = client,
			created = M.clock(),
		}
		local failed = store(config.KEY_PENDING, p)
		if failed then
			cb(nil, failed)
			return
		end
		cb(M.authorize_url(p), nil)
	end)
end

function M.cancel()
	store(config.KEY_PENDING, nil)
end

-- Reads a token endpoint response: the decoded body, or an error message and Spotify's error code.
local function token_response(r: FetchResult): (any, string?, string?)
	if r.error then
		return nil, "Can't reach Spotify: " .. r.error, "network"
	end
	local ok, body = pcall(tern.json.decode, r.body)
	if not ok or type(body) ~= "table" then
		return nil, string.format("Spotify answered HTTP %d", r.status), "http"
	end
	if r.status ~= 200 or type(body.access_token) ~= "string" then
		local code = if type(body.error) == "string" then body.error else "http"
		local text = if type(body.error_description) == "string" then body.error_description else code
		return nil, string.format("Spotify refused: %s (HTTP %d)", text, r.status), code
	end
	return body, nil, nil
end

local function post_token(fields: { [string]: string }, cb: (r: FetchResult) -> ())
	tern.fetch(config.ACCOUNTS .. "/api/token", {
		method = "POST",
		headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
		body = url.form(fields),
		timeout_ms = 20000,
	}, function(r: FetchResult, _cx: WindowCx?)
		cb(r)
	end)
end

-- Finishes a sign-in from the address the browser was redirected to.
function M.complete(pasted: string, cb: (err: string?) -> ())
	local p = M.pending()
	if p == nil then
		cb("Start the sign-in first.")
		return
	end
	local q = url.parse_query(text.trim(pasted))
	if q.error then
		M.cancel()
		changed()
		cb("Spotify did not sign you in: " .. q.error)
		return
	end
	if q.code == nil or q.code == "" then
		cb("That isn't the address Spotify redirected to: it has no code= in it.")
		return
	end
	if q.state ~= p.state then
		cb("That address belongs to another sign-in attempt. Use the newest one, or start over.")
		return
	end
	if M.clock() - (tonumber(p.created) or 0) > M.PENDING_TTL then
		M.cancel()
		changed()
		cb("This sign-in took too long and expired. Start over.")
		return
	end
	generation += 1
	local gen = generation
	post_token({
		grant_type = "authorization_code",
		code = q.code,
		redirect_uri = config.REDIRECT_URI,
		client_id = p.client_id,
		code_verifier = p.verifier,
	}, function(r)
		local body, err = token_response(r)
		if body == nil then
			cb(err)
			return
		end
		if gen ~= generation then
			cb("The sign-in was cancelled.")
			return
		end
		if type(body.refresh_token) ~= "string" or body.refresh_token == "" then
			cb("Spotify's answer had no refresh token; sign-in can't be kept. Try again.")
			return
		end
		local still = function()
			return gen == generation
		end
		persist(body.access_token, body.refresh_token, M.clock() + (tonumber(body.expires_in) or 3600), body.scope, nil, still, function(failed)
			if failed == CANCELLED then
				cb("The sign-in was cancelled.")
				return
			elseif failed then
				cb(failed)
				return
			end
			store(config.KEY_PENDING, nil)
			changed()
			cb(nil)
		end)
	end)
end

local function settle(list: { TokenCallback }, token: string?, err: string?)
	for _, fn in list do
		local ok, e = pcall(function()
			fn(token, err)
		end)
		if not ok then
			tern.log.warn("spotify: token callback failed", e)
		end
	end
end

-- Refreshes the access token. Concurrent callers share one request. When `stale` is
-- given and the stored token already differs from it, answers the stored one instead.
function M.refresh(cb: TokenCallback, stale: string?)
	local t = M.tokens()
	if t == nil then
		cb(nil, M.SIGNED_OUT)
		return
	end
	if stale ~= nil and t.access_token ~= stale and t.expires_at - M.MARGIN > M.clock() then
		cb(t.access_token, nil)
		return
	end
	if waiting then
		table.insert(waiting, cb)
		return
	end
	local client = M.client_id()
	if client == nil then
		cb(nil, M.SIGNED_OUT)
		return
	end
	local list: { TokenCallback } = { cb }
	waiting = list
	local gen = generation
	-- Signed out (here or by the window half's command), signed in again, or migrated to a
	-- different refresh token meanwhile: answer from what is stored now and write nothing.
	local function replaced(refresh_token: string): boolean
		local current = M.tokens()
		return gen ~= generation or current == nil or known_refresh(current) ~= refresh_token
	end
	local function answer_current()
		waiting = nil
		local current = M.tokens()
		if current == nil and gen == generation then
			generation += 1
			changed()
		end
		settle(list, if current then current.access_token else nil, if current then nil else M.SIGNED_OUT)
	end
	read_refresh(t, function(refresh_token, rerr)
		if refresh_token == nil then
			waiting = nil
			settle(list, nil, rerr)
			return
		end
		local refresh: string = refresh_token
		post_token({ grant_type = "refresh_token", refresh_token = refresh, client_id = client }, function(r)
			if replaced(refresh) then
				answer_current()
				return
			end
			local body, err, code = token_response(r)
			if body == nil then
				waiting = nil
				if code == "invalid_grant" or code == "invalid_client" then
					generation += 1
					drop_sealed(M.tokens())
					store(config.KEY_AUTH, nil)
					store(config.KEY_NOW, nil)
					changed()
					settle(list, nil, M.SIGNED_OUT)
				else
					settle(list, nil, err)
				end
				return
			end
			local access: string = body.access_token
			local next_refresh = if type(body.refresh_token) == "string" and body.refresh_token ~= "" then body.refresh_token else refresh
			local scope = if type(body.scope) == "string" then body.scope else t.scope
			local still = function()
				return not replaced(refresh)
			end
			-- `waiting` stays set while sealing, so concurrent callers wait for this answer.
			persist(access, next_refresh, M.clock() + (tonumber(body.expires_in) or 3600), scope, M.tokens(), still, function(failed)
				if failed == CANCELLED then
					answer_current()
					return
				end
				waiting = nil
				settle(list, if failed then nil else access, failed)
			end)
		end)
	end)
end

-- A usable access token, refreshing first when it expires within the margin.
function M.token(cb: TokenCallback)
	local t = M.tokens()
	if t == nil then
		cb(nil, M.SIGNED_OUT)
		return
	end
	if t.expires_at - M.MARGIN > M.clock() then
		cb(t.access_token, nil)
		return
	end
	M.refresh(cb)
end

-- Forgets the tokens, any pending sign-in and the published now-playing record.
-- The Client ID stays, so signing in again is one click.
function M.sign_out()
	generation += 1
	drop_sealed(M.tokens())
	store(config.KEY_AUTH, nil)
	store(config.KEY_PENDING, nil)
	store(config.KEY_NOW, nil)
	changed()
end

return M
