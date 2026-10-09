-- Unit tests for the modules that don't touch `tern`. Run: .tools/luau.exe tests/pure.luau
local sha256 = require("../lib/sha256")
local url = require("../lib/url")
local field = require("../lib/field")
local model = require("../lib/model")

local check = require("./check")
local eq = check.eq

-- SHA-256: FIPS vectors and every padding boundary (55/56 bytes end in one or two blocks).
local vectors = {
	{ "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
	{ "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
	{ "abcdbcdecdefdefgefghfghighijhijkijkljklmnlmnomnopnopq", "a57ed99266a7c7be3eaee2ffa23f54ff042a4829fa036cf5ea83d7e3de0c666e" },
	{ string.rep("a", 55), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318" },
	{ string.rep("a", 56), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a" },
	{ string.rep("a", 63), "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34" },
	{ string.rep("a", 64), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb" },
	{ string.rep("a", 65), "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0" },
	{ string.rep("a", 119), "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb" },
	{ string.rep("a", 120), "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c" },
	{ string.rep("a", 1000), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3" },
}
for _, v in vectors do
	eq("sha256 len " .. #v[1], sha256.hex(v[1]), v[2])
end
local all = {}
for i = 0, 255 do
	all[i + 1] = string.char(i)
end
eq("sha256 all bytes", sha256.hex(table.concat(all)), "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880")
-- RFC 7636 appendix B: the verifier whose S256 challenge is E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM.
eq("pkce rfc7636", sha256.hex("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "13d31e961a1ad8ec2f16b10c4c982e0876a878ad6df144566ee1894acb70f9c3")
eq("digest is binary", #sha256.digest("x"), 32)

-- URL helpers.
eq("encode unreserved", url.encode("aZ09-._~"), "aZ09-._~")
eq("encode reserved", url.encode("a b/c:d?&=+"), "a%20b%2Fc%3Ad%3F%26%3D%2B")
eq("encode utf8", url.encode("é"), "%C3%A9")
eq("form sorted", url.form({ b = "2", a = "x y" }), "a=x%20y&b=2")
eq("with_query none", url.with_query("https://h/p", {}), "https://h/p")
eq("with_query", url.with_query("https://h/p", { q = "a&b" }), "https://h/p?q=a%26b")
eq("with_query append", url.with_query("https://h/p?x=1", { y = 2 }), "https://h/p?x=1&y=2")

local q = url.parse_query("http://127.0.0.1:8888/callback?code=AQB%2Fx-y&state=s+1#frag")
eq("parse code", q.code, "AQB/x-y")
eq("parse state", q.state, "s 1")
local bare = url.parse_query("code=abc&error=access_denied")
eq("parse bare", bare.error, "access_denied")
eq("parse none", next(url.parse_query("http://127.0.0.1:8888/callback")), nil)
eq("roundtrip", url.decode(url.encode("a+b c%/é")), "a+b c%/é")

-- Text fields: UTF-8 safe editing, UTF-16 caret.
local function key(name: string, text: string?, mods: { [string]: boolean }?): any
	local m = mods or {}
	return { name = name, text = text, ctrl = m.ctrl == true, alt = m.alt == true, meta = m.meta == true, shift = m.shift == true }
end
local f = field.new()
for _, ch in { "B", "j", "ö", "r", "k" } do
	field.key(f, key(ch, ch))
end
eq("field typed", f.text, "Björk")
eq("field cursor bytes", f.cursor, 6)
eq("field utf16", field.utf16(f), 5)
field.key(f, key("left"))
field.key(f, key("left"))
eq("field left over ascii", f.cursor, 4)
field.key(f, key("left"))
eq("field left over 2-byte char", f.cursor, 2)
field.key(f, key("backspace"))
eq("field backspace", f.text, "Börk")
f = field.new("Björk")
f.cursor = 2
field.key(f, key("delete"))
eq("field delete multibyte", f.text, "Bjrk")
f = field.new("hello big world")
field.key(f, key("backspace", nil, { ctrl = true }))
eq("field word delete", f.text, "hello big ")
eq("field ctrl+c is not typing", field.key(f, key("c", "c", { ctrl = true })), false)
eq("field altgr types", field.key(f, key("q", "@", { ctrl = true, alt = true })), true)
f = field.new("")
field.key(f, key("paste", "line one\r\nline two"))
eq("field paste flattens", f.text, "line one line two")
f = field.new("😀a")
eq("field utf16 surrogate", field.utf16(f), 3)

-- Model readers: nulls, missing fields, renamed keys.
local null = newproxy() -- tern.json.null is userdata, not a table
local pb = model.playback({
	is_playing = true,
	progress_ms = 1234,
	shuffle_state = false,
	repeat_state = "context",
	device = { id = "d1", name = "Desk", type = "Computer", is_active = true, volume_percent = 40 },
	item = {
		uri = "spotify:track:1",
		name = "Song",
		type = "track",
		duration_ms = 200000,
		artists = { { name = "A" }, { name = "B" } },
		album = { name = "Alb", uri = "spotify:album:1", images = {
			{ url = "big", width = 640 },
			{ url = "mid", width = 300 },
			{ url = "small", width = 64 },
		} },
	},
})
assert(pb and pb.item and pb.device)
eq("model artists", pb.item.artists, "A, B")
eq("model image pick", pb.item.image, "mid")
eq("model repeat", pb.repeat_mode, "context")
eq("model volume", pb.device.volume, 40)
eq("model nil playback", model.playback(nil), nil)
eq("model image no widths", model.image({ { url = "only" } }), "only")
eq("model image small only", model.image({ { url = "s", width = 64 }, { url = "t", width = 120 } }), "t")
local s = model.search({ playlists = { items = { null, { uri = "spotify:playlist:x", id = "x", name = "P", items = { total = 7 } } } } })
eq("model search skips null playlists", #s.playlists, 1)
eq("model playlist renamed count", s.playlists[1].total, 7)
local page = model.track_page({ items = { { track = null }, { is_local = true, track = { uri = "spotify:local:1" } }, { track = { uri = "spotify:track:2", name = "T" } } }, next = "n" })
eq("model track page skips null/local", #page.items, 1)
eq("model track page next", page.next, "n")
local ep = model.track({ uri = "spotify:episode:1", type = "episode", name = "Ep", show = { name = "Show", images = { { url = "s" } } } })
eq("model episode show", ep and ep.artists, "Show")
eq("duration", model.duration(187000), "3:07")
eq("duration hours", model.duration(3723000), "1:02:03")

check.done("pure")
