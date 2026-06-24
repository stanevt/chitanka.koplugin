--[[--
Достъп до публичния API на chitanka.info.

Без вход/сесия. Само GET заявки към:
  * /search.xml, /books/search.xml, /texts/search.xml, /persons/search.xml
  * /new/books.opds, /new/texts.opds  (за раздела „Нови“)
  * /book|/text/{id}-{slug}.{формат}  (сваляне)
  * assets2.chitanka.info/thumb/book-cover/...  (корици)

XML-ът е плосък и добре оформен, затова разчитаме на Lua-шаблони — по-предвидимо
от дървесен парсер за тази конкретна схема.
]]

local socket = require("socket")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local logger = require("logger")

local API = {}

API.BASE_URL = "https://chitanka.info"
API.ASSETS_URL = "https://assets2.chitanka.info"
API.USER_AGENT = "Mozilla/5.0 (KOReader; chitanka.koplugin)"
-- Налични формати за сваляне (низът е и разширението на файла).
API.FORMATS = { "epub", "fb2.zip", "mobi", "pdf", "txt.zip" }

----------------------------------------------------------------------
-- Помощни функции за XML
----------------------------------------------------------------------

local ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

local function unescape(s)
    if not s then return nil end
    s = s:gsub("&#x(%x+);", function(h) return util.unicodeCodepointToUtf8(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return util.unicodeCodepointToUtf8(tonumber(d)) end)
    s = s:gsub("&(%w+);", function(name) return ENTITIES[name] or ("&" .. name .. ";") end)
    return s
end

local function trim(s)
    if not s then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

-- Стойност на просто <tag>...</tag> в даден блок.
local function field(block, tag)
    if not block then return nil end
    local v = block:match("<" .. tag .. ">(.-)</" .. tag .. ">")
    return unescape(trim(v))
end

-- Връща частта от блока преди първия вложен контейнер, за да четем
-- собствените полета на елемента (а не тези на автора/категорията).
local function headOf(block)
    local cut = #block + 1
    for _, marker in ipairs({ "<author", "<translator", "<sequence", "<category" }) do
        local i = block:find(marker, 1, true)
        if i and i < cut then cut = i end
    end
    return block:sub(1, cut - 1)
end

-- Името от под-блок като <author>...<name>X</name>...</author>.
local function nameOf(subblock)
    if not subblock then return nil end
    return unescape(trim(subblock:match("<name>(.-)</name>")))
end

----------------------------------------------------------------------
-- Парсване на резултати
----------------------------------------------------------------------

local function parseBook(block)
    local head = headOf(block)
    return {
        kind = "book",
        id = tonumber(field(head, "id")),
        slug = field(head, "slug"),
        title = field(head, "title"),
        year = field(head, "year"),
        type = field(head, "type"),
        author = nameOf(block:match("<author>(.-)</author>")),
        category = nameOf(block:match("<category>(.-)</category>")),
        has_cover = block:find("<has%-cover") ~= nil,
        has_annotation = block:find("<has%-annotation") ~= nil,
    }
end

local function parseText(block)
    local head = headOf(block)
    return {
        kind = "text",
        id = tonumber(field(head, "id")),
        slug = field(head, "slug"),
        title = field(head, "title"),
        year = field(head, "year"),
        type = field(head, "type"),
        author = nameOf(block:match("<author>(.-)</author>")),
        translator = nameOf(block:match("<translator>(.-)</translator>")),
        has_cover = false, -- творбите нямат корица
        has_annotation = false,
    }
end

local function parsePerson(block)
    return {
        kind = "person",
        id = tonumber(field(block, "id")),
        slug = field(block, "slug"),
        title = field(block, "name"),
        real_name = field(block, "real-name"),
        country = field(block, "country"),
    }
end

function API._parseSearch(body)
    local results = {}
    local books = body:match("<books>(.-)</books>")
    if books then
        for b in books:gmatch("<book>(.-)</book>") do
            results[#results + 1] = parseBook(b)
        end
    end
    local texts = body:match("<texts>(.-)</texts>")
    if texts then
        for t in texts:gmatch("<text>(.-)</text>") do
            results[#results + 1] = parseText(t)
        end
    end
    local persons = body:match("<persons>(.-)</persons>")
    if persons then
        for p in persons:gmatch("<person>(.-)</person>") do
            results[#results + 1] = parsePerson(p)
        end
    end
    return results
end

function API._parseOPDS(body, kind)
    local results = {}
    for entry in body:gmatch("<entry>(.-)</entry>") do
        local entry_kind, id = entry:match("urn:x%-chitanka:(%a+):(%d+)")
        if id then
            -- Ако викащият е указал вид (напр. "book"), ползваме го като резервен,
            -- но URN-ът е меродавен (text feed може да съдържа само творби).
            local resolved_kind = entry_kind or kind
            results[#results + 1] = {
                kind = resolved_kind,
                id = tonumber(id),
                slug = nil, -- голите URL-и (/book/{id}.epub) работят и без slug
                title = unescape(trim(entry:match("<title>(.-)</title>"))),
                author = nameOf(entry:match("<author>(.-)</author>")),
                year = trim(entry:match("<dc:issued>(.-)</dc:issued>")),
                has_cover = (resolved_kind == "book")
                    and entry:find('rel="http://opds%-spec.org/image"') ~= nil,
                has_annotation = false,
            }
        end
    end
    return results
end

----------------------------------------------------------------------
-- HTTP
----------------------------------------------------------------------

function API._request(url, sink, is_download)
    local parsed = socket_url.parse(url)
    local requester = (parsed.scheme == "https") and https or http
    socketutil:set_timeout(15, is_download and 600 or 30)
    local code, headers, status = socket.skip(1, requester.request{
        url = url,
        method = "GET",
        headers = { ["User-Agent"] = API.USER_AGENT },
        sink = sink,
    })
    socketutil:reset_timeout()
    return code, headers, status
end

-- Изтегля цялото тяло на отговора като низ.
function API._get(url)
    local sink = {}
    local code, _, status = API._request(url, ltn12.sink.table(sink), false)
    if code ~= 200 then
        logger.warn("chitanka: GET", url, "->", code, status)
        return nil, status or ("HTTP " .. tostring(code))
    end
    return table.concat(sink)
end

----------------------------------------------------------------------
-- Публичен интерфейс
----------------------------------------------------------------------

local SEARCH_PATHS = {
    all = "/search.xml",
    books = "/books/search.xml",
    texts = "/texts/search.xml",
    persons = "/persons/search.xml",
}

--- Търсене. `kind` ∈ {all, books, texts, persons}. Връща списък или nil, err.
function API.search(query, kind)
    local path = SEARCH_PATHS[kind] or SEARCH_PATHS.all
    local url = API.BASE_URL .. path .. "?q=" .. socket_url.escape(query)
    local body, err = API._get(url)
    if not body then return nil, err end
    return API._parseSearch(body)
end

function API.getNewBooks()
    local body, err = API._get(API.BASE_URL .. "/new/books.opds")
    if not body then return nil, err end
    return API._parseOPDS(body, "book")
end

function API.getNewTexts()
    local body, err = API._get(API.BASE_URL .. "/new/texts.opds")
    if not body then return nil, err end
    return API._parseOPDS(body, "text")
end

--- Всички книги и творби на даден автор (по slug).
--- Извлича /author/{slug}/books.opds и /author/{slug}/texts.opds и ги обединява.
function API.getPersonWorks(slug)
    local base = API.BASE_URL .. "/author/" .. slug
    local results = {}
    local books_body = API._get(base .. "/books.opds")
    if books_body then
        for _, item in ipairs(API._parseOPDS(books_body, "book")) do
            results[#results + 1] = item
        end
    end
    local texts_body = API._get(base .. "/texts.opds")
    if texts_body then
        for _, item in ipairs(API._parseOPDS(texts_body, "text")) do
            results[#results + 1] = item
        end
    end
    if #results == 0 then
        return nil, "Не са намерени творби за този автор."
    end
    return results
end

--- URL на корица (само за книги). Папката е floor(id/256) в шестнайсетичен вид.
function API.coverUrl(id, size)
    return string.format("%s/thumb/book-cover/%02x/%d.%s.jpg",
        API.ASSETS_URL, math.floor(id / 256), id, size or "250")
end

--- URL за сваляне на книга/творба в даден формат.
function API.downloadUrl(kind, id, slug, fmt)
    local base = (kind == "text") and "/text/" or "/book/"
    local name = slug and (tostring(id) .. "-" .. slug) or tostring(id)
    return API.BASE_URL .. base .. name .. "." .. fmt
end

--- Сваля корица в кеша и връща локалния път (или nil).
function API.downloadCover(id)
    if not id then return nil end
    local dir = DataStorage:getDataDir() .. "/cache/chitanka"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(DataStorage:getDataDir() .. "/cache")
        lfs.mkdir(dir)
    end
    local path = string.format("%s/cover_%d.jpg", dir, id)
    if lfs.attributes(path, "mode") == "file" then
        return path -- вече е в кеша
    end
    local f = io.open(path, "wb")
    if not f then return nil end
    local code = API._request(API.coverUrl(id, "250"), ltn12.sink.file(f), true)
    if code ~= 200 then
        os.remove(path)
        return nil
    end
    return path
end

--- Сваля книга/творба в `dest_dir`. Връща пълния път или nil, err.
function API.downloadBook(kind, id, slug, fmt, dest_dir)
    local fname = ((slug or tostring(id)) .. "." .. fmt):gsub("[/\\]", "_")
    local path = dest_dir .. "/" .. fname
    local f = io.open(path, "wb")
    if not f then return nil, "Cannot open file for writing: " .. path end
    local code, _, status = API._request(API.downloadUrl(kind, id, slug, fmt),
        ltn12.sink.file(f), true)
    if code ~= 200 then
        os.remove(path)
        return nil, status or ("HTTP " .. tostring(code))
    end
    return path
end

return API
