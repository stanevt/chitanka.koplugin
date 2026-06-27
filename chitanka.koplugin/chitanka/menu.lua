--[[--
Разширение на стандартното KOReader Menu с поддръжка на корици в резултатите.

Архитектура (същата като zlibrary.koplugin):
  * item.state  -- слотът в лявата колона на Menu; слагаме там ImageWidget.
  * state_w     -- широчина на левия слот, преизчислена в _recalculateDimen.
  * Корицата се сваля в реален подпроцес (ffiUtil.runInSubProcess) за да не
    блокира главния нишка и UI на e-ink устройството.
  * Дебаунс от 0.8 с преди старт — ако потребителят превърта бързо, не пращаме
    заявки за всяка страница.
  * Всеки завършен подпроцес се засича чрез polling на всеки 0.5 с.
  * Корицата се пази на диска (DataStorage/cache/chitanka/); следващото
    отваряне на същата страница е моментно.
]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local API = require("chitanka/api")

local CoverMenu = Menu:extend{
    _jobs         = nil,   -- { pid, menu_item, dest }
    _poll_sched   = false,
    _closed       = false,
    _debounce_fn  = nil,
    cover_w       = nil,
    cover_h       = nil,
}

----------------------------------------------------------------------
-- Инициализация и размери
----------------------------------------------------------------------

function CoverMenu:init()
    self._jobs   = {}
    self._closed = false
    Menu.init(self)
end

-- Изчислява размерите на корицата и задава state_w на Menu.
function CoverMenu:_recalculateDimen()
    Menu._recalculateDimen(self)
    if not self.item_dimen then return end
    -- Menu._recalculateDimen overwrites self.perpage; re-apply the user's choice.
    if self.desired_perpage and self.desired_perpage > 0 and self.perpage > 0 then
        local items_h = self.perpage * self.item_dimen.h
        self.perpage = self.desired_perpage
        self.item_dimen.h = math.floor(items_h / self.desired_perpage)
    end
    self.cover_h = self.item_dimen.h - 2 * Size.padding.small
    self.cover_w = math.floor(self.cover_h * 2 / 3)
    self.state_w = self.cover_w + 2 * Size.padding.small
end

----------------------------------------------------------------------
-- Изграждане на state уиджети
----------------------------------------------------------------------

-- Изображение за заредена корица.
function CoverMenu:_imageWidget(path)
    return CenterContainer:new{
        dimen = Geom:new{ w = self.cover_w, h = self.cover_h },
        ImageWidget:new{
            file           = path,
            width          = self.cover_w,
            height         = self.cover_h,
            scale_factor   = 0,
            file_do_cache  = false,
        },
    }
end

-- Placeholder: рамка (за книга с корица, все още не заредена)
-- или празен блок (за творба/автор без корица — за запазване на подравняването).
function CoverMenu:_placeholder(has_border)
    local w, h = self.cover_w, self.cover_h
    if has_border then
        local b = Size.border.thin
        local iw, ih = w - 2 * b, h - 2 * b
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            FrameContainer:new{
                width = w, height = h, bordersize = b, padding = 0, margin = 0,
                CenterContainer:new{
                    dimen = Geom:new{ w = iw, h = ih },
                    TextBoxWidget:new{
                        text      = "⊡",
                        face      = Font:getFace("cfont", math.floor(ih * 0.25)),
                        width     = iw,
                        alignment = "center",
                    },
                },
            },
        }
    else
        -- Празен контейнер с точни размери
        return FrameContainer:new{
            width = w, height = h, bordersize = 0, padding = 0, margin = 0,
            Widget:new{
                dimen = Geom:new{ w = w, h = h },
            },
        }
    end
end

-- Избира правилния state widget за даден елемент (меню реда).
function CoverMenu:_stateFor(menu_item)
    if not (self.cover_w and self.cover_h) then return nil end
    if menu_item.has_cover and menu_item.book_id then
        local path = API.coverCachePath(menu_item.book_id)
        if path and lfs.attributes(path, "mode") == "file" then
            return self:_imageWidget(path)
        end
        return self:_placeholder(true)
    end
    return self:_placeholder(false)
end

----------------------------------------------------------------------
-- Рисуване на елементите
----------------------------------------------------------------------

function CoverMenu:_visibleItems()
    local t = self.item_table
    if not t then return {} end
    local perpage = self.perpage or 10
    local offset  = ((self.page or 1) - 1) * perpage
    local out = {}
    for i = 1, perpage do
        local it = t[offset + i]
        if not it then break end
        out[#out + 1] = it
    end
    return out
end

function CoverMenu:updateItems(select_number, no_recalculate_dimen)
    Menu.updateItems(self, select_number, no_recalculate_dimen)

    -- Задаваме placeholder на елементите, за които state все още е nil.
    -- cover_w е зададен от _recalculateDimen, извикан вътре в Menu.updateItems.
    if self.cover_w then
        local needs_repaint = false
        for _, it in ipairs(self:_visibleItems()) do
            if it.state == nil then
                it.state = self:_stateFor(it)
                if it.state then needs_repaint = true end
            end
        end
        if needs_repaint then
            UIManager:setDirty(self, "ui")
        end
    end

    self:_triggerLoad()
end

----------------------------------------------------------------------
-- Асинхронно сваляне на корици
----------------------------------------------------------------------

-- Дебаунс: изчакваме 0.8 с след последното обновяване на страница.
function CoverMenu:_triggerLoad()
    if self._debounce_fn then
        UIManager:unschedule(self._debounce_fn)
    end
    local saved_page = self.page
    self._debounce_fn = function()
        self._debounce_fn = nil
        if self._closed or self.page ~= saved_page then return end
        self:_startDownloads()
    end
    UIManager:scheduleIn(0.8, self._debounce_fn)
end

function CoverMenu:_startDownloads()
    for _, it in ipairs(self:_visibleItems()) do
        if it.has_cover and it.book_id then
            local dest = API.coverCachePath(it.book_id)
            if dest and lfs.attributes(dest, "mode") ~= "file" then
                self:_spawnJob(it, dest)
            end
        end
    end
end

-- Стартира подпроцес, който сваля корицата и я записва на диска.
-- Родителският процес разбира за успех само от наличието на файла.
function CoverMenu:_spawnJob(menu_item, dest)
    for _, j in ipairs(self._jobs) do
        if j.menu_item == menu_item then return end   -- вече е в опашката
    end

    local url = API.coverUrl(menu_item.book_id, "250")
    local ua  = API.USER_AGENT
    local tmp = dest .. ".tmp"

    -- Осигуряваме, че директорията за кеш съществува.
    local cache_dir = dest:match("^(.*)/[^/]+$")
    if cache_dir and lfs.attributes(cache_dir, "mode") ~= "directory" then
        lfs.mkdir(cache_dir:match("^(.*)/[^/]+$"))  -- родителската директория
        lfs.mkdir(cache_dir)
    end

    local ok, pid = pcall(ffiUtil.runInSubProcess, function()
        local req = require("ssl.https")
        local ltn12 = require("ltn12")
        local f = io.open(tmp, "wb")
        if not f then return end
        local _, code = req.request{
            url     = url,
            headers = { ["User-Agent"] = ua },
            sink    = ltn12.sink.file(f),
        }
        if code == 200 then
            os.rename(tmp, dest)
        else
            os.remove(tmp)
        end
    end, false)

    if not (ok and pid and pid > 0) then
        logger.warn("chitanka: cover subprocess failed for id", menu_item.book_id)
        return
    end

    table.insert(self._jobs, { pid = pid, menu_item = menu_item, dest = dest })
    self:_schedulePoll()
end

function CoverMenu:_schedulePoll()
    if self._poll_sched then return end
    self._poll_sched = true
    UIManager:scheduleIn(0.5, function() self:_poll() end)
end

function CoverMenu:_poll()
    self._poll_sched = false
    if self._closed then return end

    local remaining = {}
    local any_loaded = false

    for _, job in ipairs(self._jobs) do
        if ffiUtil.isSubProcessDone(job.pid) then
            if lfs.attributes(job.dest, "mode") == "file" then
                job.menu_item.state = self:_imageWidget(job.dest)
                any_loaded = true
            end
        else
            table.insert(remaining, job)
        end
    end

    self._jobs = remaining

    if any_loaded then
        UIManager:nextTick(function()
            if not self._closed then
                self:updateItems(nil, true)
            end
        end)
    end

    if #self._jobs > 0 then
        self:_schedulePoll()
    end
end

----------------------------------------------------------------------
-- Почистване при затваряне
----------------------------------------------------------------------

function CoverMenu:onCloseWidget()
    self._closed = true
    if self._debounce_fn then
        UIManager:unschedule(self._debounce_fn)
        self._debounce_fn = nil
    end
    for _, job in ipairs(self._jobs or {}) do
        pcall(ffiUtil.terminateSubProcess, job.pid)
    end
    self._jobs = {}
    Menu.onCloseWidget(self)
end

return CoverMenu
