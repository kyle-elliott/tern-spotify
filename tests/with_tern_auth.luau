-- Sign-in, the single-flight refresh and the API wrapper against the fake `tern`.
-- Bundled by run.py: `tern` and `require` are locals provided by the bundle.

local auth = require("./auth")
local api = require("./api")
-- These tests cover the plain-storage fallback: no OS protection here.
local vault = require("./vault")
vault.scheme = function(): string?
	return nil
end
vault.seal = function(_secret: string, cb: any)
	cb(nil, "test: no protection")
end
local url = require("./url")
local sha256 = require("./sha256")
local fake = (tern :: any).fake

local check = require("./check")
local eq = check.eq

local now = 1000000
auth.clock = function()
	return now
end
local changes = 0
auth.on_change(function()
	changes += 1
end)

local CLIENT = "0123456789abcdef0123456789abcdef"

-- Client ID validation.
eq("client id rejects junk", auth.set_client_id("nope") ~= nil, true)
eq("client id accepts hex", auth.set_client_id("  " .. string.upper(CLIENT) .. "\n"), nil)
eq("client id stored lowercase", auth.client_id(), CLIENT)

-- begin: random bytes from a process, PKCE values, authorize URL.
local authorize: string? = nil
auth.begin(function(u, err)
	authorize = u
	eq("begin no error", err, nil)
end)
eq("begin spawned one process", #fake.processes, 1)
local proc = table.remove(fake.processes, 1)
local raw = string.rep("\1\2\3\4", 16)
proc.cb({ status = 0, stdout = tern.base64.encode(raw) .. "\r\n", stderr = "", timed_out = false }, nil)
local pending = auth.pending()
assert(pending, "pending stored")
eq("verifier length", #pending.verifier, 64)
eq("verifier from first 48 bytes", pending.verifier, tern.base64.encode(string.sub(raw, 1, 48), { url = true }))
assert(authorize, "authorize URL")
local aq = url.parse_query(authorize)
eq("authorize challenge", aq.code_challenge, tern.base64.encode(sha256.digest(pending.verifier), { url = true }))
eq("authorize method", aq.code_challenge_method, "S256")
eq("authorize redirect", aq.redirect_uri, "http://127.0.0.1:8888/callback")
eq("authorize state", aq.state, pending.state)
eq("authorize client", aq.client_id, CLIENT)
eq("authorize scopes", string.find(aq.scope, "user-modify-playback-state", 1, true) ~= nil, true)

-- complete: rejects wrong addresses without a request.
local complete_err: string? = nil
auth.complete("http://127.0.0.1:8888/callback?state=" .. pending.state, function(err)
	complete_err = err
end)
eq("complete without code fails", complete_err ~= nil, true)
auth.complete("http://127.0.0.1:8888/callback?code=abc&state=other", function(err)
	complete_err = err
end)
eq("complete wrong state fails", string.find(complete_err or "", "another sign-in", 1, true) ~= nil, true)
eq("no request for bad addresses", #fake.fetches, 0)

-- complete: exchanges the code.
complete_err = "unset"
auth.complete("http://127.0.0.1:8888/callback?code=THECODE&state=" .. url.encode(pending.state), function(err)
	complete_err = err
end)
eq("exchange sent", #fake.fetches, 1)
local form = url.parse_query(fake.fetches[1].opts.body)
eq("exchange grant", form.grant_type, "authorization_code")
eq("exchange code", form.code, "THECODE")
eq("exchange verifier", form.code_verifier, pending.verifier)
eq("exchange method", fake.fetches[1].opts.method, "POST")
fake.answer(200, { access_token = "A1", refresh_token = "R1", expires_in = 3600, scope = "s" })
eq("complete ok", complete_err, nil)
eq("tokens stored", auth.tokens() and auth.tokens().access_token, "A1")
eq("pending cleared", auth.pending(), nil)
eq("change notified", changes, 1)

-- token: fresh token needs no request.
local got: { any } = {}
auth.token(function(t, e)
	table.insert(got, { t, e })
end)
eq("fresh token inline", got[1][1], "A1")
eq("fresh token no fetch", #fake.fetches, 0)

-- Near expiry: concurrent callers share one refresh; a rotated refresh token is kept.
now += 3600 - 100
got = {}
for _ = 1, 3 do
	auth.token(function(t, e)
		table.insert(got, { t, e })
	end)
end
eq("single refresh in flight", #fake.fetches, 1)
local rform = url.parse_query(fake.fetches[1].opts.body)
eq("refresh grant", rform.refresh_token, "R1")
fake.answer(200, { access_token = "A2", refresh_token = "R2", expires_in = 3600 })
eq("all callers answered", #got, 3)
eq("callers got new token", got[3][1], "A2")
eq("rotated refresh token stored", auth.tokens() and auth.tokens().refresh_token, "R2")

-- Refresh without rotation keeps the old refresh token.
auth.refresh(function() end)
fake.answer(200, { access_token = "A3", expires_in = 3600 })
eq("refresh token kept", auth.tokens() and auth.tokens().refresh_token, "R2")

-- refresh(stale): another caller already refreshed, so no request.
local stale_answer: string? = nil
auth.refresh(function(t)
	stale_answer = t
end, "A2")
eq("stale refresh answered from store", stale_answer, "A3")
eq("stale refresh no fetch", #fake.fetches, 0)

-- Sign-out while a refresh is in flight: the late answer isn't written back.
auth.refresh(function() end)
auth.sign_out()
fake.answer(200, { access_token = "LATE", refresh_token = "LATE", expires_in = 3600 })
eq("late refresh discarded", auth.tokens(), nil)
eq("client id survives sign-out", auth.client_id(), CLIENT)

-- Sign-out by another VM (the window half deletes `auth` in kv) during a refresh: nothing is written back.
tern.kv.set("auth", { access_token = "E1", refresh_token = "ER", expires_at = now - 10 })
local eerr: string? = nil
local before_ext = changes
auth.token(function(_t, e)
	eerr = e
end)
tern.kv.set("auth", nil)
fake.answer(200, { access_token = "E2", refresh_token = "ER2", expires_in = 3600 })
eq("external sign-out not overwritten", auth.tokens(), nil)
eq("external sign-out reported", eerr, auth.SIGNED_OUT)
eq("external sign-out notifies", changes, before_ext + 1)

-- invalid_grant: tokens are forgotten and callers hear signed_out.
tern.kv.set("auth", { access_token = "B1", refresh_token = "BR", expires_at = now - 10 })
local before = changes
local ierr: string? = nil
auth.token(function(_t, e)
	ierr = e
end)
fake.answer(400, { error = "invalid_grant", error_description = "Refresh token revoked" })
eq("invalid_grant signs out", auth.tokens(), nil)
eq("invalid_grant error", ierr, auth.SIGNED_OUT)
eq("invalid_grant notifies", changes, before + 1)

-- A network failure keeps the tokens.
tern.kv.set("auth", { access_token = "C1", refresh_token = "CR", expires_at = now - 10 })
local nerr: string? = nil
auth.token(function(_t, e)
	nerr = e
end)
fake.network_error("io: Connection refused")
eq("network error reported", string.find(nerr or "", "Connection refused", 1, true) ~= nil, true)
eq("network error keeps tokens", auth.tokens() and auth.tokens().refresh_token, "CR")

-- api.request: a 401 refreshes once and retries with the new token.
tern.kv.set("auth", { access_token = "D1", refresh_token = "DR", expires_at = now + 3600 })
local res: any = nil
api.request("PUT", "/me/player/pause", nil, function(r)
	res = r
end)
eq("api first attempt token", fake.fetches[1].opts.headers.Authorization, "Bearer D1")
eq("api bodiless PUT sends empty body", fake.fetches[1].opts.body, "")
fake.answer(401, { error = { status = 401, message = "The access token expired" } })
eq("api refresh after 401", string.find(fake.fetches[1].url, "/api/token", 1, true) ~= nil, true)
fake.answer(200, { access_token = "D2", expires_in = 3600 })
eq("api retry token", fake.fetches[1].opts.headers.Authorization, "Bearer D2")
fake.answer(204, nil)
eq("api retried ok", res and res.ok, true)

-- api: error classification.
local function classify(status: number, body: any, headers: any?): any
	local out: any = nil
	api.request("GET", "/me/player", { query = { additional_types = "episode" } }, function(r)
		out = r
	end)
	fake.answer(status, body, headers)
	return out
end
eq("api query string", (function()
	api.request("GET", "/me/player", { query = { additional_types = "episode" } }, function() end)
	local u = fake.fetches[1].url
	fake.answer(204, nil)
	return u
end)(), "https://api.spotify.com/v1/me/player?additional_types=episode")
eq("premium", classify(403, { error = { status = 403, message = "x", reason = "PREMIUM_REQUIRED" } }).kind, "premium")
eq("no device", classify(404, { error = { status = 404, message = "Player command failed: No active device found", reason = "NO_ACTIVE_DEVICE" } }).kind, "no_device")
local rate = classify(429, nil, { ["retry-after"] = "7" })
eq("rate kind", rate.kind, "rate")
eq("rate retry", rate.retry_after, 7)
eq("restricted", classify(403, { error = { status = 403, message = "Restriction violated", reason = "UNKNOWN" } }).kind, "restricted")
eq("ok with json", classify(200, { is_playing = true }).data.is_playing, true)

-- api: absolute `next` URLs only under the API base.
eq("resolve next", api.resolve("https://api.spotify.com/v1/me/playlists?offset=50"), "https://api.spotify.com/v1/me/playlists?offset=50")
eq("resolve foreign host refused", api.resolve("https://evil.example/v1/x"), nil)
eq("resolve prefix trick refused", api.resolve("https://api.spotify.com/v1.evil.example/x"), nil)

-- Signed out: requests fail without a fetch.
auth.sign_out()
api.request("GET", "/me/player", nil, function(r)
	res = r
end)
eq("signed out kind", res.kind, "signed_out")
eq("signed out no fetch", #fake.fetches, 0)

-- Changing the Client ID drops tokens issued for the old app.
tern.kv.set("auth", { access_token = "F1", refresh_token = "FR", expires_at = now + 3600 })
eq("same client id keeps tokens", auth.set_client_id(CLIENT), nil)
eq("same client id: tokens kept", auth.tokens() ~= nil, true)
eq("other client id accepted", auth.set_client_id("fedcba9876543210fedcba9876543210"), nil)
eq("other client id: tokens dropped", auth.tokens(), nil)
auth.set_client_id(CLIENT)

-- A pending sign-in past its lifetime is refused without a request.
tern.kv.set("pending", { verifier = "v", state = "S", client_id = CLIENT, created = now - auth.PENDING_TTL - 1 })
local stale_err: string? = nil
auth.complete("http://127.0.0.1:8888/callback?code=c&state=S", function(err)
	stale_err = err
end)
eq("stale pending refused", string.find(stale_err or "", "expired", 1, true) ~= nil, true)
eq("stale pending cleared", auth.pending(), nil)
eq("stale pending: no request", #fake.fetches, 0)

-- A code exchange without a refresh token stores nothing.
tern.kv.set("pending", { verifier = "v", state = "S", client_id = CLIENT, created = now })
local noref_err: string? = nil
auth.complete("http://127.0.0.1:8888/callback?code=c&state=S", function(err)
	noref_err = err
end)
fake.answer(200, { access_token = "G1", expires_in = 3600 })
eq("exchange without refresh token refused", noref_err ~= nil, true)
eq("exchange without refresh token: nothing stored", auth.tokens(), nil)

check.done("auth/api")
