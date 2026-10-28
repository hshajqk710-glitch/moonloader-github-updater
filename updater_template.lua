script_name('ExampleUpdater')
script_version('1.0.0')

local LOCAL_VERSION = '1.0.0'

-- ============================================================
--  UPDATER (НАСТРОЙКИ)
-- ============================================================
local SCRIPT_FILENAME = 'example_updater.lua' -- Имя файла в вашем репозитории
local GH_USER, GH_REPO, GH_BRANCH = 'ВАШ_НИК', 'ВАШ_РЕПОЗИТОРИЙ', 'main'

local UPDATE_URL_VERSION = ('https://raw.githubusercontent.com/%s/%s/%s/version.txt'):format(GH_USER, GH_REPO, GH_BRANCH)
local UPDATE_URL_SCRIPT  = ('https://raw.githubusercontent.com/%s/%s/%s/%s'):format(GH_USER, GH_REPO, GH_BRANCH, SCRIPT_FILENAME)

local UPDATE_DIALOG_ID   = 8889
local AUTO_CHECK_DELAY   = 10          -- сек после загрузки игры до первой проверки
local AUTO_CHECK_EVERY   = 30 * 60     -- сек между тихими проверками (раз в 30 мин)
local DOWNLOAD_TIMEOUT   = 25          -- сек на одну попытку загрузки
local MIN_SCRIPT_SIZE    = 1000        -- байт: минимальный вес файла (защита от скачивания 404 ошибки)

-- ============================================================
--  UPDATER (ДВИЖОК И ТРАНСПОРТЫ)
-- ============================================================
local updateAvailable     = false
local updateDownloading   = false
local remoteVersion       = ''
local updaterStatus       = 'не проверялось'
local lastAutoCheck       = 0
local pendingUpdatePrompt = false
local promptRetryAt       = 0
local promptedVersion     = nil
local WORK_DIR            = getWorkingDirectory()

local okMoon, moonlib = pcall(require, 'moonloader')
local DS_END = 6
if okMoon and moonlib and moonlib.download_status then
    DS_END = moonlib.download_status.STATUS_ENDDOWNLOADDATA
end

local okRequests, requestsLib = pcall(require, 'requests')
local okHttp,  http  = pcall(require, 'socket.http')
local okHttps, https = pcall(require, 'ssl.https')

local hasRawDownload = (downloadUrlToFile ~= nil)
local hasRequests    = (okRequests and requestsLib ~= nil)
local hasSecureHttp  = (okHttps and https ~= nil)
local canDownload    = hasRawDownload or hasRequests or hasSecureHttp

local function urlNoCache(url)
    return url .. (url:find('?', 1, true) and '&' or '?') .. 'nocache=' .. tostring(os.time())
end

local function readFile(path)
    local f = io.open(path, 'rb'); if not f then return nil end
    local content = f:read('*a'); f:close(); return content
end

local function writeFile(path, content)
    local f = io.open(path, 'wb'); if not f then return false end
    f:write(content); f:close(); return true
end

local function socketRequestOnce(url)
    local body = {}
    local sink = function(chunk) if chunk then body[#body + 1] = chunk end; return 1 end
    local isHttps = url:match('^https') ~= nil
    local lib = isHttps and https or http
    if not lib then return nil, nil, isHttps and 'нет ssl.https' or 'нет socket.http' end
    local ok, res, code, headers = pcall(lib.request, { url = url, sink = sink, method = 'GET' })
    if not ok then return nil, nil, tostring(res) end
    if res ~= 1 then return nil, nil, tostring(code or res or 'request failed') end
    if code == 200 then return table.concat(body), 200 end
    local location = type(headers) == 'table' and headers.location or nil
    return nil, code, nil, location
end

local function socketFetch(url)
    local current = urlNoCache(url)
    for attempt = 1, 4 do
        local text, code, err, location = socketRequestOnce(current)
        if text then return text == '' and nil or text, 'пустой ответ' end
        if location and (code == 301 or code == 302 or code == 303 or code == 307) then
            if location:sub(1, 1) == '/' then
                local schemeHost = current:match('^(https?://[^/]+)')
                location = schemeHost and (schemeHost .. location) or location
            end
            current = location
        else
            return nil, err or ('HTTP ' .. tostring(code))
        end
    end
    return nil, 'слишком много редиректов'
end

local function rawFetch(url, timeout)
    local tmp = WORK_DIR .. '/updater_tmp.txt'
    os.remove(tmp)
    local finished = false
    local ok = pcall(downloadUrlToFile, urlNoCache(url), tmp, function(id, status)
        if status == DS_END then finished = true end
    end)
    if not ok then return nil, 'downloadUrlToFile недоступен' end
    local t0 = os.clock()
    while not finished and (os.clock() - t0) < timeout do wait(0) end
    local content = finished and readFile(tmp) or nil
    os.remove(tmp)
    return content and content ~= '' and content or nil, 'таймаут downloadUrlToFile'
end

local function requestsFetch(url)
    if not hasRequests then return nil, 'нет requests' end
    local ok, resp = pcall(requestsLib.request, 'GET', urlNoCache(url))
    if not ok or not resp then return nil, 'requests err' end
    local code = tonumber(resp.status_code) or 0
    if code ~= 200 then return nil, 'HTTP ' .. tostring(code) end
    local body = resp.text or resp.content
    return body and body ~= '' and body or nil, 'пустой ответ'
end

local function fetchText(url, timeout)
    if hasRawDownload then local b = rawFetch(url, timeout); if b then return b end end
    if hasRequests    then local b = requestsFetch(url); if b then return b end end
    if hasSecureHttp or (okHttp and http) then local b = socketFetch(url); if b then return b end end
    return nil, 'нет транспорта или ошибка загрузки'
end

local function applyVersionText(text)
    local ver = tostring(text or ''):match('%d+%.%d+%.%d+')
    if not ver then return 'err' end
    remoteVersion = ver
    updateAvailable = (LOCAL_VERSION ~= ver)
    return updateAvailable and 'new' or 'same'
end

local function scriptPath()
    local ok, info = pcall(thisScript)
    if ok and info then
        local okPath, path = pcall(function() return info.path end)
        if okPath and type(path) == 'string' and path ~= '' then return path end
    end
    return WORK_DIR .. '/' .. SCRIPT_FILENAME
end

local doCheck, doUpdate

local function promptUpdate()
    if not updateAvailable then return end
    if promptedVersion == remoteVersion then return end
    promptedVersion = remoteVersion
    pendingUpdatePrompt = true
end

doCheck = function(silent, thenDownload)
    if updateDownloading then return end
    if not canDownload then
        updaterStatus = 'нет http-транспорта'
        if not silent then sampAddChatMessage("[Updater] Скачивание недоступно на этой сборке.", 0xFF0000) end
        return
    end

    updateDownloading = true
    updaterStatus = 'проверяю...'
    if not silent then sampAddChatMessage("[Updater] Проверяю обновление на GitHub...", 0xFFFF00) end

    lua_thread.create(function()
        local ok, body, err = pcall(fetchText, UPDATE_URL_VERSION, 15)
        updateDownloading = false
        if not ok then body, err = nil, tostring(body) end

        if not body then
            updaterStatus = 'ошибка проверки'
            if not silent then sampAddChatMessage("[Updater] Не удалось проверить обновление.", 0xFF0000) end
            return
        end

        local st = applyVersionText(body)
        if st == 'new' then
            updaterStatus = 'доступно v' .. remoteVersion
            if not silent or promptedVersion ~= remoteVersion then
                sampAddChatMessage("[Updater] Доступно обновление: v" .. remoteVersion, 0x00FF00)
            end
            if thenDownload then doUpdate() else promptUpdate() end
        elseif st == 'same' then
            updaterStatus = 'последняя версия'
            if not silent then sampAddChatMessage("[Updater] У вас последняя версия: v" .. LOCAL_VERSION, 0x00FF00) end
        else
            updaterStatus = 'неверный ответ'
            if not silent then sampAddChatMessage("[Updater] Ошибка: неверный формат version.txt на GitHub.", 0xFF0000) end
        end
    end)
end

doUpdate = function()
    if updateDownloading then return end
    if not canDownload then return end

    updateDownloading = true
    updaterStatus = 'скачиваю v' .. remoteVersion
    sampAddChatMessage("[Updater] Скачиваю обновление v" .. remoteVersion .. "...", 0xFFFF00)

    lua_thread.create(function()
        local ok, body, err = pcall(fetchText, UPDATE_URL_SCRIPT, DOWNLOAD_TIMEOUT)
        updateDownloading = false
        if not ok then body, err = nil, tostring(body) end

        if not body or body == '' then
            updaterStatus = 'ошибка загрузки'
            sampAddChatMessage("[Updater] Ошибка скачивания обновления.", 0xFF0000)
            return
        end

        if #body < MIN_SCRIPT_SIZE then
            updaterStatus = 'файл повреждён'
            sampAddChatMessage("[Updater] Скачался битый файл (слишком маленький).", 0xFF0000)
            return
        end

        if not body:find('script_name', 1, true) then
            updaterStatus = 'это не скрипт'
            sampAddChatMessage("[Updater] На GitHub лежит не скрипт.", 0xFF0000)
            return
        end

        local tmp = WORK_DIR .. '/updater_tmp_file.lua'
        if not writeFile(tmp, body) then
            updaterStatus = 'ошибка записи'
            sampAddChatMessage("[Updater] Не удалось записать обновление на диск