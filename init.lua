local slots = {}

local jumpMods = { "alt" }
local assignMods = { "alt", "shift" }
local keys = { "q", "w", "e", "r", "1", "2", "3", "4" }

-- Mission Control 和 Space 切换都有异步动画。不要用一次固定延时判断
-- 是否完成，而是在此时间内持续确认目标 Space 并重试聚焦。
local missionControlExitDelay = 0.15
local spaceSwitchTimeout = 2.0
local spaceSwitchPollInterval = 0.05
local jumpGeneration = 0

local function windowDescription(win)
    local app = win:application()
    local appName = app and app:name() or "Unknown"
    local title = win:title()

    if not title or title == "" then
        return appName
    end

    return appName .. " — " .. title
end

local function contains(list, value)
    if not list then
        return false
    end

    for _, item in ipairs(list) do
        if item == value then
            return true
        end
    end

    return false
end

local function assignWindow(slot)
    local win = hs.window.focusedWindow()

    if not win then
        hs.alert.show("当前没有可登记的窗口")
        return
    end

    local spaces, err = hs.spaces.windowSpaces(win)

    if not spaces or #spaces == 0 then
        hs.alert.show(
            "无法读取窗口所在桌面" ..
            (err and "\n" .. tostring(err) or "")
        )
        return
    end

    slots[slot] = {
        -- 保留窗口对象本身；仅靠 hs.window.get(id) 在其他 Space
        -- 上可能受 macOS 窗口枚举限制
        window = win,
        id = win:id(),
        spaceID = spaces[1],
        description = windowDescription(win),
    }

    hs.alert.show(
        "窗口 " .. keys[slot]:upper() .. "：\n" ..
        slots[slot].description
    )
end

local function focusSavedWindow(slot)
    local saved = slots[slot]

    if not saved then
        hs.alert.show(
            "窗口 " .. keys[slot]:upper() .. " 尚未登记"
        )
        return
    end

    local win = saved.window

    -- 窗口对象在关闭后可能仍被 Lua 引用，但已经失效
    if not win or not win:application() then
        slots[slot] = nil
        hs.alert.show(
            "窗口 " .. keys[slot]:upper() .. " 已关闭，请重新登记"
        )
        return
    end

    if win:isMinimized() then
        win:unminimize()
    end

    -- raise() 再 focus()，对部分应用更可靠
    win:raise()
    win:focus()
end

local function isSpaceVisible(spaceID)
    for _, activeSpaceID in pairs(hs.spaces.activeSpaces() or {}) do
        if activeSpaceID == spaceID then
            return true
        end
    end

    return false
end

local function moveMouseToWindowIfNeeded(win, mouseScreenUUID)
    local targetScreen = win:screen()

    -- 如果鼠标已经在目标窗口所在屏幕，则不移动鼠标
    -- if not mouseScreenUUID or
    --     not targetScreen or
    --     targetScreen:getUUID() == mouseScreenUUID then
    --     return
    -- end

    local frame = win:frame()
    hs.mouse.absolutePosition({
        x = frame.x + frame.w / 2,
        y = frame.y + frame.h / 2,
    })
end

local function focusWhenSpaceIsReady(
    slot,
    generation,
    startedAt,
    mouseScreenUUID
)
    -- 连续按多个跳转键时，让先前跳转产生的定时器自动失效
    if generation ~= jumpGeneration then
        return
    end

    local saved = slots[slot]
    if not saved then
        return
    end

    if isSpaceVisible(saved.spaceID) then
        focusSavedWindow(slot)
        moveMouseToWindowIfNeeded(saved.window, mouseScreenUUID)

        -- 某些应用第一次 focus 会被 Space 动画吞掉，再补一次
        hs.timer.doAfter(0.1, function()
            if generation == jumpGeneration then
                focusSavedWindow(slot)
            end
        end)
        return
    end

    if hs.timer.secondsSinceEpoch() - startedAt >= spaceSwitchTimeout then
        hs.alert.show("切换桌面超时，请再试一次")
        return
    end

    hs.timer.doAfter(spaceSwitchPollInterval, function()
        focusWhenSpaceIsReady(
            slot,
            generation,
            startedAt,
            mouseScreenUUID
        )
    end)
end

local function jumpToWindow(slot)
    local saved = slots[slot]

    if not saved then
        hs.alert.show(
            "窗口 " .. keys[slot]:upper() .. " 尚未登记"
        )
        return
    end

    local win = saved.window

    if not win or not win:application() then
        slots[slot] = nil
        hs.alert.show(
            "窗口 " .. keys[slot]:upper() .. " 已关闭，请重新登记"
        )
        return
    end

    -- 窗口可能被用户移动到了另一个 Space，切换前重新读取
    local currentWindowSpaces = hs.spaces.windowSpaces(win)

    if currentWindowSpaces and #currentWindowSpaces > 0 then
        saved.spaceID = currentWindowSpaces[1]
    end

    jumpGeneration = jumpGeneration + 1
    local generation = jumpGeneration
    local mouseScreen = hs.mouse.getCurrentScreen()
    local mouseScreenUUID = mouseScreen and mouseScreen:getUUID() or nil

    -- 若当前停在 Mission Control，先退出；不在其中时调用也是安全的。
    -- 给退出动画一点启动时间，避免 gotoSpace() 被 Mission Control 吞掉。
    hs.spaces.closeMissionControl()
    hs.timer.doAfter(missionControlExitDelay, function()
        if generation ~= jumpGeneration then
            return
        end

        if not isSpaceVisible(saved.spaceID) then
            local ok = hs.spaces.gotoSpace(saved.spaceID)
            if not ok then
                hs.alert.show(
                    "无法切换到窗口 " ..
                    keys[slot]:upper() ..
                    " 所在桌面"
                )
                return
            end
        end

        focusWhenSpaceIsReady(
            slot,
            generation,
            hs.timer.secondsSinceEpoch(),
            mouseScreenUUID
        )
    end)
end


for slot, key in ipairs(keys) do
    hs.hotkey.bind(assignMods, key, function()
        assignWindow(slot)
    end)

    hs.hotkey.bind(jumpMods, key, function()
        jumpToWindow(slot)
    end)
end

hs.hotkey.bind({ "alt" }, "`", function()
  hs.spaces.openMissionControl()
end)

hs.alert.show("窗口快捷键已加载")
