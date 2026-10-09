--!strict
-- Short helper processes (OS randomness for sign-in, OS protection for the refresh token).

local text = require("./text")

local M = {}

local TIMEOUT_MS = 20000

-- Windows PowerShell's full path (a daemon's PATH may lack it).
function M.powershell(): string
	local root = tern.getenv("SystemRoot") or "C:\\Windows"
	return root .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
end

-- `powershell -Command script` as an argv.
function M.powershell_argv(script: string): { string }
	return { M.powershell(), "-NoProfile", "-NonInteractive", "-Command", script }
end

-- Runs `argv` (with `stdin`, when given) and answers its trimmed stdout once it exits 0,
-- else why not. Never raises: a program that can't start is reported through `cb` too.
function M.run(argv: { string }, stdin: string?, cb: (out: string?, err: string?) -> ())
	local ok, err = pcall(function()
		tern.process.run(argv, { stdin = stdin, timeout_ms = TIMEOUT_MS }, function(r: ProcessResult, _cx: WindowCx?)
			if r.status ~= 0 then
				local why = text.trim(r.stderr)
				cb(nil, if r.timed_out then "timed out" elseif why ~= "" then why else "exit " .. r.status)
			else
				cb(text.trim(r.stdout), nil)
			end
		end)
	end)
	if not ok then
		cb(nil, tostring(err))
	end
end

return M
