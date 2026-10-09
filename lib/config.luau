--!strict
-- Constants shared by both halves. The two base URLs can be pointed at a local
-- mock server (tests/mock_spotify.py) through the environment of the process
-- the half runs in.

local function env(name: string, default: string): string
	local v = tern.getenv(name)
	if v == nil or v == "" then
		return default
	end
	return (string.gsub(v, "/+$", ""))
end

return {
	API = env("TERN_SPOTIFY_API", "https://api.spotify.com/v1"),
	ACCOUNTS = env("TERN_SPOTIFY_ACCOUNTS", "https://accounts.spotify.com"),
	REDIRECT_URI = "http://127.0.0.1:8888/callback",
	SCOPES = {
		"user-read-playback-state",
		"user-modify-playback-state",
		"user-read-currently-playing",
		"playlist-read-private",
		"playlist-read-collaborative",
		"user-library-read",
		-- Like / unlike, and adding the current track to your playlists.
		"user-library-modify",
		"playlist-modify-public",
		"playlist-modify-private",
	},
	BLOCK = "spotify.player",
	-- kv keys
	KEY_CLIENT = "client_id",
	KEY_PENDING = "pending",
	KEY_AUTH = "auth",
	KEY_NOW = "now",
}
