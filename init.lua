local slots = {}

local jumpMods = { "alt" }
local assignMods = { "alt", "shift" }
local keys = { "q", "w", "e", "r", "1", "2", "3", "4" }

-- Mission Control 和 Space 切换都有异步动画。不要用一次固定延时判断
-- 是否完成，而是在此时间内持续确认目标 Space 并重试聚焦。
local missionControlExitDelay = 0.15
local spaceSwitchTimeout = 2.0
local spaceSwitchPollInterval = 0.05
local nearlyFullScreenRatio = 0.9
local doublePressInterval = 0.2
local jumpGeneration = 0
local pendingJumpTimers = {}

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

local function moveMouseToWindowCenter(win)
    local frame = win:frame()
    hs.mouse.absolutePosition({
        x = frame.x + frame.w / 2,
        y = frame.y + frame.h / 2,
    })
end

local function moveWindowToMouse(win)
    local mousePosition = hs.mouse.absolutePosition()
    local frame = win:frame()
    local sourceScreen = win:screen()
    local targetScreen = hs.mouse.getCurrentScreen()
    local isCrossScreen = sourceScreen and
        targetScreen and
        sourceScreen:getUUID() ~= targetScreen:getUUID()

    if isCrossScreen then
        -- frame() 是目标显示器扣除 macOS 菜单栏和 Dock 后的可用区域。
        local targetFrame = targetScreen:frame()

        if frame.w > targetFrame.w or frame.h > targetFrame.h then
            -- 原窗口在目标显示器放不下时，改为可用区域铺满。
            win:setFrame(targetFrame, 0)
            moveMouseToWindowCenter(win)
            return
        end

        -- 保留原尺寸和尽可能靠近鼠标的中心位置，同时保证整个窗口
        -- 都位于目标显示器的可用区域内。
        local x = mousePosition.x - frame.w / 2
        local y = mousePosition.y - frame.h / 2
        x = math.max(targetFrame.x, math.min(
            x,
            targetFrame.x + targetFrame.w - frame.w
        ))
        y = math.max(targetFrame.y, math.min(
            y,
            targetFrame.y + targetFrame.h - frame.h
        ))

        win:setFrame({
            x = x,
            y = y,
            w = frame.w,
            h = frame.h,
        }, 0)
        moveMouseToWindowCenter(win)
        return
    end

    if sourceScreen then
        local usableFrame = sourceScreen:frame()
        local windowArea = frame.w * frame.h
        local usableArea = usableFrame.w * usableFrame.h

        -- 同屏且窗口已经使用至少 90% 的可用面积时，不移动窗口或鼠标。
        if usableArea > 0 and
            windowArea / usableArea >= nearlyFullScreenRatio then
            return
        end
    end

    -- 同屏移动也限制在可用区域内，保证窗口不会因为鼠标靠近
    -- 屏幕边缘而有一部分落到屏幕外。
    local movementScreen = targetScreen or sourceScreen
    if not movementScreen then
        return
    end

    local targetFrame = movementScreen:frame()
    local x = mousePosition.x - frame.w / 2
    local y = mousePosition.y - frame.h / 2

    -- 极少数非近似全屏窗口可能单边尺寸仍超过屏幕；这种情况下
    -- 也缩放到可用区域，才能保证整个窗口可见。
    if frame.w > targetFrame.w or frame.h > targetFrame.h then
        win:setFrame(targetFrame, 0)
        moveMouseToWindowCenter(win)
        return
    end

    x = math.max(targetFrame.x, math.min(
        x,
        targetFrame.x + targetFrame.w - frame.w
    ))
    y = math.max(targetFrame.y, math.min(
        y,
        targetFrame.y + targetFrame.h - frame.h
    ))

    win:setFrame({
        x = x,
        y = y,
        w = frame.w,
        h = frame.h,
    }, 0)
    moveMouseToWindowCenter(win)
end

local function focusWhenSpaceIsReady(
    slot,
    generation,
    startedAt
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
        moveMouseToWindowCenter(saved.window)

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
            startedAt
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
            hs.timer.secondsSinceEpoch()
        )
    end)
end

local function moveSavedWindowToMouse(slot)
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

    if win:isMinimized() then
        win:unminimize()
    end

    jumpGeneration = jumpGeneration + 1
    local generation = jumpGeneration
    local mouseScreen = hs.mouse.getCurrentScreen()
    local targetSpace = mouseScreen and
        (hs.spaces.activeSpaces() or {})[mouseScreen:getUUID()] or nil
    local windowSpaces = hs.spaces.windowSpaces(win)

    local function finishMove()
        if generation ~= jumpGeneration then
            return
        end

        moveWindowToMouse(win)
        win:raise()
        win:focus()
    end

    if targetSpace and not contains(windowSpaces, targetSpace) then
        local ok = hs.spaces.moveWindowToSpace(win, targetSpace)
        if not ok then
            hs.alert.show("无法把窗口移动到鼠标所在桌面")
            return
        end

        -- 给 macOS 一点时间完成 Space 归属变更，再调整跨屏坐标。
        hs.timer.doAfter(0.05, finishMove)
        return
    end

    finishMove()
end

local function handleJumpKey(slot)
    local pendingTimer = pendingJumpTimers[slot]

    if pendingTimer then
        -- 0.2 秒内第二次按下：取消单击，改为让窗口找鼠标。
        pendingTimer:stop()
        pendingJumpTimers[slot] = nil
        moveSavedWindowToMouse(slot)
        return
    end

    -- 延迟执行单击，给第二次按键留出判断时间。
    pendingJumpTimers[slot] = hs.timer.doAfter(doublePressInterval, function()
        pendingJumpTimers[slot] = nil
        jumpToWindow(slot)
    end)
end


for slot, key in ipairs(keys) do
    hs.hotkey.bind(assignMods, key, function()
        assignWindow(slot)
    end)

    hs.hotkey.bind(jumpMods, key, function()
        handleJumpKey(slot)
    end)
end

hs.hotkey.bind({ "alt" }, "`", function()
  hs.spaces.openMissionControl()
end)

hs.alert.show("窗口快捷键已加载")
