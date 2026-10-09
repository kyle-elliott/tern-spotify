--!strict
-- The player block's sign-in flow: Client ID, opening Spotify's sign-in page, and
-- finishing with the redirect address (pasted, typed or handed over by the window half).

local auth = require("./auth")
local field = require("./field")
local state_lib = require("./state")
local text = require("./text")

type State = state_lib.State

local M = {}

-- The sign-in step: "client" (needs a Client ID), "start" (ready to open Spotify) or "redirect".
function M.step(): string
	if auth.client_id() == nil then
		return "client"
	end
	return if auth.pending() then "redirect" else "start"
end

-- The text field the current sign-in step needs (nil: none, the step is a button).
function M.field_for_step(): string?
	local current = M.step()
	return if current == "client" then "client_id" elseif current == "redirect" then "redirect" else nil
end

function M.begin_signin(state: State)
	state.signin.busy, state.signin.error = "Opening Spotify…", nil
	local cx = state.cx
	auth.begin(function(authorize, err)
		state.signin.busy = nil
		if authorize == nil then
			state.signin.error = err
		else
			field.clear(state.fields.redirect)
			cx:open(authorize)
			state_lib.set_focus(state, "redirect")
		end
		cx:render()
	end)
end

function M.submit_client(state: State)
	local err = auth.set_client_id(state.fields.client_id.text)
	if err then
		state.signin.error = err
		return
	end
	state.signin.error = nil
	field.clear(state.fields.client_id)
	M.begin_signin(state)
end

function M.submit_redirect(state: State)
	local address = state.fields.redirect.text
	if text.is_blank(address) then
		return
	end
	state.signin.busy, state.signin.error = "Signing in…", nil
	auth.complete(address, function(err)
		state.signin.busy = nil
		if err then
			state.signin.error = err
		else
			field.clear(state.fields.redirect)
		end
		state.cx:render()
	end)
end

function M.signin_action(state: State, act: string)
	if act == "signin" then
		M.begin_signin(state)
	elseif act == "submit_client" then
		M.submit_client(state)
	elseif act == "submit_redirect" then
		M.submit_redirect(state)
	elseif act == "open_link" or act == "copy_link" then
		local p = auth.pending()
		if p then
			local link = auth.authorize_url(p)
			if act == "open_link" then
				state.cx:open(link)
			else
				state.cx:copy(link)
				state_lib.flash(state, "Sign-in link copied", "success")
			end
		end
	elseif act == "restart" then
		auth.cancel()
		field.clear(state.fields.redirect)
		state.signin.error = nil
		state_lib.set_focus(state, nil)
	elseif act == "change_client" then
		auth.clear_client_id()
		state.signin.error = nil
		state_lib.set_focus(state, "client_id")
	end
end

return M
