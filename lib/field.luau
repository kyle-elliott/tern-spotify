--!strict
-- A one-line text field the block owns: text plus a caret kept as a byte
-- offset on a UTF-8 character boundary. Tern's `input` node wants the caret
-- in UTF-16 code units, which `utf16` converts to.

export type Field = { text: string, cursor: number }

export type KeyLike = { name: string, text: string?, ctrl: boolean, alt: boolean, meta: boolean, shift: boolean }

local M = {}

function M.new(text: string?): Field
	local t = text or ""
	return { text = t, cursor = #t }
end

local function is_cont(b: number?): boolean
	return b ~= nil and b >= 0x80 and b < 0xC0
end

-- Inserts `s` at the caret; line breaks and control characters become spaces or vanish.
function M.insert(f: Field, s: string)
	local clean = string.gsub(string.gsub(s, "[\r\n\t]+", " "), "%c", "")
	f.text = string.sub(f.text, 1, f.cursor) .. clean .. string.sub(f.text, f.cursor + 1)
	f.cursor += #clean
end

local function prev(f: Field): number
	local i = f.cursor
	if i <= 0 then
		return 0
	end
	i -= 1
	while i > 0 and is_cont(string.byte(f.text, i + 1)) do
		i -= 1
	end
	return i
end

local function after(f: Field): number
	local i = f.cursor
	if i >= #f.text then
		return #f.text
	end
	i += 1
	while i < #f.text and is_cont(string.byte(f.text, i + 1)) do
		i += 1
	end
	return i
end

function M.backspace(f: Field)
	local p = prev(f)
	f.text = string.sub(f.text, 1, p) .. string.sub(f.text, f.cursor + 1)
	f.cursor = p
end

function M.delete(f: Field)
	local n = after(f)
	f.text = string.sub(f.text, 1, f.cursor) .. string.sub(f.text, n + 1)
end

function M.left(f: Field)
	f.cursor = prev(f)
end

function M.right(f: Field)
	f.cursor = after(f)
end

function M.clear(f: Field)
	f.text, f.cursor = "", 0
end

-- The caret as UTF-16 code units (what `input`'s `cursor` prop takes).
function M.utf16(f: Field): number
	local n = 0
	local ok = pcall(function()
		for _, cp in utf8.codes(string.sub(f.text, 1, f.cursor)) do
			n += if cp > 0xFFFF then 2 else 1
		end
	end)
	return if ok then n else f.cursor
end

-- Applies an editing key; returns whether it was one. Enter, Escape, Tab and
-- the vertical arrows are left to the caller.
function M.key(f: Field, key: KeyLike): boolean
	local name = key.name
	if name == "paste" then
		M.insert(f, key.text or "")
	elseif name == "backspace" then
		if key.ctrl or key.alt or key.meta then
			-- delete the word before the caret
			local before = string.sub(f.text, 1, f.cursor)
			local trimmed = string.match(before, "^(.-)%S*%s*$") or ""
			f.text = trimmed .. string.sub(f.text, f.cursor + 1)
			f.cursor = #trimmed
		else
			M.backspace(f)
		end
	elseif name == "delete" then
		M.delete(f)
	elseif name == "left" then
		M.left(f)
	elseif name == "right" then
		M.right(f)
	elseif name == "home" then
		f.cursor = 0
	elseif name == "end" then
		f.cursor = #f.text
	elseif key.text ~= nil and key.text ~= "" and not key.meta and not (key.ctrl and not key.alt) then
		-- Ctrl+Alt with text is AltGr on Windows layouts; plain Ctrl/Cmd chords aren't typing.
		M.insert(f, key.text)
	else
		return false
	end
	return true
end

return M
