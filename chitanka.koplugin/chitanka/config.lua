--[[--
Потребителски настройки за приставката Читанка.

Тънка обвивка над LuaSettings, която пази предпочитанията в отделен файл
(chitanka.lua в папката с настройки на KOReader).
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

local Config = {}

local settings -- мързеливо създаван LuaSettings обект

local DEFAULTS = {
    default_format = "epub",                  -- epub / fb2.zip / mobi / pdf / txt.zip
    last_search_type = "all",                 -- all / books / texts / persons
    confirm_format_each_time = true,          -- ако е false: сваляме директно в default_format
    results_per_page = 10,                    -- брой резултати на страница в списъка
	download_name_pattern = "author_title",   -- "author_title" или "title_author"
}

local function getSettings()
    if not settings then
        settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/chitanka.lua")
    end
    return settings
end

function Config:get(key)
    local v = getSettings():readSetting(key)
    if v == nil then
        return DEFAULTS[key]
    end
    return v
end

function Config:set(key, value)
    local s = getSettings()
    s:saveSetting(key, value)
    s:flush()
end

function Config:toggle(key)
    self:set(key, not self:get(key))
end

--- Връща папка за сваляне (своя настройка → обща KOReader → резервна).
function Config:getDownloadDir()
    local s = getSettings()
    local own = s:readSetting("download_dir")
    if own and lfs.attributes(own, "mode") == "directory" then
        return own
    end
    if G_reader_settings then
        local shared = G_reader_settings:readSetting("download_dir")
        if shared and lfs.attributes(shared, "mode") == "directory" then
            return shared
        end
    end
    local fallback = DataStorage:getDataDir() .. "/downloads"
    if lfs.attributes(fallback, "mode") ~= "directory" then
        lfs.mkdir(fallback)
    end
    return fallback
end

function Config:setDownloadDir(dir)
    self:set("download_dir", dir)
end

function Config:getDownloadName(item)
    local pattern = self:get("download_name_pattern") or "title_author"
    local parts = {}
    if item.title and item.title ~= "" then
        parts[#parts + 1] = item.title
    end
    if item.author and item.author ~= "" then
        parts[#parts + 1] = item.author
    end

    local name
    if #parts == 2 then
        if pattern == "author_title" then
            name = parts[2] .. " - " .. parts[1]
        else
            name = table.concat(parts, " - ")
        end
    elseif #parts == 1 then
        name = parts[1]
    else
        name = item.slug or tostring(item.id)
    end

    -- Таблица с интелигентни замени
    local smart_replacements = {
        [":"]  = " -",
        ["/"]  = " - ",
        ["\\"] = " - ",
        ["?"]  = "",
        ["!"]  = "",
        ["*"]  = "",
        ["<"]  = "",
        [">"]  = "",
        ["|"]  = "",
        ['"']  = "",
    }
    name = name:gsub("[:/\\?%!%*<>|\"]", smart_replacements)

    -- Премахване на всякакви оставащи символи, забранени от файловата система (за всеки случай)
    name = name:gsub("[<>:\"/\\|?*]", "_")

    -- Почистване на интервали и тирета
    name = name:gsub("%s+", " ")
               :gsub("^%s*%-%s*", "")
               :gsub("%s*%-%s*$", "")
               :gsub("%s*%-%s*", " - ")

    if name == "" then
        name = item.slug or tostring(item.id)
    end

    return name
end

return Config
