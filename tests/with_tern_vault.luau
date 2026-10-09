-- The refresh token sealed by the OS (lib/vault), against a scripted fake vault.
-- Bundled by run.py: `tern` and `require` are locals provided by the bundle.

local auth = require("./auth")
local vault = require("./vault")
local url = require("./url")
local fake = (tern :: any).fake

local check = require("./check")
local eq = check.eq

local now = 2000000
auth.clock = function()
	return now
end

-- Fake OS protection: secrets kept in a table, counted calls, switchable failures.
local secrets: { [string]: string } = {}
local calls = { seal = 0, open = 0, forget = 0 }
local fail_seal, fail_open = false, false
local n = 0
vault.scheme = function(): string?
	return "fake"
end
vault.seal = function(secret: string, cb: any)
	calls.seal += 1
	if fail_seal then
		cb(nil, "broken store")
		return
	end
	n += 1
	local data = "v" .. n
	secrets[data] = secret
	cb({ scheme = "fake", data = data }, nil)
end
vault.open = function(sealed: any, cb: any)
	calls.open += 1
	if fail_open then
		cb(nil, "locked")
		return
	end
	cb(secrets[sealed.data], nil)
end
vault.forget = function(sealed: any)
	if sealed then
		calls.forget += 1
		secrets[sealed.data] = nil
	end
end

local CLIENT = "0123456789abcdef0123456789abcdef"
auth.set_client_id(CLIENT)

local function stored(): any
	return tern.kv.get("auth")
end

-- Sign-in: the refresh token is sealed, never written plain.
tern.kv.set("pending", { verifier = "v", state = "S", client_id = CLIENT, created = now })
local err: string? = "unset"
auth.complete("http://127.0.0.1:8888/callback?code=c&state=S", function(e)
	err = e
end)
fake.answer(200, { access_token = "A1", refresh_token = "R1-secret", expires_in = 3600 })
eq("sign-in ok", err, nil)
eq("sealed once", calls.seal, 1)
eq("no plain refresh token", stored().refresh_token, nil)
eq("sealed stored", stored().refresh_sealed and stored().refresh_sealed.scheme, "fake")
eq("secret not in kv", string.find(tern.json.encode(stored()), "R1-secret", 1, true) == nil, true)
eq("signed in", auth.signed_in(), true)

-- Refresh right after: the token is known in memory, no unseal.
now += 3600
auth.token(function() end)
eq("refresh sends the secret", url.parse_query(fake.fetches[1].opts.body).refresh_token, "R1-secret")
eq("no unseal needed", calls.open, 0)
-- Not rotated: the sealed value is reused without sealing again.
fake.answer(200, { access_token = "A2", expires_in = 3600 })
eq("access stored", stored().access_token, "A2")
eq("unchanged token not resealed", calls.seal, 1)

-- Rotated: sealed again, the old secret replaced.
now += 3600
auth.token(function() end)
fake.answer(200, { access_token = "A3", refresh_token = "R2-secret", expires_in = 3600 })
eq("rotation resealed", calls.seal, 2)
eq("rotated secret sealed", secrets[stored().refresh_sealed.data], "R2-secret")

-- A sealed value this VM hasn't read (e.g. after a restart) is unsealed once.
n += 1
secrets["v" .. n] = "R3-secret"
tern.kv.set("auth", { access_token = "A3", refresh_sealed = { scheme = "fake", data = "v" .. n }, expires_at = now - 10 })
local opens = calls.open
auth.token(function() end)
eq("unsealed once", calls.open, opens + 1)
eq("refresh uses unsealed secret", url.parse_query(fake.fetches[1].opts.body).refresh_token, "R3-secret")
fake.answer(200, { access_token = "A4", expires_in = 3600 })

-- Unsealing fails: an error, and the sign-in is kept.
n += 1
secrets["v" .. n] = "R4-secret"
tern.kv.set("auth", { access_token = "A4", refresh_sealed = { scheme = "fake", data = "v" .. n }, expires_at = now - 10 })
fail_open = true
local oerr: string? = nil
auth.token(function(_t, e)
	oerr = e
end)
fail_open = false
eq("unseal failure reported", string.find(oerr or "", "Could not unlock", 1, true) ~= nil, true)
eq("unseal failure keeps sign-in", auth.signed_in(), true)
eq("no request without the secret", #fake.fetches, 0)

-- Sealing fails: falls back to plain storage.
fail_seal = true
now += 3600
tern.kv.set("auth", { access_token = "A5", refresh_token = "R5-secret", expires_at = now - 10 })
auth.token(function() end)
fake.answer(200, { access_token = "A6", refresh_token = "R6-secret", expires_in = 3600 })
fail_seal = false
eq("fallback stores plain", stored().refresh_token, "R6-secret")
eq("fallback has no sealed value", stored().refresh_sealed, nil)

-- Migration: a plain token is sealed, and the next refresh needs no unseal.
local seals = calls.seal
auth.migrate()
eq("migrated", stored().refresh_token, nil)
eq("migration sealed", calls.seal, seals + 1)
eq("migrated secret", secrets[stored().refresh_sealed.data], "R6-secret")
opens = calls.open
now += 3600
auth.token(function() end)
eq("after migration: no unseal", calls.open, opens)
eq("after migration: same secret", url.parse_query(fake.fetches[1].opts.body).refresh_token, "R6-secret")
fake.answer(200, { access_token = "A7", expires_in = 3600 })

-- Migration finishing while a refresh is in flight: the refresh answer is still stored.
tern.kv.set("auth", { access_token = "A7", refresh_token = "R7-secret", expires_at = now - 10 })
auth.token(function() end) -- request in flight with the plain token
auth.migrate() -- seals the same token meanwhile
fake.answer(200, { access_token = "A8", expires_in = 3600 })
eq("refresh survives migration", stored().access_token, "A8")
eq("still sealed after refresh", stored().refresh_sealed ~= nil and stored().refresh_token == nil, true)

-- Migration is skipped when nothing can seal.
tern.kv.set("auth", { access_token = "A9", refresh_token = "R9-secret", expires_at = now + 3600 })
fail_seal = true
auth.migrate()
fail_seal = false
eq("failed migration keeps plain", stored().refresh_token, "R9-secret")

-- Sign-out and a Client ID change remove the sealed secret.
auth.migrate()
local forgets = calls.forget
auth.sign_out()
eq("sign-out forgets sealed secret", calls.forget, forgets + 1)
tern.kv.set("auth", { access_token = "B1", refresh_sealed = { scheme = "fake", data = "vx" }, expires_at = now + 3600 })
auth.set_client_id("fedcba9876543210fedcba9876543210")
eq("client change forgets sealed secret", calls.forget, forgets + 2)

check.done("vault")
