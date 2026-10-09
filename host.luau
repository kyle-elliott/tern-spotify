--!strict
-- Host half: the `spotify.player` block and the session coordinator that
-- polls Spotify for every player block on this host and publishes the
-- now-playing record for the status line.

local auth = require("./lib/auth")
local player = require("./lib/player")
local session = require("./lib/session")

tern.block.define("player", player.def)
session.start()
-- Seal a refresh token stored plain by an older version (or after a failed seal).
auth.migrate()
