--[[--
Приставка „Читанка“ за KOReader.

Регистрира меню за търсене и сваляне на книги и творби от chitanka.info.
Свързва UI слоя (chitanka/ui) с настройките (chitanka/config) и API-то
(chitanka/api). Без вход, сесии или квоти — само публични заявки.
]]

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local API = require("chitanka/api")
local Config = require("chitanka/config")
local UI = require("chitanka/ui")

local Chitanka = WidgetContainer:extend{
    name = "chitanka",
    is_doc_only = false,
}

function Chitanka:onDispatcherRegisterActions()
    Dispatcher:registerAction("chitanka_search", {
        category = "none",
        event = "ChitankaSearch",
        title = _("Читанка: Търсене"),
        general = true,
    })
    Dispatcher:registerAction("chitanka_new_books", {
        category = "none",
        event = "ChitankaNewBooks",
        title = _("Читанка: Нови книги"),
        general = true,
    })
    Dispatcher:registerAction("chitanka_new_texts", {
        category = "none",
        event = "ChitankaNewTexts",
        title = _("Читанка: Нови творби"),
        general = true,
    })
end

function Chitanka:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Chitanka:onChitankaSearch()
    UI:showSearchDialog()
end

function Chitanka:onChitankaNewBooks()
    UI:browseNew("books")
end

function Chitanka:onChitankaNewTexts()
    UI:browseNew("texts")
end

function Chitanka:getSettingsMenu()
    local format_menu = {}
    for _, fmt in ipairs(API.FORMATS) do
        format_menu[#format_menu + 1] = {
            text = fmt:upper(),
            radio = true,
            checked_func = function() return Config:get("default_format") == fmt end,
            callback = function() Config:set("default_format", fmt) end,
            keep_menu_open = true,
        }
    end
    local perpage_menu = {}
    for _, n in ipairs({ 5, 10, 15, 20, 25 }) do
        perpage_menu[#perpage_menu + 1] = {
            text = tostring(n),
            radio = true,
            checked_func = function() return Config:get("results_per_page") == n end,
            callback = function() Config:set("results_per_page", n) end,
            keep_menu_open = true,
        }
    end
	local name_pattern_menu = {
        {
            text = _("Автор - Заглавие"),
            radio = true,
            checked_func = function() return Config:get("download_name_pattern") == "author_title" end,
            callback = function() Config:set("download_name_pattern", "author_title") end,
            keep_menu_open = true,
        },
        {
            text = _("Заглавие - Автор"),
            radio = true,
            checked_func = function() return Config:get("download_name_pattern") == "title_author" end,
            callback = function() Config:set("download_name_pattern", "title_author") end,
            keep_menu_open = true,
        },
	}
    return {
        {
            text = _("Формат по подразбиране"),
            sub_item_table = format_menu,
        },
        {
            text = _("Питай за формат всеки път"),
            checked_func = function() return Config:get("confirm_format_each_time") end,
            callback = function() Config:toggle("confirm_format_each_time") end,
            keep_menu_open = true,
        },
        {
            text = _("Резултати на страница"),
            sub_item_table = perpage_menu,
        },
        {
            text = _("Папка за сваляне"),
            callback = function() self:chooseDownloadDir() end,
            keep_menu_open = true,
        },
		{
            text = _("Име на сваления файл"),
            sub_item_table = name_pattern_menu,
        },
    }
end

function Chitanka:chooseDownloadDir()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        path = Config:getDownloadDir(),
        onConfirm = function(path)
            Config:setDownloadDir(path)
            UIManager:show(InfoMessage:new{
                text = _("Папка за сваляне:\n") .. path,
            })
        end,
    })
end

function Chitanka:addToMainMenu(menu_items)
    menu_items.chitanka = {
        text = _("Читанка"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Търсене"),
                callback = function() UI:showSearchDialog() end,
            },
            {
                text = _("Нови книги"),
                callback = function() UI:browseNew("books") end,
            },
            {
                text = _("Нови творби"),
                callback = function() UI:browseNew("texts") end,
            },
            {
                text = _("Настройки"),
                sub_item_table = self:getSettingsMenu(),
            },
        },
    }
end

return Chitanka
