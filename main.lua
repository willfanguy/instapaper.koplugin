local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local FFIUtil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local https = require("ssl.https")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local util = require("util")
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
-- Profile Actions
--------------------------------------------------------------------

function Instapaper:onInstapaperSync()
    self:ensureOnlineAndLoggedIn(function()
        self:syncToDevice()
    end)
    return true
end

function Instapaper:onDispatcherRegisterActions()
    Dispatcher:registerAction("instapaper_sync",
        { category = "none", event = "InstapaperSync", title = _("Instapaper sync"), general = true, separator = true, })
end

--------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------

-- Inject "instapaper" into KOReader's main-menu order list so the entry
-- appears near the top instead of being appended at the bottom (the default
-- for unlisted plugin entries). Modifies the cached order table in place;
-- the menu builder reads this table when the user first opens the main menu.
local function injectIntoMainMenu(module_name)
    local ok, order = pcall(require, module_name)
    if not ok or not order or type(order.main) ~= "table" then return end
    for _, v in ipairs(order.main) do
        if v == "instapaper" then return end  -- idempotent
    end
    for i, item in ipairs(order.main) do
        if item == "open_last_document" then
            table.insert(order.main, i + 1, "instapaper")
            return
        end
    end
    -- anchor not found (KOReader internals shifted) -- fall back to bottom
end

function Instapaper:init()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:loadSettings()
    injectIntoMainMenu("ui/elements/filemanager_menu_order")
    injectIntoMainMenu("ui/elements/reader_menu_order")
end

function Instapaper:loadSettings()
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/instapaper.lua")
    self.consumer_key       = self.settings:readSetting("consumer_key")
    self.consumer_secret    = self.settings:readSetting("consumer_secret")
    self.oauth_token        = self.settings:readSetting("oauth_token")
    self.oauth_token_secret = self.settings:readSetting("oauth_token_secret")
    self.username           = self.settings:readSetting("username")
    self.article_limit      = self.settings:readSetting("article_limit") or 50
    self.output_format      = self.settings:readSetting("output_format") or "html"
    self.include_images     = self.settings:readSetting("include_images") or false
    self.after_download_action = self.settings:readSetting("after_download_action") or "none"
    self.cache_folder       = self.settings:readSetting("cache_folder")
    -- auto_archive_on_sync defaults to true; nil-coalesce treats explicit false correctly
    local aaos = self.settings:readSetting("auto_archive_on_sync")
    if aaos == nil then aaos = true end
    self.auto_archive_on_sync = aaos
    self.articles_per_page  = self.settings:readSetting("articles_per_page") or 25
    self.sort_by            = self.settings:readSetting("sort_by") or "saved_desc"
end

function Instapaper:saveSettings()
    self.settings:saveSetting("consumer_key",       self.consumer_key)
    self.settings:saveSetting("consumer_secret",    self.consumer_secret)
    self.settings:saveSetting("oauth_token",        self.oauth_token)
    self.settings:saveSetting("oauth_token_secret", self.oauth_token_secret)
    self.settings:saveSetting("username",           self.username)
    self.settings:saveSetting("article_limit",      self.article_limit)
    self.settings:saveSetting("output_format",      self.output_format)
    self.settings:saveSetting("include_images",     self.include_images)
    self.settings:saveSetting("after_download_action", self.after_download_action)
    self.settings:saveSetting("cache_folder",       self.cache_folder)
    self.settings:saveSetting("auto_archive_on_sync", self.auto_archive_on_sync)
    self.settings:saveSetting("articles_per_page", self.articles_per_page)
    self.settings:saveSetting("sort_by",            self.sort_by)
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
    -- Count legacy-format files so the "Rename downloaded articles" entry
    -- can dim itself once the migration is complete.
    local function countLegacyFiles()
        local dir = self:getDownloadDir()
        if not lfs.attributes(dir, "mode") then return 0 end
        local n = 0
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".."
              and (entry:match("^(%d+)_.+%.html$") or entry:match("^(%d+)_.+%.epub$")) then
                n = n + 1
            end
        end
        return n
    end

    local function failureCount()
        local failures = self:loadFailureList()
        return failures and #failures or 0
    end

    menu_items.instapaper = {
        text = _("Instapaper"),
        sorting_hint = "main",
        sub_item_table = {
            {
                text = _("Sync now"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:syncToDevice()
                    end)
                end,
                separator = true,
            },
            {
                text = _("Articles"),
                callback = function()
                    self:showUnreadFromCache()
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
                text = _("Custom folders"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:fetchAndShowUserFolders()
                    end)
                end,
            },
            {
                text = _("Clear downloads cache"),
                keep_menu_open = true,
                callback = function()
                    self:clearDownloadsCache()
                end,
            },
            {
                text_func = function()
                    local n = failureCount()
                    if n > 0 then
                        return T(_("View last sync failures (%1)"), tostring(n))
                    end
                    return _("View last sync failures")
                end,
                enabled_func = function()
                    return failureCount() > 0
                end,
                keep_menu_open = true,
                callback = function()
                    self:showLastSyncFailures()
                end,
            },
            {
                text_func = function()
                    local n = countLegacyFiles()
                    if n > 0 then
                        return T(_("Rename downloaded articles (%1)"), tostring(n))
                    end
                    return _("Rename downloaded articles")
                end,
                enabled_func = function()
                    return countLegacyFiles() > 0
                end,
                keep_menu_open = true,
                callback = function()
                    self:confirmAndMigrateFilenames()
                end,
                separator = true,
            },
            {
                text = _("Settings"),
                keep_menu_open = true,
                callback = function()
                    self:showSettingsDialog()
                end,
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
                        NetworkMgr:runWhenOnline(function()
                            self:showLoginDialog()
                        end)
                    end
                end,
            },
        },
    }
end

function Instapaper:ensureOnlineAndLoggedIn(callback)
    if not self:isLoggedIn() then
        UIManager:show(InfoMessage:new{
            text = _("Please configure API credentials and log in first."),
        })
        return
    end
    NetworkMgr:runWhenOnline(function()
        callback()
    end)
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

function Instapaper:showSettingsDialog()
    local limit_choices = { 10, 25, 50, 100, 200, 500 }
    local current_limit = self.article_limit or 50

    -- Find current index for limit
    local limit_idx = 2  -- default to 25
    for i, v in ipairs(limit_choices) do
        if v == current_limit then
            limit_idx = i
            break
        end
    end

    local output_format = self.output_format or "html"
    local include_images = self.include_images or false
    local after_download_action = self.after_download_action or "none"
    local cache_folder = self.cache_folder
    local auto_archive_on_sync = self.auto_archive_on_sync

    local perpage_choices = { 14, 20, 25, 30, 40 }
    local perpage_idx = 3  -- default 25
    for i, v in ipairs(perpage_choices) do
        if v == self.articles_per_page then perpage_idx = i; break end
    end

    local sort_choices = {
        { value = "saved_desc", label = _("Newest first") },
        { value = "saved_asc",  label = _("Oldest first") },
        { value = "title_asc",  label = _("Title A-Z")   },
    }
    local sort_idx = 1
    for i, s in ipairs(sort_choices) do
        if s.value == self.sort_by then sort_idx = i; break end
    end

    local settings_dialog
    local function rebuildSettingsDialog()
        if settings_dialog then
            UIManager:close(settings_dialog)
        end

        local default_dir = DataStorage:getDataDir() .. "/instapaper"
        local fmt_label = output_format == "epub" and "EPUB" or "HTML"
        local img_label = include_images and _("ON") or _("OFF")
        local limit_label = tostring(limit_choices[limit_idx])
        local action_label
        if after_download_action == "archive" then
            action_label = _("Archive only")
        elseif after_download_action == "read" then
            action_label = _("Archive + Mark read")
        else
            action_label = _("None")
        end
        
        local cache_label
        if cache_folder and cache_folder ~= "" then
            if #cache_folder > 40 then
                cache_label = "..." .. cache_folder:sub(-37)
            else
                cache_label = cache_folder
            end
        else
            cache_label = _("Default")
        end

        local sync_archive_label = auto_archive_on_sync and _("ON") or _("OFF")
        local perpage_label = tostring(perpage_choices[perpage_idx])
        local sort_label    = sort_choices[sort_idx].label

        settings_dialog = ButtonDialog:new{
            title = _("Instapaper settings")
                .. "\n" .. _("Article list limit: ") .. limit_label
                .. "\n" .. _("Articles per page: ") .. perpage_label
                .. "\n" .. _("Sort: ") .. sort_label
                .. "\n" .. _("Output format: ") .. fmt_label
                .. "\n" .. _("Include images (EPUB): ") .. img_label
                .. "\n" .. _("After tap-download: ") .. action_label
                .. "\n" .. _("Archive finished on sync: ") .. sync_archive_label
                .. "\n" .. _("Cache folder: ") .. cache_label,
            buttons = {
                {
                    {
                        text = _("< Limit >"),
                        callback = function()
                            limit_idx = (limit_idx % #limit_choices) + 1
                            rebuildSettingsDialog()
                        end,
                    },
                    {
                        text = _("< Per page >"),
                        callback = function()
                            perpage_idx = (perpage_idx % #perpage_choices) + 1
                            rebuildSettingsDialog()
                        end,
                    },
                    {
                        text = _("< Format >"),
                        callback = function()
                            output_format = output_format == "html" and "epub" or "html"
                            rebuildSettingsDialog()
                        end,
                    },
                },
                {
                    {
                        text = _("< Sort >"),
                        callback = function()
                            sort_idx = (sort_idx % #sort_choices) + 1
                            rebuildSettingsDialog()
                        end,
                    },
                },
                {
                    {
                        text = _("Images: ") .. img_label,
                        callback = function()
                            include_images = not include_images
                            rebuildSettingsDialog()
                        end,
                    },
                    {
                        text = _("< Tap-download >"),
                        callback = function()
                            if after_download_action == "none" then
                                after_download_action = "archive"
                            elseif after_download_action == "archive" then
                                after_download_action = "read"
                            else
                                after_download_action = "none"
                            end
                            rebuildSettingsDialog()
                        end,
                    },
                },
                {
                    {
                        text = _("Sync archive: ") .. sync_archive_label,
                        callback = function()
                            auto_archive_on_sync = not auto_archive_on_sync
                            rebuildSettingsDialog()
                        end,
                    },
                    {
                        text = _("< Cache folder >"),
                        callback = function()
                            UIManager:close(settings_dialog)
                            self:showCacheFolderDialog(function(new_path)
                                cache_folder = new_path
                                rebuildSettingsDialog()
                            end, cache_folder)
                        end,
                    },
                },
                {
                    {
                        text = _("Save"),
                        callback = function()
                            UIManager:close(settings_dialog)
                            self.article_limit  = limit_choices[limit_idx]
                            self.output_format  = output_format
                            self.include_images = include_images
                            self.after_download_action = after_download_action
                            self.cache_folder = cache_folder
                            self.auto_archive_on_sync = auto_archive_on_sync
                            self.articles_per_page = perpage_choices[perpage_idx]
                            self.sort_by = sort_choices[sort_idx].value
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("Settings saved."),
                                timeout = 2,
                            })
                        end,
                    },
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(settings_dialog)
                        end,
                    },
                },
            },
        }
        UIManager:show(settings_dialog)
    end

    rebuildSettingsDialog()
end

function Instapaper:showCacheFolderDialog(return_callback, current_folder)
    local default_dir = DataStorage:getDataDir() .. "/instapaper"
    
    local cache_dialog
    cache_dialog = MultiInputDialog:new{
        title = _("Cache folder"),
        fields = {
            {
                text = current_folder or "",
                hint = current_folder and current_folder ~= "" and current_folder or default_dir,
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(cache_dialog)
                        if return_callback then
                            return_callback(current_folder)
                        end
                    end,
                },
                {
                    text = _("OK"),
                    is_enter_default = true,
                    callback = function()
                        local fields = cache_dialog:getFields()
                        local new_path = fields[1]
                        UIManager:close(cache_dialog)
                        
                        if new_path and new_path ~= "" then
                            local attr = lfs.attributes(new_path)
                            if attr and attr.mode == "directory" then
                                if return_callback then
                                    return_callback(new_path)
                                end
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("The specified path does not exist."),
                                })
                                if return_callback then
                                    return_callback(current_folder)
                                end
                            end
                        else
                            if return_callback then
                                return_callback(nil)
                            end
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(cache_dialog)
    cache_dialog:onShowKeyboard()
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

function Instapaper:fetchAndShowArticles(folder_id, folder_name)
    UIManager:show(InfoMessage:new{
        text = _("Fetching articles..."),
        timeout = 1,
    })

    local params = { limit = tostring(self.article_limit or 50) }
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

    self:showArticleMenu(bookmarks, folder_id, folder_name)
end

-- Local-first entry point for the Unread folder. Renders from the cached
-- bookmark list (written at end of sync) without touching the network.
-- Falls back to the network path when no cache exists yet (first run).
function Instapaper:showUnreadFromCache()
    local cached = self:loadBookmarkCache("unread")
    if cached and #cached > 0 then
        self:showArticleMenu(cached, "unread")
        return
    end
    self:ensureOnlineAndLoggedIn(function()
        self:fetchAndShowArticles("unread")
    end)
end

-- Build a set of bookmark_ids whose article file currently exists on disk.
-- Used by showArticleMenu to mark rows as "on device" vs "server only".
function Instapaper:getDownloadedIdSet()
    local set = {}
    for _, item in ipairs(self:getLocalArticles()) do
        set[item.id] = true
    end
    return set
end

function Instapaper:showArticleMenu(bookmarks, folder_id, folder_name)
    local folder_names = {
        unread  = _("Unread"),
        starred = _("Starred"),
        archive = _("Archive"),
    }
    local downloaded_ids = self:getDownloadedIdSet()

    -- Right-column annotation: saved date plus reading progress.
    -- Saved date format: "Apr 28" (current year) or "Apr 28 '25" (older).
    -- Progress is appended only when > 0. Both, either, or neither may render.
    local function formatMandatory(bm)
        local parts = {}
        if bm.time and bm.time > 0 then
            local current_year = tonumber(os.date("%Y"))
            local item_year    = tonumber(os.date("%Y", bm.time))
            if item_year == current_year then
                parts[#parts + 1] = os.date("%b %-d", bm.time)
            else
                parts[#parts + 1] = os.date("%b %-d '%y", bm.time)
            end
        end
        if bm.progress and bm.progress > 0 then
            parts[#parts + 1] = string.format("%d%%", bm.progress * 100)
        end
        if #parts == 0 then return nil end
        return table.concat(parts, " · ")
    end

    -- Sort bookmarks in place per the user's chosen sort_by mode.
    local function sortBookmarks(items, mode)
        if mode == "saved_asc" then
            table.sort(items, function(a, b) return (a.time or 0) < (b.time or 0) end)
        elseif mode == "title_asc" then
            table.sort(items, function(a, b)
                return (a.title or ""):lower() < (b.title or ""):lower()
            end)
        else  -- saved_desc (default)
            table.sort(items, function(a, b) return (a.time or 0) > (b.time or 0) end)
        end
    end
    sortBookmarks(bookmarks, self.sort_by)

    local menu
    local menu_items = {}
    for _, bm in ipairs(bookmarks) do
        local title = bm.title
        if not title or title == "" or type(title) ~= "string" then
            title = "Untitled"
        end

        local id_str = tostring(bm.bookmark_id)
        local on_device = downloaded_ids[id_str] == true
        -- Filled circle = downloaded (instant open).
        -- Empty circle = server-only (needs download).
        local prefix = on_device and "● " or "○ "

        local item = {
            text = prefix .. title,
            _bookmark = bm,
            _on_device = on_device,
            callback = function()
                if on_device then
                    -- Instant open path -- no network needed
                    self:openLocalArticle(bm)
                else
                    NetworkMgr:runWhenOnline(function()
                        self:downloadAndOpenArticle(bm)
                    end)
                end
            end,
            hold_callback = function()
                self:showArticleActions(bm, menu, folder_id)
            end,
            hold_keep_menu_open = true,
        }

        local mandatory = formatMandatory(bm)
        if mandatory then
            item.mandatory = mandatory
        end

        table.insert(menu_items, item)
    end

    local menu_title = folder_name or folder_names[folder_id] or folder_id or "Articles"
    if type(menu_title) ~= "string" then
        menu_title = "Articles"
    end
    
    -- Forcing items_font_size makes items_per_page visibly take effect:
    -- without an explicit font size KOReader's auto-derivation runs lazily
    -- and the row height doesn't shrink to actually pack more rows.
    local items_font_size = Menu.getItemFontSize
        and Menu.getItemFontSize(self.articles_per_page) or nil

    menu = Menu:new{
        title = "Instapaper - " .. menu_title,
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        items_per_page = self.articles_per_page,
        items_font_size = items_font_size,
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

function Instapaper:buildArticleMetaTitle(bookmark)
    local title = bookmark.title
    if not title or title == "" then
        title = _("Untitled")
    end

    local lines = { title }

    -- Date
    if bookmark.time and bookmark.time > 0 then
        local date_str = os.date("%Y-%m-%d", bookmark.time)
        lines[#lines + 1] = _("Date: ") .. date_str
    end

    -- Word count / reading time
    if bookmark.word_count and bookmark.word_count > 0 then
        local wc = tostring(bookmark.word_count) .. " " .. _("words")
        local mins = math.ceil(bookmark.word_count / 200)
        wc = wc .. "  (~" .. tostring(mins) .. " min)"
        lines[#lines + 1] = wc
    end

    -- Reading progress
    if bookmark.progress and bookmark.progress > 0 then
        lines[#lines + 1] = _("Progress: ") .. string.format("%d%%", bookmark.progress * 100)
    end

    -- URL (truncated)
    if bookmark.url and bookmark.url ~= "" then
        local url = bookmark.url
        if #url > 60 then
            url = url:sub(1, 57) .. "..."
        end
        lines[#lines + 1] = url
    end

    return table.concat(lines, "\n")
end

function Instapaper:showArticleActions(bookmark, parent_menu, folder_id)
    local dialog_title = self:buildArticleMetaTitle(bookmark)

    local actions_dialog
    actions_dialog = ButtonDialog:new{
        title = dialog_title,
        buttons = {
            {
                {
                    text = _("Download"),
                    callback = function()
                        UIManager:close(actions_dialog)
                        NetworkMgr:runWhenOnline(function()
                            self:downloadArticleOnly(bookmark)
                        end)
                    end,
                },
                {
                    text = _("Open"),
                    callback = function()
                        UIManager:close(actions_dialog)
                        NetworkMgr:runWhenOnline(function()
                            self:downloadAndOpenArticle(bookmark)
                        end)
                    end,
                },
            },
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

function Instapaper:getDownloadDir()
    local dir
    if self.cache_folder and self.cache_folder ~= "" then
        dir = self.cache_folder
    else
        dir = DataStorage:getDataDir() .. "/instapaper"
    end
    lfs.mkdir(dir)
    return dir
end

function Instapaper:buildFilepath(bookmark)
    local safe_title = (bookmark.title or "article")
        :gsub("[/\\%?%%%*%:%|%\"%<%>]", "_")
        :sub(1, 100)
    safe_title = util.fixUtf8(safe_title, "_")
    return self:getDownloadDir() .. "/"
        .. safe_title .. "_ip_" .. tostring(bookmark.bookmark_id) .. ".html"
end

function Instapaper:injectTitleIfMissing(html, bookmark)
    local title = bookmark.title
    if not title or title == "" then
        return html
    end
    -- Only inject if no h1/h2/h3 found near the top of the document
    local head = html:sub(1, 2000):lower()
    if head:find("<h1") or head:find("<h2") or head:find("<h3") then
        return html
    end
    local escaped = title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local inject = "<h3>" .. escaped .. "</h3>\n"
    -- Insert after <body> tag if present, otherwise prepend
    local result, n = html:gsub("(<body[^>]*>)", "%1\n" .. inject, 1)
    if n == 0 then
        result = inject .. html
    end
    return result
end

function Instapaper:fetchArticleHtml(bookmark)
    local ok, html, code = self:apiRequest("/api/1/bookmarks/get_text", {
        bookmark_id = tostring(bookmark.bookmark_id),
    }, true)
    if not ok then
        return nil, code
    end
    html = self:injectTitleIfMissing(html, bookmark)
    return html, nil
end

-- Wrap fetchArticleHtml with one retry. Wi-Fi naps on Kindles cause the
-- first call to hang then fail; the second call usually lands in an
-- awake window. Returns html on success, nil + last error on failure.
function Instapaper:fetchArticleHtmlWithRetry(bookmark, max_attempts)
    max_attempts = max_attempts or 2
    local last_err
    for attempt = 1, max_attempts do
        local html, err = self:fetchArticleHtml(bookmark)
        if html then return html end
        last_err = err
    end
    return nil, last_err
end

function Instapaper:saveArticleHtml(bookmark, html)
    local filepath = self:buildFilepath(bookmark)
    local f = io.open(filepath, "w")
    if not f then
        return nil
    end
    f:write(html)
    f:close()
    return filepath
end

-- Save article in the configured output format (html or epub).
-- Returns filepath on success, nil on failure.
function Instapaper:saveArticle(bookmark, html)
    local fmt = self.output_format or "html"
    if fmt == "epub" then
        local InstapaperEpub = require("instapaper_epub")
        local filepath, err = InstapaperEpub.createEpub(
            bookmark, html, self:getDownloadDir(), self.include_images)
        if not filepath then
            logger.warn("Instapaper: EPUB creation failed, falling back to HTML", err)
            return self:saveArticleHtml(bookmark, html)
        end
        return filepath
    else
        return self:saveArticleHtml(bookmark, html)
    end
end

-- Download only (no open), keeps caller menu open
function Instapaper:downloadArticleOnly(bookmark)
    UIManager:show(InfoMessage:new{
        text = _("Downloading article..."),
        timeout = 1,
    })

    local html, err = self:fetchArticleHtml(bookmark)
    if not html then
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed (HTTP %1)"), tostring(err)),
        })
        return
    end

    local filepath = self:saveArticle(bookmark, html)
    if not filepath then
        UIManager:show(InfoMessage:new{
            text = _("Could not save article file."),
        })
        return
    end

    local short_title = (bookmark.title or "article"):sub(1, 40)
    UIManager:show(InfoMessage:new{
        text = T(_("Saved: %1"), short_title),
        timeout = 2,
    })

    if self.after_download_action == "archive" then
        self:apiRequest("/api/1/bookmarks/archive", {
            bookmark_id = tostring(bookmark.bookmark_id),
        })
    elseif self.after_download_action == "read" then
        self:apiRequest("/api/1/bookmarks/archive", {
            bookmark_id = tostring(bookmark.bookmark_id),
        })
        self:apiRequest("/api/1/bookmarks/update_read_progress", {
            bookmark_id = tostring(bookmark.bookmark_id),
            progress = "1.0",
            progress_timestamp = tostring(os.time()),
        })
    end
end

-- Open an already-downloaded article without any network round-trip.
-- Used for "on-device" rows in the local-first article list.
function Instapaper:openLocalArticle(bookmark)
    -- Prefer the configured output_format's path; fall back to whichever is on disk
    local html_path = self:buildFilepath(bookmark)
    local epub_path
    if InstapaperEpub_loaded then
        -- noop placeholder; we lazy-require below
    end
    local target = html_path
    if not lfs.attributes(target) then
        local InstapaperEpub = require("instapaper_epub")
        epub_path = InstapaperEpub.buildEpubPath(self:getDownloadDir(), bookmark)
        if lfs.attributes(epub_path) then target = epub_path end
    end
    if not lfs.attributes(target) then
        UIManager:show(InfoMessage:new{
            text = _("Local file not found. Download it first."),
        })
        return
    end
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(target)
end

function Instapaper:downloadAndOpenArticle(bookmark)
    UIManager:show(InfoMessage:new{
        text = _("Downloading article..."),
        timeout = 1,
    })

    local html, err = self:fetchArticleHtml(bookmark)
    if not html then
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed (HTTP %1)"), tostring(err)),
        })
        return
    end

    local filepath = self:saveArticle(bookmark, html)
    if not filepath then
        UIManager:show(InfoMessage:new{
            text = _("Could not save article file."),
        })
        return
    end

    if self.after_download_action == "archive" then
        self:apiRequest("/api/1/bookmarks/archive", {
            bookmark_id = tostring(bookmark.bookmark_id),
        })
    elseif self.after_download_action == "read" then
        self:apiRequest("/api/1/bookmarks/archive", {
            bookmark_id = tostring(bookmark.bookmark_id),
        })
        self:apiRequest("/api/1/bookmarks/update_read_progress", {
            bookmark_id = tostring(bookmark.bookmark_id),
            progress = "1.0",
            progress_timestamp = tostring(os.time()),
        })
    end

    -- Open in KOReader
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(filepath)
end

--------------------------------------------------------------------
-- Downloads folder
--------------------------------------------------------------------

function Instapaper:confirmAndMigrateFilenames()
    local count = 0
    local dir = self:getDownloadDir()
    for entry in lfs.dir(dir) do
        if entry:match("^(%d+)_.+%.html$") or entry:match("^(%d+)_.+%.epub$") then
            count = count + 1
        end
    end

    if count == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No legacy-format files to rename."),
            timeout = 2,
        })
        return
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Rename %1 article(s) to put the title first?\nReading progress and finished status will be preserved."),
            tostring(count)),
        ok_text = _("Rename"),
        ok_callback = function()
            local renamed, errs, skipped = self:migrateFilenames()
            local msg
            if errs > 0 or skipped > 0 then
                msg = T(_("Renamed: %1\nErrors: %2  Skipped: %3"),
                    tostring(renamed), tostring(errs), tostring(skipped))
            else
                msg = T(_("Renamed %1 article(s)."), tostring(renamed))
            end
            UIManager:show(InfoMessage:new{ text = msg })
        end,
    })
end

function Instapaper:clearDownloadsCache()
    local dir = self:getDownloadDir()
    local ConfirmBox = require("ui/widget/confirmbox")

    UIManager:show(ConfirmBox:new{
        text = _("Delete all files and folders in the Instapaper downloads folder?"),
        ok_text = _("Delete"),
        ok_callback = function()
            self:_doClearDownloadsCache(dir)
        end,
    })
end

function Instapaper:_doClearDownloadsCache(dir)
    local function removeAll(path)
        local attr = lfs.attributes(path)
        if not attr then return end
        if attr.mode == "directory" then
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    removeAll(path .. "/" .. entry)
                end
            end
            lfs.rmdir(path)
        else
            os.remove(path)
        end
    end

    local count = 0
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            removeAll(dir .. "/" .. entry)
            count = count + 1
        end
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Deleted %1 item(s) from downloads folder."), count),
        timeout = 3,
    })
end

--------------------------------------------------------------------
-- Custom folders
--------------------------------------------------------------------

-- Returns a list of {text, value} for user-created folders, or nil on error.
function Instapaper:fetchUserFolders()
    local ok, body, code = self:apiRequest("/api/1/folders/list", {})
    if not ok then
        logger.warn("Instapaper: failed to fetch folders", code)
        return nil
    end
    local parse_ok, data = pcall(JSON.decode, body)
    if not parse_ok or type(data) ~= "table" then
        return nil
    end
    local folders = {}
    for _, item in ipairs(data) do
        if type(item) == "table" and item.type == "folder" then
            table.insert(folders, {
                text  = item.title or item.slug or tostring(item.folder_id),
                value = tostring(item.folder_id),
            })
        end
    end
    return folders
end

function Instapaper:fetchAndShowUserFolders()
    UIManager:show(InfoMessage:new{
        text = _("Fetching folders..."),
        timeout = 1,
    })

    local folders = self:fetchUserFolders()
    if not folders then
        UIManager:show(InfoMessage:new{
            text = _("Failed to fetch folders."),
        })
        return
    end
    if #folders == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No custom folders found."),
        })
        return
    end

    local folder_menu
    local menu_items = {}
    for _, folder in ipairs(folders) do
        local f = folder
        table.insert(menu_items, {
            text = f.text,
            callback = function()
                UIManager:close(folder_menu)
                NetworkMgr:runWhenOnline(function()
                    self:fetchAndShowArticles(f.value, f.text)
                end)
            end,
        })
    end

    folder_menu = Menu:new{
        title = _("Instapaper - Custom folders"),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        close_callback = function()
            UIManager:close(folder_menu)
        end,
    }
    UIManager:show(folder_menu, "full")
end

--------------------------------------------------------------------
-- Bookmark cache (for local-first browsing)
--
-- After each sync we serialize the server's Unread bookmark list to
-- {cache_dir}/.cache/bookmarks_unread.json. The article-list view reads
-- from this file instead of hitting the API on every tap.
--------------------------------------------------------------------

function Instapaper:_bookmarkCachePath(folder_id)
    return self:getDownloadDir() .. "/.cache/bookmarks_" .. (folder_id or "unread") .. ".json"
end

function Instapaper:saveBookmarkCache(folder_id, bookmarks)
    local cache_dir = self:getDownloadDir() .. "/.cache"
    lfs.mkdir(cache_dir)
    local path = self:_bookmarkCachePath(folder_id)
    local f = io.open(path, "w")
    if not f then return end
    f:write(JSON.encode(bookmarks))
    f:close()
end

function Instapaper:loadBookmarkCache(folder_id)
    local path = self:_bookmarkCachePath(folder_id)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    local ok, data = pcall(JSON.decode, content)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

-- Persist (or clear, when the list is empty) the set of articles that
-- failed to download in the most recent sync. The "View last sync
-- failures" menu entry reads this back.
function Instapaper:_failureListPath()
    return self:getDownloadDir() .. "/.cache/last_sync_failures.json"
end

function Instapaper:saveFailureList(failures)
    local cache_dir = self:getDownloadDir() .. "/.cache"
    lfs.mkdir(cache_dir)
    local path = self:_failureListPath()
    if not failures or #failures == 0 then
        os.remove(path)
        return
    end
    local f = io.open(path, "w")
    if not f then return end
    f:write(JSON.encode(failures))
    f:close()
end

function Instapaper:loadFailureList()
    local f = io.open(self:_failureListPath(), "r")
    if not f then return {} end
    local content = f:read("*all")
    f:close()
    local ok, data = pcall(JSON.decode, content)
    if not ok or type(data) ~= "table" then return {} end
    return data
end

function Instapaper:showLastSyncFailures()
    local failures = self:loadFailureList()
    if #failures == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No failed downloads from the last sync."),
            timeout = 2,
        })
        return
    end
    local lines = { T(_("%1 articles failed in the last sync:"), tostring(#failures)) }
    for i, fail in ipairs(failures) do
        if i > 20 then
            lines[#lines + 1] = T(_("... and %1 more"), tostring(#failures - 20))
            break
        end
        local title = fail.title or "(untitled)"
        if #title > 60 then title = title:sub(1, 57) .. "..." end
        lines[#lines + 1] = "• " .. title
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = _("These will be retried on the next Sync now.")
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

--------------------------------------------------------------------
-- Sync (full mirror of Unread folder)
--------------------------------------------------------------------

-- Walk the cache directory and return { id, path, name } for every article.
-- Recognises two naming conventions:
--   new:    {title}_ip_{bookmark_id}.{html|epub}   (post-1.4.0)
--   legacy: {bookmark_id}_{title}.{html|epub}      (1.2.x and 1.3.x)
function Instapaper:getLocalArticles()
    local dir = self:getDownloadDir()
    local items = {}
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local id = entry:match("_ip_(%d+)%.html$")
                    or entry:match("_ip_(%d+)%.epub$")
                    or entry:match("^(%d+)_.+%.html$")
                    or entry:match("^(%d+)_.+%.epub$")
            if id then
                table.insert(items, {
                    id   = id,
                    path = dir .. "/" .. entry,
                    name = entry,
                })
            end
        end
    end
    return items
end

-- One-time migration: rename legacy {id}_{title}.ext files to {title}_ip_{id}.ext,
-- moving the matching .sdr/ sidecar in lockstep so reading state and finished
-- status are preserved. Returns (renamed_count, error_count, skipped_count).
function Instapaper:migrateFilenames()
    local dir = self:getDownloadDir()
    local entries = {}
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            table.insert(entries, entry)
        end
    end

    local renamed, errs, skipped = 0, 0, 0
    for _, entry in ipairs(entries) do
        local id, base, ext = entry:match("^(%d+)_(.+)%.(html)$")
        if not id then
            id, base, ext = entry:match("^(%d+)_(.+)%.(epub)$")
        end
        if id then
            local new_name = base .. "_ip_" .. id .. "." .. ext
            local old_path = dir .. "/" .. entry
            local new_path = dir .. "/" .. new_name

            if lfs.attributes(new_path) then
                skipped = skipped + 1  -- target exists; don't clobber
            elseif os.rename(old_path, new_path) then
                renamed = renamed + 1
                -- Move sidecar (legacy pattern: {basename_no_ext}.sdr)
                local old_sdr_legacy = dir .. "/" .. id .. "_" .. base .. ".sdr"
                local new_sdr_legacy = dir .. "/" .. base .. "_ip_" .. id .. ".sdr"
                if lfs.attributes(old_sdr_legacy, "mode") == "directory" then
                    os.rename(old_sdr_legacy, new_sdr_legacy)
                end
                -- Move sidecar (modern pattern: {full_filename}.sdr)
                local old_sdr_modern = old_path .. ".sdr"
                local new_sdr_modern = new_path .. ".sdr"
                if lfs.attributes(old_sdr_modern, "mode") == "directory" then
                    os.rename(old_sdr_modern, new_sdr_modern)
                end
            else
                errs = errs + 1
            end
        end
    end
    return renamed, errs, skipped
end

-- Returns true if KOReader has marked the document complete (end-of-book
-- prompt accepted, or "Reading status -> Finished" set manually).
function Instapaper:isDocumentFinished(filepath)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings then return false end
    local doc_settings = DocSettings:open(filepath)
    if not doc_settings then return false end
    local summary = doc_settings:readSetting("summary")
    return summary and summary.status == "complete"
end

-- Remove the article file plus its KOReader sidecar. Uses DocSettings:purge()
-- so both legacy ("foo.sdr") and modern ("foo.html.sdr") naming conventions
-- are handled, plus central-folder mode if that's ever configured.
function Instapaper:removeLocalArticle(filepath)
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings then
        local doc_settings = DocSettings:open(filepath)
        if doc_settings and doc_settings.purge then
            doc_settings:purge()
        end
    end
    os.remove(filepath)
end

-- For each finished local article: archive on Instapaper, then delete locally.
-- Returns the archived count.
function Instapaper:archiveFinishedDownloads()
    local archived = 0
    for _, item in ipairs(self:getLocalArticles()) do
        if self:isDocumentFinished(item.path) then
            local ok = self:apiRequest("/api/1/bookmarks/archive", {
                bookmark_id = item.id,
            })
            if ok then
                self:removeLocalArticle(item.path)
                archived = archived + 1
            end
        end
    end
    return archived
end

-- Full mirror sync of the Unread folder:
--   1. Archive finished articles (if enabled) and remove their local files.
--   2. Fetch the server's Unread list.
--   3. Delete locals whose bookmark_id is no longer in Unread (orphans).
--   4. Download server-side articles missing from disk.
function Instapaper:syncToDevice()
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        Trapper:info(_("Syncing Instapaper..."))

        -- Step 1: archive finished + delete locally
        local archived = 0
        if self.auto_archive_on_sync then
            Trapper:info(_("Archiving finished articles..."))
            archived = self:archiveFinishedDownloads()
        end

        -- Step 2: fetch server's current Unread list (with one retry)
        Trapper:info(_("Fetching unread list..."))
        local ok, body, code
        for attempt = 1, 2 do
            ok, body, code = self:apiRequest("/api/1/bookmarks/list", { limit = "500" })
            if ok then break end
            if attempt == 1 then
                Trapper:info(_("Network hiccup -- retrying..."))
            end
        end
        if not ok then
            Trapper:info(T(_("Sync failed: %1"), body or tostring(code)))
            return
        end
        local parse_ok, data = pcall(JSON.decode, body)
        if not parse_ok or type(data) ~= "table" then
            Trapper:info(_("Failed to parse article list."))
            return
        end

        local server_ids = {}
        local server_bookmarks = {}
        for _, item in ipairs(data) do
            if type(item) == "table" and item.type == "bookmark" then
                server_ids[tostring(item.bookmark_id)] = true
                table.insert(server_bookmarks, item)
            end
        end

        -- Persist cache so the article-list view can render offline
        self:saveBookmarkCache("unread", server_bookmarks)

        -- Step 3: orphan sweep
        local removed = 0
        local local_ids = {}
        local locals = self:getLocalArticles()
        for _, item in ipairs(locals) do
            local_ids[item.id] = true
            if not server_ids[item.id] then
                self:removeLocalArticle(item.path)
                removed = removed + 1
            end
        end

        -- Step 4: download missing, with per-call retry and failure tracking
        local missing = {}
        for _, bm in ipairs(server_bookmarks) do
            if not local_ids[tostring(bm.bookmark_id)] then
                table.insert(missing, bm)
            end
        end

        local downloaded, failed = 0, 0
        local failures = {}  -- list of { id, title } for persistence
        local total = #missing
        for i, bm in ipairs(missing) do
            Trapper:info(T(_("Downloading %1/%2..."), tostring(i), tostring(total)))
            local html = self:fetchArticleHtmlWithRetry(bm, 2)
            local saved = html and self:saveArticle(bm, html)
            if saved then
                downloaded = downloaded + 1
            else
                failed = failed + 1
                table.insert(failures, {
                    id    = tostring(bm.bookmark_id),
                    title = bm.title or "(untitled)",
                })
            end
        end

        -- Persist failure list so user can review later
        self:saveFailureList(failures)

        local summary = T(_("Sync complete.\nArchived: %1  Removed: %2\nDownloaded: %3  Failed: %4"),
            tostring(archived), tostring(removed),
            tostring(downloaded), tostring(failed))
        Trapper:info(summary)
    end)
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
