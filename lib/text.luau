--!strict
-- Small string helpers shared by both halves.

local M = {}

-- `s` without leading and trailing whitespace.
function M.trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

-- Whether `s` holds nothing but whitespace.
function M.is_blank(s: string): boolean
	return string.match(s, "^%s*$") ~= nil
end

-- `s` cut to at most `n` characters (UTF-8 aware), with an ellipsis when cut.
function M.truncate(s: string, n: number): string
	local ok, len = pcall(utf8.len, s)
	if not ok or type(len) ~= "number" or len <= n then
		return s
	end
	local cut = utf8.offset(s, n) or #s
	return string.sub(s, 1, cut - 1) .. "…"
end

return M
