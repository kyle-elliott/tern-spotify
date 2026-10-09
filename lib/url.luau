--!strict
-- Percent-encoding, form/query building and query parsing.

local M = {}

-- Percent-encodes everything outside RFC 3986's unreserved set.
function M.encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

-- Decodes `%XX` escapes and, in query strings, `+` as a space.
function M.decode(s: string): string
	local plus = string.gsub(s, "%+", " ")
	return (string.gsub(plus, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end))
end

-- `a=1&b=2` from a map, keys sorted so the output is deterministic. Nil values are skipped.
function M.form(fields: { [string]: any }): string
	local keys = {}
	for k in fields do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts = {}
	for _, k in keys do
		table.insert(parts, M.encode(k) .. "=" .. M.encode(tostring(fields[k])))
	end
	return table.concat(parts, "&")
end

-- `base` with `fields` appended as a query string (none when empty).
function M.with_query(base: string, fields: { [string]: any }?): string
	if fields == nil or next(fields) == nil then
		return base
	end
	local sep = if string.find(base, "?", 1, true) then "&" else "?"
	return base .. sep .. M.form(fields)
end

-- The query parameters of a URL (or of a bare `a=1&b=2` string). A fragment is ignored.
function M.parse_query(s: string): { [string]: string }
	local out: { [string]: string } = {}
	local query = string.match(s, "%?([^#]*)") or (if string.find(s, "=", 1, true) then string.match(s, "^([^#]*)") else nil)
	if query == nil then
		return out
	end
	for pair in string.gmatch(query, "[^&]+") do
		local k, v = string.match(pair, "^([^=]*)=?(.*)$")
		if k and k ~= "" then
			out[M.decode(k)] = M.decode(v or "")
		end
	end
	return out
end

return M
