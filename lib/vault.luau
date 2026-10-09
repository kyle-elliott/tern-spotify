--!strict
-- Keeps one secret (the Spotify refresh token) out of the plugin's plain kv file, using
-- the operating system's own protection through a short process. The host half can't use
-- `tern.secrets` (window-only), so this is the host-side equivalent:
--
--   windows  DPAPI (CurrentUser) through PowerShell; the ciphertext lives in kv
--   macos    the login keychain through /usr/bin/security; kv only holds a version tag
--   linux    libsecret through secret-tool; kv only holds a version tag
--
-- `seal` succeeds only after the secret has been read back unchanged, so a protection
-- that doesn't really work on some machine (it can't be tested everywhere) is never relied
-- on: callers fall back to storing the secret in kv as before.
--
-- Protects the file at rest (other accounts, backups, synced folders, a copied file); not
-- against programs running as the same user, which can ask the same OS service.

export type Sealed = { scheme: string, data: string }

local proc = require("./proc")

local M = {}
local SERVICE = "tern-spotify"
local ACCOUNT = "refresh-token"
local ENTROPY = "tern-spotify/refresh-token" -- DPAPI optional entropy: binds blobs to this use

local DPAPI_PRELUDE = "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Security; "
	.. "$e=[Text.Encoding]::UTF8.GetBytes('" .. ENTROPY .. "'); "
	.. "$s=[Security.Cryptography.DataProtectionScope]::CurrentUser; "
	.. "$in=[Console]::In.ReadToEnd().Trim(); "

local DPAPI_SEAL = DPAPI_PRELUDE
	.. "[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($in),$e,$s))"

local DPAPI_OPEN = DPAPI_PRELUDE
	.. "[Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($in),$e,$s))"

-- The scheme this machine would use, or nil (iOS has no processes; other systems none known).
function M.scheme(): string?
	local os = tern.runtime.os
	if os == "windows" then
		return "dpapi"
	elseif os == "macos" then
		return "keychain"
	elseif os == "linux" then
		return "secret-tool"
	end
	return nil
end

-- Reads a sealed secret back.
function M.open(sealed: Sealed, cb: (secret: string?, err: string?) -> ())
	if sealed.scheme == "dpapi" then
		proc.run(proc.powershell_argv(DPAPI_OPEN), sealed.data, cb)
	elseif sealed.scheme == "keychain" then
		proc.run({ "/usr/bin/security", "find-generic-password", "-a", ACCOUNT, "-s", SERVICE, "-w" }, nil, cb)
	elseif sealed.scheme == "secret-tool" then
		proc.run({ "secret-tool", "lookup", "service", SERVICE, "account", ACCOUNT }, nil, cb)
	else
		cb(nil, "unknown protection " .. sealed.scheme)
	end
end

-- A new version tag for schemes that keep the secret outside kv, so a stored sealed value
-- changes whenever the secret does (callers compare them to spot a replaced sign-in).
local function version(): string
	return string.format("%d-%d", os.time(), math.floor(tern.now() * 1000) % 1000000000)
end

-- Protects `secret` and answers the value to store, or nil (with why) when this machine
-- can't: then the caller keeps the secret in kv. Verified by reading it back.
function M.seal(secret: string, cb: (sealed: Sealed?, err: string?) -> ())
	local scheme = M.scheme()
	if scheme == nil then
		cb(nil, "no protection on " .. tern.runtime.os)
		return
	end
	local function verify(sealed: Sealed)
		M.open(sealed, function(back, err)
			if back == secret then
				cb(sealed, nil)
			else
				cb(nil, "read-back failed: " .. (err or "different value"))
			end
		end)
	end
	if scheme == "dpapi" then
		proc.run(proc.powershell_argv(DPAPI_SEAL), secret, function(out, err)
			if out == nil or out == "" then
				cb(nil, err or "no output")
				return
			end
			verify({ scheme = "dpapi", data = out })
		end)
	elseif scheme == "keychain" then
		-- `security` takes the password as an argument (no stdin form); it is visible to
		-- same-user process listings for the moment the process runs.
		proc.run({ "/usr/bin/security", "add-generic-password", "-U", "-a", ACCOUNT, "-s", SERVICE, "-l", "Tern Spotify sign-in", "-w", secret }, nil, function(out, err)
			if out == nil then
				cb(nil, err)
				return
			end
			verify({ scheme = "keychain", data = version() })
		end)
	else
		proc.run({ "secret-tool", "store", "--label=Tern Spotify sign-in", "service", SERVICE, "account", ACCOUNT }, secret, function(out, err)
			if out == nil then
				cb(nil, err)
				return
			end
			verify({ scheme = "secret-tool", data = version() })
		end)
	end
end

-- Deletes a secret kept outside kv (best effort; a DPAPI blob only lives in kv).
function M.forget(sealed: Sealed?)
	if sealed == nil then
		return
	end
	local argv: { string }? = nil
	if sealed.scheme == "keychain" then
		argv = { "/usr/bin/security", "delete-generic-password", "-a", ACCOUNT, "-s", SERVICE }
	elseif sealed.scheme == "secret-tool" then
		argv = { "secret-tool", "clear", "service", SERVICE, "account", ACCOUNT }
	end
	if argv then
		proc.run(argv, nil, function() end)
	end
end

return M
