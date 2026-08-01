local slots = {}

local jumpMods = { "alt" }
local assignMods = { "alt", "shift" }
local keys = { "q", "w", "e", "r", "1", "2", "3", "4" }

-- Mission Control 和 Space 切换都有异步动画。不要用一次固定延时判断
-- 是否完成，而是在此时间内持续确认目标 Space 并重试聚焦。
local missionControlExitDelay = 0.15
local spaceSwitchTimeout = 2.0
local spaceSwitchPollInterval = 0.05
local doublePressInterval = 0.2
local maxUndoStates = 10
local jumpGeneration = 0
local pendingJumpTimers = {}
local pendingFractionTimers = {}
local windowUndoStacks = {}
local scaleFactors = { 0.9, 1 / 0.9 }

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

local function framesAreEqual(a, b)
    local epsilon = 0.5
    return math.abs(a.x - b.x) < epsilon and
        math.abs(a.y - b.y) < epsilon and
        math.abs(a.w - b.w) < epsilon and
        math.abs(a.h - b.h) < epsilon
end

local function constrainWindowFrameToScreen(win, requestedFrame)
    local center = {
        x = requestedFrame.x + requestedFrame.w / 2,
        y = requestedFrame.y + requestedFrame.h / 2,
    }
    local screen = hs.screen.find(center) or win:screen()

    if not screen then
        return requestedFrame
    end

    local screenFrame = screen:frame()
    local width = math.min(requestedFrame.w, screenFrame.w)
    local height = math.min(requestedFrame.h, screenFrame.h)
    local x = math.max(screenFrame.x, math.min(
        requestedFrame.x,
        screenFrame.x + screenFrame.w - width
    ))
    local y = math.max(screenFrame.y, math.min(
        requestedFrame.y,
        screenFrame.y + screenFrame.h - height
    ))

    return {
        x = x,
        y = y,
        w = width,
        h = height,
    }
end

local function applyConstrainedWindowFrame(win, requestedFrame)
    local constrainedFrame = constrainWindowFrameToScreen(
        win,
        requestedFrame
    )
    win:setFrame(constrainedFrame, 0)

    -- 某些应用会自行修正请求的尺寸；再根据实际结果检查一次边界。
    local actualFrame = win:frame()
    local correctedFrame = constrainWindowFrameToScreen(win, actualFrame)
    if not framesAreEqual(actualFrame, correctedFrame) then
        win:setFrame(correctedFrame, 0)
    end
end

local function setWindowFrameWithUndo(win, newFrame)
    local windowID = win:id()
    local oldFrame = win:frame()
    local constrainedFrame = constrainWindowFrameToScreen(win, newFrame)

    if not windowID or framesAreEqual(oldFrame, constrainedFrame) then
        return
    end

    local stack = windowUndoStacks[windowID]
    if not stack then
        stack = {}
        windowUndoStacks[windowID] = stack
    end

    table.insert(stack, {
        x = oldFrame.x,
        y = oldFrame.y,
        w = oldFrame.w,
        h = oldFrame.h,
    })

    if #stack > maxUndoStates then
        table.remove(stack, 1)
    end

    applyConstrainedWindowFrame(win, constrainedFrame)
end

local function undoActiveWindowFrame()
    local win = hs.window.focusedWindow()
    if not win then
        hs.alert.show("当前没有可撤销的窗口")
        return
    end

    local stack = windowUndoStacks[win:id()]
    if not stack or #stack == 0 then
        hs.alert.show("当前窗口没有可撤销的状态")
        return
    end

    applyConstrainedWindowFrame(win, table.remove(stack))
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

    local windowID = win:id()
    local releasedKeys = {}

    -- 同一个窗口只能登记到一个槽位。若它已经绑定在其他键上，
    -- 先释放旧槽位，再把它迁移到当前选择的键。
    for otherSlot, saved in pairs(slots) do
        if windowID and otherSlot ~= slot and saved.id == windowID then
            slots[otherSlot] = nil
            table.insert(releasedKeys, keys[otherSlot]:upper())

            local pendingTimer = pendingJumpTimers[otherSlot]
            if pendingTimer then
                pendingTimer:stop()
                pendingJumpTimers[otherSlot] = nil
            end
        end
    end

    slots[slot] = {
        -- 保留窗口对象本身；仅靠 hs.window.get(id) 在其他 Space
        -- 上可能受 macOS 窗口枚举限制
        window = win,
        id = windowID,
        spaceID = spaces[1],
        description = windowDescription(win),
    }

    local message = "窗口 " .. keys[slot]:upper() .. "：\n" ..
        slots[slot].description

    if #releasedKeys > 0 then
        message = message .. "\n已释放旧键：" ..
            table.concat(releasedKeys, "  ")
    end

    hs.alert.show(message)
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

    -- 同屏移动也限制在可用区域内，保证窗口不会因为鼠标靠近
    -- 屏幕边缘而有一部分落到屏幕外。
    local movementScreen = targetScreen or sourceScreen
    if not movementScreen then
        return
    end

    local targetFrame = movementScreen:frame()
    -- 宽、高分别截断；只有超限的那一边会被缩小。
    local width = math.min(frame.w, targetFrame.w)
    local height = math.min(frame.h, targetFrame.h)
    local x = mousePosition.x - width / 2
    local y = mousePosition.y - height / 2

    x = math.max(targetFrame.x, math.min(
        x,
        targetFrame.x + targetFrame.w - width
    ))
    y = math.max(targetFrame.y, math.min(
        y,
        targetFrame.y + targetFrame.h - height
    ))

    setWindowFrameWithUndo(win, {
        x = x,
        y = y,
        w = width,
        h = height,
    })
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

local function cleanAndShowAssignableKeys()
    local assignableKeys = {}

    for slot, key in ipairs(keys) do
        local saved = slots[slot]
        local isAvailable = false

        if saved and saved.window then
            -- 已关闭的窗口对象仍可能留在 Lua 中，因此用 pcall 防止
            -- 某些应用退出时 Accessibility 对象失效而抛出异常。
            local ok, app = pcall(function()
                return saved.window:application()
            end)
            isAvailable = ok and app ~= nil
        end

        if not isAvailable then
            slots[slot] = nil
            table.insert(assignableKeys, key:upper())

            local pendingTimer = pendingJumpTimers[slot]
            if pendingTimer then
                pendingTimer:stop()
                pendingJumpTimers[slot] = nil
            end
        end
    end

    if #assignableKeys == 0 then
        hs.alert.show("当前没有可重新登记的空闲按键")
        return
    end

    hs.alert.show(
        "可重新登记的按键：\n" .. table.concat(assignableKeys, "  ")
    )
end

local function layoutActiveWindow(side, fraction)
    local win = hs.window.focusedWindow()
    if not win then
        hs.alert.show("当前没有可调整的窗口")
        return
    end

    local screen = win:screen()
    if not screen then
        return
    end

    local screenFrame = screen:frame()
    local width = screenFrame.w * fraction
    local x = screenFrame.x

    if side == "right" then
        x = screenFrame.x + screenFrame.w - width
    end

    setWindowFrameWithUndo(win, {
        x = x,
        y = screenFrame.y,
        w = width,
        h = screenFrame.h,
    })
end

local function maximizeActiveWindow()
    local win = hs.window.focusedWindow()
    if not win then
        hs.alert.show("当前没有可调整的窗口")
        return
    end

    local screen = win:screen()
    if screen then
        setWindowFrameWithUndo(win, screen:frame())
    end
end

local function scaleActiveWindow(scale)
    local win = hs.window.focusedWindow()
    if not win then
        hs.alert.show("当前没有可调整的窗口")
        return
    end

    local frame = win:frame()
    local centerX = frame.x + frame.w / 2
    local centerY = frame.y + frame.h / 2
    local width = frame.w * scale
    local height = frame.h * scale

    setWindowFrameWithUndo(win, {
        x = centerX - width / 2,
        y = centerY - height / 2,
        w = width,
        h = height,
    })
end

local function handleFractionKey(side)
    local pendingTimer = pendingFractionTimers[side]

    if pendingTimer then
        -- 双击：取消左/右 2/3，改为左/右 1/3。
        pendingTimer:stop()
        pendingFractionTimers[side] = nil
        layoutActiveWindow(side, 1 / 3)
        return
    end

    -- 单击：等待 0.2 秒确认没有第二次按键，再布局为 2/3。
    pendingFractionTimers[side] = hs.timer.doAfter(
        doublePressInterval,
        function()
            pendingFractionTimers[side] = nil
            layoutActiveWindow(side, 2 / 3)
        end
    )
end


for slot, key in ipairs(keys) do
    hs.hotkey.bind(assignMods, key, function()
        assignWindow(slot)
    end)

    hs.hotkey.bind(jumpMods, key, function()
        handleJumpKey(slot)
    end)
end

hs.hotkey.bind({ "alt", "shift" }, "z", function()
    cleanAndShowAssignableKeys()
end)

hs.hotkey.bind({ "alt", "shift" }, "x", function()
    local win = hs.window.focusedWindow()
    if not win then
        hs.alert.show("当前没有可移动的窗口")
        return
    end

    moveWindowToMouse(win)
end)

hs.hotkey.bind({ "alt" }, "left", function()
    layoutActiveWindow("left", 1 / 2)
end)

hs.hotkey.bind({ "alt" }, "right", function()
    layoutActiveWindow("right", 1 / 2)
end)

hs.hotkey.bind({ "alt", "shift" }, "left", function()
    handleFractionKey("left")
end)

hs.hotkey.bind({ "alt", "shift" }, "right", function()
    handleFractionKey("right")
end)

hs.hotkey.bind({ "alt", "shift" }, "return", function()
    maximizeActiveWindow()
end)

hs.hotkey.bind({ "alt", "shift" }, "delete", function()
    undoActiveWindowFrame()
end)

hs.hotkey.bind({ "alt", "shift" }, "[", function()
    scaleActiveWindow(scaleFactors[1])
end)

hs.hotkey.bind({ "alt", "shift" }, "]", function()
    scaleActiveWindow(scaleFactors[2])
end)

hs.hotkey.bind({ "alt" }, "`", function()
  hs.spaces.openMissionControl()
end)

hs.alert.show("窗口快捷键已加载")
