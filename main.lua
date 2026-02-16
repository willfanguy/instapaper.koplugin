local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local FFIUtil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local https = require("ssl.https")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local _ = require("gettext")
local T = FFIUtil.template

local base64_encode = require("mime").b64
local sha2 = require("ffi/sha2")

--------------------------------------------------------------------
-- OAuth 1.0a helpers
--------------------------------------------------------------------

-- RFC 3986 percent-encoding
local function percent_encode(str)
    if not str then return "" end
    str = tostring(str)
    return (str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function generate_nonce()
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local t = {}
    for i = 1, 32 do
        local idx = math.random(1, #chars)
        t[i] = chars:sub(idx, idx)
    end
    return table.concat(t)
end

--------------------------------------------------------------------
-- Plugin
--------------------------------------------------------------------

local Instapaper = WidgetContainer:extend{
    name = "instapaper",
    api_base = "https://www.instapaper.com",
}

-- OAuth 1.0a signature (HMAC-SHA1)
function Instapaper:oauthSign(method, request_url, all_params, consumer_secret, token_secret)
    local keys = {}
    for k in pairs(all_params) do keys[#keys + 1] = k end
    table.sort(keys)

    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = percent_encode(k) .. "=" .. percent_encode(all_params[k])
    end
    local param_string = table.concat(parts, "&")

    local base_string = method:upper()
        .. "&" .. percent_encode(request_url)
        .. "&" .. percent_encode(param_string)

    local signing_key = percent_encode(consumer_secret or "")
        .. "&" .. percent_encode(token_secret or "")

    local hmac_hex = sha2.hmac(sha2.sha1, signing_key, base_string)
    local hmac_binary = sha2.hex_to_bin(hmac_hex)
    return base64_encode(hmac_binary)
end

-- Signed POST request to the Instapaper API.
-- Returns ok, body, http_code.
-- When raw_response is true the body is returned as-is (for non-JSON endpoints).
function Instapaper:apiRequest(endpoint, body_params, raw_response)
    local request_url = self.api_base .. endpoint
    body_params = body_params or {}

    -- OAuth parameters
    local oauth = {
        oauth_consumer_key     = self.consumer_key,
        oauth_nonce            = generate_nonce(),
        oauth_signature_method = "HMAC-SHA1",
        oauth_timestamp        = tostring(os.time()),
        oauth_version          = "1.0",
    }
    if self.oauth_token and self.oauth_token ~= "" then
        oauth.oauth_token = self.oauth_token
    end

    -- Merge all params for signature computation
    local all_params = {}
    for k, v in pairs(oauth)        do all_params[k] = v end
    for k, v in pairs(body_params)  do all_params[k] = v end

    oauth.oauth_signature = self:oauthSign(
        "POST", request_url, all_params,
        self.consumer_secret, self.oauth_token_secret)

    -- Build Authorization header
    local auth_parts = {}
    local oauth_keys = {}
    for k in pairs(oauth) do oauth_keys[#oauth_keys + 1] = k end
    table.sort(oauth_keys)
    for _, k in ipairs(oauth_keys) do
        auth_parts[#auth_parts + 1] = percent_encode(k)
            .. '="' .. percent_encode(oauth[k]) .. '"'
    end
    local auth_header = "OAuth " .. table.concat(auth_parts, ", ")

    -- Build POST body
    local bp = {}
    for k, v in pairs(body_params) do
        bp[#bp + 1] = percent_encode(k) .. "=" .. percent_encode(v)
    end
    local body = table.concat(bp, "&")

    -- Execute request
    local chunks = {}
    socketutil:set_timeout(
        socketutil.DEFAULT_BLOCK_TIMEOUT,
        socketutil.DEFAULT_TOTAL_TIMEOUT)
    local result, code = https.request{
        url     = request_url,
        method  = "POST",
        headers = {
            ["Authorization"]  = auth_header,
            ["Content-Type"]   = "application/x-www-form-urlencoded",
            ["Content-Length"]  = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink   = ltn12.sink.table(chunks),
    }
    socketutil:reset_timeout()

    local response_body = table.concat(chunks)

    if result ~= 1 then
        logger.warn("Instapaper: network error on", endpoint, code)
        return false, tostring(code), 0
    end

    if raw_response then
        return code == 200, response_body, code
    end

    if code ~= 200 then
        local ok_json, err_data = pcall(JSON.decode, response_body)
        if ok_json and type(err_data) == "table" then
            for _, item in ipairs(err_data) do
                if item.type == "error" then
                    return false, item.message or "Unknown error", code
                end
            end
        end
        return false, response_body, code
    end

    return true, response_body, code
end

--------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------

function Instapaper:init()
    self.ui.menu:registerToMainMenu(self)
    self:loadSettings()
end

function Instapaper:loadSettings()
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/instapaper.lua")
    self.consumer_key       = self.settings:readSetting("consumer_key")
    self.consumer_secret    = self.settings:readSetting("consumer_secret")
    self.oauth_token        = self.settings:readSetting("oauth_token")
    self.oauth_token_secret = self.settings:readSetting("oauth_token_secret")
    self.username           = self.settings:readSetting("username")
end

function Instapaper:saveSettings()
    self.settings:saveSetting("consumer_key",       self.consumer_key)
    self.settings:saveSetting("consumer_secret",    self.consumer_secret)
    self.settings:saveSetting("oauth_token",        self.oauth_token)
    self.settings:saveSetting("oauth_token_secret", self.oauth_token_secret)
    self.settings:saveSetting("username",           self.username)
    self.settings:flush()
end

function Instapaper:isConfigured()
    return self.consumer_key    and self.consumer_key    ~= ""
       and self.consumer_secret and self.consumer_secret ~= ""
end

function Instapaper:isLoggedIn()
    return self:isConfigured()
       and self.oauth_token        and self.oauth_token        ~= ""
       and self.oauth_token_secret and self.oauth_token_secret ~= ""
end

--------------------------------------------------------------------
-- Main menu
--------------------------------------------------------------------

function Instapaper:addToMainMenu(menu_items)
    menu_items.instapaper = {
        text = _("Instapaper"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Unread articles"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:fetchAndShowArticles("unread")
                    end)
                end,
            },
            {
                text = _("Starred articles"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:fetchAndShowArticles("starred")
                    end)
                end,
            },
            {
                text = _("Archived articles"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:fetchAndShowArticles("archive")
                    end)
                end,
                separator = true,
            },
            {
                text = _("API credentials"),
                keep_menu_open = true,
                callback = function()
                    self:showCredentialsDialog()
                end,
            },
            {
                text_func = function()
                    if self:isLoggedIn() then
                        if self.username and self.username ~= "" then
                            return T(_("Log out (%1)"), self.username)
                        else
                            return _("Log out")
                        end
                    else
                        return _("Log in")
                    end
                end,
                keep_menu_open = true,
                callback = function()
                    if self:isLoggedIn() then
                        self:logout()
                    else
                        if not self:isConfigured() then
                            UIManager:show(InfoMessage:new{
                                text = _("Please set API credentials first.\nGet them at: instapaper.com/main/request_oauth_consumer_token"),
                            })
                            return
                        end
                        if not NetworkMgr:isOnline() then
                            NetworkMgr:promptWifiOn()
                            return
                        end
                        self:showLoginDialog()
                    end
                end,
            },
        },
    }
end

function Instapaper:ensureOnlineAndLoggedIn(callback)
    if not NetworkMgr:isOnline() then
        NetworkMgr:promptWifiOn()
        return
    end
    if not self:isLoggedIn() then
        UIManager:show(InfoMessage:new{
            text = _("Please configure API credentials and log in first."),
        })
        return
    end
    callback()
end

--------------------------------------------------------------------
-- Dialogs
--------------------------------------------------------------------

function Instapaper:showCredentialsDialog()
    self.cred_dialog = MultiInputDialog:new{
        title = _("Instapaper API credentials"),
        fields = {
            {
                text = self.consumer_key or "",
                hint = _("Consumer key"),
            },
            {
                text = self.consumer_secret or "",
                hint = _("Consumer secret"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.cred_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = self.cred_dialog:getFields()
                        self.consumer_key    = fields[1]
                        self.consumer_secret = fields[2]
                        -- Invalidate tokens when credentials change
                        self.oauth_token        = nil
                        self.oauth_token_secret = nil
                        self:saveSettings()
                        UIManager:close(self.cred_dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Credentials saved."),
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(self.cred_dialog)
    self.cred_dialog:onShowKeyboard()
end

function Instapaper:showLoginDialog()
    self.login_dialog = MultiInputDialog:new{
        title = _("Instapaper login"),
        fields = {
            {
                text = self.username or "",
                hint = _("Email or username"),
            },
            {
                text = "",
                hint = _("Password, if you have one"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.login_dialog)
                    end,
                },
                {
                    text = _("Login"),
                    is_enter_default = true,
                    callback = function()
                        local fields = self.login_dialog:getFields()
                        UIManager:close(self.login_dialog)
                        if fields[1] and fields[1] ~= "" then
                            self:xauthLogin(fields[1], fields[2] or "")
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Username is required."),
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.login_dialog)
    self.login_dialog:onShowKeyboard()
end

--------------------------------------------------------------------
-- Auth
--------------------------------------------------------------------

function Instapaper:xauthLogin(username, password)
    UIManager:show(InfoMessage:new{
        text = _("Logging in..."),
        timeout = 1,
    })

    -- Temporarily clear tokens for xAuth (no token yet)
    local prev_t, prev_s = self.oauth_token, self.oauth_token_secret
    self.oauth_token, self.oauth_token_secret = nil, nil

    -- raw_response = true because xAuth returns qline, not JSON
    local ok, body, code = self:apiRequest("/api/1/oauth/access_token", {
        x_auth_username = username,
        x_auth_password = password,
        x_auth_mode     = "client_auth",
    }, true)

    if ok then
        local token  = body:match("oauth_token=([^&]+)")
        local secret = body:match("oauth_token_secret=([^&]+)")
        if token and secret then
            self.oauth_token        = token
            self.oauth_token_secret = secret
            self.username           = username
            self:saveSettings()
            UIManager:show(InfoMessage:new{
                text = _("Login successful!"),
                timeout = 2,
            })
            return
        end
    end

    -- Restore previous tokens on failure
    self.oauth_token, self.oauth_token_secret = prev_t, prev_s
    UIManager:show(InfoMessage:new{
        text = T(_("Login failed (HTTP %1)"), tostring(code)),
    })
end

function Instapaper:logout()
    self.oauth_token        = nil
    self.oauth_token_secret = nil
    self.username           = nil
    self:saveSettings()
    UIManager:show(InfoMessage:new{
        text = _("Logged out."),
        timeout = 2,
    })
end

--------------------------------------------------------------------
-- Bookmarks
--------------------------------------------------------------------

function Instapaper:fetchAndShowArticles(folder_id)
    UIManager:show(InfoMessage:new{
        text = _("Fetching articles..."),
        timeout = 1,
    })

    local params = { limit = "25" }
    if folder_id then
        params.folder_id = folder_id
    end

    local ok, body, code = self:apiRequest("/api/1/bookmarks/list", params)

    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to fetch articles: %1"), body or tostring(code)),
        })
        return
    end

    local parse_ok, data = pcall(JSON.decode, body)
    if not parse_ok or type(data) ~= "table" then
        UIManager:show(InfoMessage:new{
            text = _("Failed to parse article list."),
        })
        return
    end

    -- /api/1/bookmarks/list returns array of objects, first is user info
    local bookmarks = {}
    if type(data) == "table" then
        for _, item in ipairs(data) do
            if type(item) == "table" and item.type == "bookmark" then
                table.insert(bookmarks, item)
            end
        end
    end
    
    if #bookmarks == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No articles found."),
        })
        return
    end

    self:showArticleMenu(bookmarks, folder_id)
end

function Instapaper:showArticleMenu(bookmarks, folder_id)
    local folder_names = {
        unread  = _("Unread"),
        starred = _("Starred"),
        archive = _("Archive"),
    }

    local menu
    local menu_items = {}
    for _, bm in ipairs(bookmarks) do
        local title = bm.title
        if not title or title == "" or type(title) ~= "string" then
            title = "Untitled"
        end
        
        local progress_str = nil
        if bm.progress and bm.progress > 0 then
            progress_str = string.format("%d%%", bm.progress * 100)
        end
        
        local item = {
            text = title,
            _bookmark = bm,
            callback = function()
                self:downloadAndOpenArticle(bm)
            end,
            hold_callback = function()
                self:showArticleActions(bm, menu, folder_id)
            end,
            hold_keep_menu_open = true,
        }
        
        if progress_str then
            item.mandatory = progress_str
        end
        
        table.insert(menu_items, item)
    end

    local menu_title = folder_names[folder_id] or folder_id or "Articles"
    if type(menu_title) ~= "string" then
        menu_title = "Articles"
    end
    
    menu = Menu:new{
        title = "Instapaper - " .. menu_title,
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        close_callback = function()
            UIManager:close(menu)
        end,
        onMenuHold = function(_, item)
            if item and type(item.hold_callback) == "function" then
                item.hold_callback()
            end
            return true
        end,
    }

    UIManager:show(menu, "full")
end

function Instapaper:showArticleActions(bookmark, parent_menu, folder_id)
    local title = bookmark.title
    if not title or title == "" then
        title = _("Untitled")
    end
    
    local actions_dialog
    actions_dialog = ButtonDialog:new{
        title = title,
        buttons = {
            {
                {
                    text = _("Archive"),
                    callback = function()
                        UIManager:close(actions_dialog)
                        self:archiveBookmark(
                            bookmark.bookmark_id, parent_menu, folder_id)
                    end,
                },
                {
                    text = _("Star"),
                    callback = function()
                        UIManager:close(actions_dialog)
                        self:starBookmark(bookmark.bookmark_id)
                    end,
                },
            },
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(actions_dialog)
                        self:deleteBookmark(
                            bookmark.bookmark_id, parent_menu, folder_id)
                    end,
                },
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(actions_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(actions_dialog)
end

function Instapaper:downloadAndOpenArticle(bookmark)
    UIManager:show(InfoMessage:new{
        text = _("Downloading article..."),
        timeout = 1,
    })

    -- get_text returns HTML, not JSON
    local ok, html, code = self:apiRequest("/api/1/bookmarks/get_text", {
        bookmark_id = tostring(bookmark.bookmark_id),
    }, true)

    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed (HTTP %1)"), tostring(code)),
        })
        return
    end

    -- Save as HTML file
    local download_dir = DataStorage:getDataDir() .. "/instapaper"
    lfs.mkdir(download_dir)

    local safe_title = (bookmark.title or "article")
        :gsub("[/\\%?%%%*%:%|%\"%<%>]", "_")
        :sub(1, 100)
    local filepath = download_dir .. "/"
        .. tostring(bookmark.bookmark_id) .. "_" .. safe_title .. ".html"

    local f = io.open(filepath, "w")
    if not f then
        UIManager:show(InfoMessage:new{
            text = _("Could not save article file."),
        })
        return
    end
    f:write(html)
    f:close()

    -- Open in KOReader
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(filepath)
end

--------------------------------------------------------------------
-- Bookmark actions
--------------------------------------------------------------------

function Instapaper:archiveBookmark(bookmark_id, parent_menu, folder_id)
    local ok, body = self:apiRequest("/api/1/bookmarks/archive", {
        bookmark_id = tostring(bookmark_id),
    })
    UIManager:show(InfoMessage:new{
        text = ok and _("Archived.") or T(_("Failed: %1"), body or ""),
        timeout = 2,
    })
    if ok and parent_menu then
        UIManager:close(parent_menu)
        self:fetchAndShowArticles(folder_id)
    end
end

function Instapaper:deleteBookmark(bookmark_id, parent_menu, folder_id)
    local ok, body = self:apiRequest("/api/1/bookmarks/delete", {
        bookmark_id = tostring(bookmark_id),
    })
    UIManager:show(InfoMessage:new{
        text = ok and _("Deleted.") or T(_("Failed: %1"), body or ""),
        timeout = 2,
    })
    if ok and parent_menu then
        UIManager:close(parent_menu)
        self:fetchAndShowArticles(folder_id)
    end
end

function Instapaper:starBookmark(bookmark_id)
    local ok, body = self:apiRequest("/api/1/bookmarks/star", {
        bookmark_id = tostring(bookmark_id),
    })
    UIManager:show(InfoMessage:new{
        text = ok and _("Starred.") or T(_("Failed: %1"), body or ""),
        timeout = 2,
    })
end

return Instapaper
