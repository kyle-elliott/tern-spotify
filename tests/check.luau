-- Assertions shared by the unit tests: `eq` records a failure and keeps going, so one run
-- reports every mismatch; `done` fails the run when any were recorded.

local M = {}

local failures = 0

function M.eq(name: string, got: any, want: any)
	if got ~= want then
		failures += 1
		print(string.format("FAIL %s\n  got:  %s\n  want: %s", name, tostring(got), tostring(want)))
	end
end

function M.done(suite: string)
	if failures > 0 then
		error(string.format("%s: %d test(s) failed", suite, failures))
	end
	print(suite .. ": all tests passed")
end

return M
