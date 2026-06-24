--[[--
Потребителски интерфейс на приставката Читанка.

Свързва API-то и настройките с диалозите на KOReader:
търсене → списък с резултати → детайли → избор на формат → сваляне.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local CoverMenu = require("chitanka/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Screen = Device.screen

local API = require("chitanka/api")
local Config = require("chitanka/config")

----------------------------------------------------------------------
-- Помощни функции
----------------------------------------------------------------------

local BOOK_TYPE_LABEL = {
    single = _("Книга"),
    magazine = _("Списание"),
    collection = _("Сборник"),
}

local function typeTag(item)
    if item.kind == "person" then return _("Автор") end
    if item.kind == "book" then
        return BOOK_TYPE_LABEL[item.type] or _("Книга")
    end
    return item.type or _("Творба")
end

local function whenOnline(fn)
    NetworkMgr:runWhenOnline(fn)
end

local function withProgress(message, fn)
    local info = InfoMessage:new{ text = message }
    UIManager:show(info)
    UIManager:forceRePaint()
    local a, b = fn()
    UIManager:close(info)
    return a, b
end

----------------------------------------------------------------------
-- UI модул
----------------------------------------------------------------------

local UI = {}

function UI:showError(err)
    UIManager:show(InfoMessage:new{
        text = _("Грешка: ") .. tostring(err or _("неизвестна")),
        icon = "notice-warning",
    })
end

function UI:formatResultLine(item)
    local tag = typeTag(item)
    if item.year then tag = tag .. ", " .. item.year end
    if item.kind == "person" then
        return string.format("%s  [%s]", item.title or "—", tag)
    end
    return string.format("%s — %s  [%s]", item.title or "—", item.author or "—", tag)
end

function UI:showResults(items, title)
    local menu_items = {}
    for _, item in ipairs(items) do
        menu_items[#menu_items + 1] = {
            text      = self:formatResultLine(item),
            -- book_id и has_cover се четат от CoverMenu за управление на корицата.
            -- has_cover е true само за книги (kind=="book") с <has-cover/> в XML-а.
            book_id   = (item.kind == "book") and item.id or nil,
            has_cover = item.has_cover or false,
            callback  = function() self:onSelectResult(item) end,
        }
    end
    local menu
    menu = CoverMenu:new{
        title          = title,
        item_table     = menu_items,
        is_borderless  = true,
        is_popout      = false,
        desired_perpage = Config:get("results_per_page"),
        width          = Screen:getWidth(),
        height         = Screen:getHeight(),
        onMenuSelect   = function(_self, it)
            if it.callback then it.callback() end
            return true
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function UI:onSelectResult(item)
    if item.kind == "person" then
        self:showPersonWorks(item)
    else
        self:showDetail(item)
    end
end

function UI:showPersonWorks(person)
    if not person.slug then
        self:doSearch(person.title, "all")
        return
    end
    whenOnline(function()
        local results, err = withProgress(_("Зареждане на творби…"), function()
            return API.getPersonWorks(person.slug)
        end)
        if not results then
            self:showError(err)
        else
            self:showResults(results, person.title)
        end
    end)
end

-- Детайлен изглед: показва се незабавно (без мрежови заявки).
-- Корицата се зарежда само ако потребителят я поиска изрично.
function UI:showDetail(item)
    -- Построяване на заглавен текст с метаданни
    local title_parts = { item.title or "—" }
    local by = {}
    if item.author then by[#by + 1] = item.author end
    if item.translator then by[#by + 1] = _("пр.:") .. " " .. item.translator end
    if #by > 0 then title_parts[#title_parts + 1] = table.concat(by, " · ") end
    local meta = {}
    if item.year then meta[#meta + 1] = item.year end
    if item.category then meta[#meta + 1] = item.category end
    local tag = typeTag(item)
    if tag then meta[#meta + 1] = tag end
    if item.real_name and item.real_name ~= item.title then
        meta[#meta + 1] = item.real_name
    end
    if item.country then meta[#meta + 1] = item.country end
    if #meta > 0 then title_parts[#title_parts + 1] = table.concat(meta, " · ") end
    local title_text = table.concat(title_parts, "\n")

    -- Бутони
    local buttons = {}
    if item.has_cover and item.kind == "book" and item.id then
        buttons[#buttons + 1] = { {
            text = _("Корица"),
            callback = function() self:showCover(item) end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Свали"),
        callback = function()
            UIManager:close(dialog)
            self:pickFormatAndDownload(item)
        end,
    } }
    buttons[#buttons + 1] = { {
        text = _("Назад"),
        callback = function() UIManager:close(dialog) end,
    } }

    local dialog
    dialog = ButtonDialog:new{
        title = title_text,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- Зарежда корицата асинхронно и я показва в ImageViewer.
function UI:showCover(item)
    whenOnline(function()
        local path = withProgress(_("Зареждане на корица…"), function()
            return API.downloadCover(item.id)
        end)
        if not path then
            self:showError(_("Корицата не може да бъде заредена."))
            return
        end
        local ImageViewer = require("ui/widget/imageviewer")
        UIManager:show(ImageViewer:new{
            file = path,
            with_title_bar = true,
            title = item.title,
            fullscreen = true,
        })
    end)
end

function UI:pickFormatAndDownload(item)
    if not Config:get("confirm_format_each_time") then
        self:download(item, Config:get("default_format"))
        return
    end
    local dialog
    local rows = {}
    for _, fmt in ipairs(API.FORMATS) do
        rows[#rows + 1] = { {
            text = fmt:upper(),
            callback = function()
                UIManager:close(dialog)
                self:download(item, fmt)
            end,
        } }
    end
    rows[#rows + 1] = { {
        text = _("Отказ"),
        callback = function() UIManager:close(dialog) end,
    } }
    dialog = ButtonDialog:new{
        title = _("Изберете формат"),
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(dialog)
end

function UI:download(item, fmt)
    whenOnline(function()
        local dir = Config:getDownloadDir()
        local path, err = withProgress(_("Сваляне…"), function()
            return API.downloadBook(item.kind, item.id, item.slug, fmt, dir)
        end)
        if not path then
            self:showError(err)
            return
        end
        UIManager:show(ConfirmBox:new{
            text = string.format(_("Свалено:\n%s\n\nОтваряне?"), path),
            ok_text = _("Отвори"),
            cancel_text = _("Затвори"),
            ok_callback = function()
                -- Изчакваме един кадър, за да се изчисти стекът на UIManager
                -- преди да отворим четеца.
                UIManager:scheduleIn(0.5, function()
                    local ReaderUI = require("apps/reader/readerui")
                    ReaderUI:showReader(path)
                end)
            end,
        })
    end)
end

function UI:doSearch(query, kind)
    if not query or query == "" then return end
    whenOnline(function()
        Config:set("last_search_type", kind)
        local results, err = withProgress(_("Търсене…"), function()
            return API.search(query, kind)
        end)
        if not results then
            self:showError(err)
        elseif #results == 0 then
            UIManager:show(InfoMessage:new{ text = _("Няма намерени резултати.") })
        else
            self:showResults(results, _("Резултати: ") .. query)
        end
    end)
end

function UI:showSearchDialog()
    local input
    local function run(kind)
        local q = input:getInputText()
        UIManager:close(input)
        self:doSearch(q, kind)
    end
    input = InputDialog:new{
        title = _("Търсене в Читанка"),
        input = "",
        input_hint = _("заглавие, автор…"),
        buttons = {
            {
                { text = _("Всичко"), is_enter_default = true,
                  callback = function() run("all") end },
                { text = _("Книги"), callback = function() run("books") end },
            },
            {
                { text = _("Творби"), callback = function() run("texts") end },
                { text = _("Автори"), callback = function() run("persons") end },
            },
            {
                { text = _("Отказ"), id = "close",
                  callback = function() UIManager:close(input) end },
            },
        },
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

function UI:browseNew(kind)
    whenOnline(function()
        local results, err = withProgress(_("Зареждане…"), function()
            if kind == "texts" then
                return API.getNewTexts()
            end
            return API.getNewBooks()
        end)
        if not results then
            self:showError(err)
        elseif #results == 0 then
            UIManager:show(InfoMessage:new{ text = _("Няма нови записи.") })
        else
            self:showResults(results,
                kind == "texts" and _("Нови творби") or _("Нови книги"))
        end
    end)
end

return UI
