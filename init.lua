local slots = {}

-- hs.spaces.gotoSpace() 依赖 Mission Control 的辅助功能元素。
-- 默认的 0.3 秒在系统繁忙或动画尚未完成时可能不够。
hs.spaces.MCwaitTime = 0.4
hs.spaces.setDefaultMCwaitTime(0.4)

local jumpMods = { "alt" }
local assignMods = { "alt", "shift" }
local keys = { "q", "w", "e", "r", "1", "2", "3", "4" }

-- gotoSpace() 返回 true 只表示已发起切换。若短时间内目标
-- Space 仍未可见，主动重试一次，不做无意义的长时间等待。
local spaceSwitchAttemptTimeout = 0.5
local spaceSwitchPollInterval = 0.05
local maxSpaceSwitchAttempts = 2
local doublePressInterval = 0.2
local maxUndoStates = 10
local maxFocusHistoryStates = 100
local jumpGeneration = 0
local pendingJumpTimers = {}
local pendingFractionTimers = {}
local windowUndoStacks = {}
local scaleFactors = { 0.9, 1 / 0.9 }
local maxDescriptionLength = 60
local moveMouseToWindowCenter
local mouseFollowTap = nil
local mouseFollowWindow = nil

-- 最前窗口历史采用类似浏览器的后退/前进双栈。普通的焦点变化
-- （鼠标点击、Cmd-Tab、Alt+QWER/1234 等）会清空前进栈；只有
-- Alt+Z/Alt+Shift+Z 自身造成的焦点变化不会被再次写入历史。
local focusBackStack = {}
local focusForwardStack = {}
local lastFocusedWindow = nil
local expectedHistoryFocusID = nil
local historyFocusGeneration = 0

local function windowIDIfValid(win)
    if not win then
        return nil
    end

    local ok, app, windowID, frame, windowSpaces = pcall(function()
        return win:application(), win:id(), win:frame(),
            hs.spaces.windowSpaces(win)
    end)
    if not ok or app == nil or windowID == nil or windowID <= 0 then
        return nil
    end

    -- 已关闭窗口的 AX 对象可能仍能返回 application() 和 id()。
    -- WindowServer 中真实存在的窗口应仍有 Space 归属和有效尺寸。
    if type(windowSpaces) ~= "table" or #windowSpaces == 0 or
        not frame or frame.w <= 0 or frame.h <= 0 or
        frame.x ~= frame.x or frame.y ~= frame.y then
        return nil
    end

    return windowID
end

local function validWindow(win)
    return windowIDIfValid(win) ~= nil
end

-- Sheet/confirm 获得 AX 焦点时，它所属的文档窗口不会再发出
-- windowFocused。历史里应记录可再次访问的文档窗口，而不是短命的
-- AXSheet 对象，因此尽量沿 AX 父链找到它附着的 hs.window。
local function normalizeFocusedWindow(win)
    if not win then
        return nil
    end

    local ok, subrole = pcall(function()
        return win:subrole()
    end)
    local isSheet = ok and subrole == "AXSheet"
    if not isSheet and validWindow(win) then
        return win
    end

    local originalID = nil
    pcall(function()
        originalID = win:id()
    end)

    local parentWindow = nil
    pcall(function()
        local element = hs.axuielement.windowElement(win)
        local path = element and element:path() or {}
        -- path() 从根到当前元素，倒序即从最近的父元素开始。
        for index = #path - 1, 1, -1 do
            local candidate = path[index]:asHSWindow()
            local candidateID = windowIDIfValid(candidate)
            if candidateID and candidateID ~= originalID then
                parentWindow = candidate
                break
            end
        end
    end)
    if parentWindow then
        return parentWindow
    end

    -- 有些应用不公开 sheet 的 AXParent。这时 mainWindow 通常就是
    -- modal 所属的文档窗口。
    if isSheet then
        local mainWindow = nil
        pcall(function()
            local app = win:application()
            mainWindow = app and app:mainWindow() or nil
        end)
        if validWindow(mainWindow) then
            return mainWindow
        end
    end

    if validWindow(win) then
        return win
    end

    return nil
end

lastFocusedWindow = normalizeFocusedWindow(hs.window.focusedWindow())

local function pushFocusHistory(stack, win)
    local windowID = windowIDIfValid(win)
    if not windowID then
        return
    end

    -- 同一窗口只保留最近一次出现的位置；顺便清除已经关闭的窗口。
    for index = #stack, 1, -1 do
        local savedID = windowIDIfValid(stack[index])
        if not savedID or savedID == windowID then
            table.remove(stack, index)
        end
    end

    table.insert(stack, win)
    if #stack > maxFocusHistoryStates then
        table.remove(stack, 1)
    end
end

local function popValidFocusHistory(stack, currentID)
    while #stack > 0 do
        local win = table.remove(stack)
        local windowID = windowIDIfValid(win)
        if windowID and windowID ~= currentID then
            return win
        end
    end

    return nil
end

local function focusHistoryWindow(win)
    if not validWindow(win) then
        return false
    end

    local ok = pcall(function()
        if win:isMinimized() then
            win:unminimize()
        end

        win:raise()
        win:focus()
    end)
    if not ok or not validWindow(win) then
        return false
    end

    return moveMouseToWindowCenter(win)
end

local function navigateFocusHistory(sourceStack, destinationStack, emptyMessage)
    local current = hs.window.focusedWindow()
    if not validWindow(current) then
        current = lastFocusedWindow
    end

    local currentID = windowIDIfValid(current)
    historyFocusGeneration = historyFocusGeneration + 1
    local generation = historyFocusGeneration
    expectedHistoryFocusID = nil
    local target
    while true do
        target = popValidFocusHistory(sourceStack, currentID)
        if not target then
            hs.alert.show(emptyMessage)
            return
        end

        -- 窗口可能在出栈后、真正聚焦前关闭。失败时继续向前回退，
        -- 不让历史导航停在只剩应用、没有实际窗口的状态。
        expectedHistoryFocusID = target:id()
        if focusHistoryWindow(target) then
            break
        end
        expectedHistoryFocusID = nil
    end

    pushFocusHistory(destinationStack, current)
    lastFocusedWindow = target

    -- 跨 Space 切换时焦点通知可能较晚；超时后不再把后续的手动
    -- 切换误认为这次历史导航。
    hs.timer.doAfter(1.5, function()
        if generation == historyFocusGeneration then
            expectedHistoryFocusID = nil
        end
    end)
end

-- new(true) 不继承默认过滤器，因此 AXSheet 和应用自定义的
-- modal subrole 也有机会产生焦点事件。不在此处做 Space 过滤。
local focusHistoryFilter = hs.window.filter.new(true)
focusHistoryFilter:subscribe(hs.window.filter.windowFocused, function(win)
    win = normalizeFocusedWindow(win)
    if not validWindow(win) then
        return
    end

    local windowID = win:id()
    if windowID == expectedHistoryFocusID then
        expectedHistoryFocusID = nil
        lastFocusedWindow = win
        return
    end

    -- 任何非历史导航的焦点变化都开始一条新路径，Alt+Shift+Z 随即失效。
    historyFocusGeneration = historyFocusGeneration + 1
    expectedHistoryFocusID = nil
    if validWindow(lastFocusedWindow) and
        lastFocusedWindow:id() ~= windowID then
        pushFocusHistory(focusBackStack, lastFocusedWindow)
    end
    focusForwardStack = {}
    lastFocusedWindow = win
end)

local function windowDescription(win)
    local app = win:application()
    local appName = app and app:name() or "Unknown"
    -- local title = win:title()

    -- if not title or title == "" then
    --     return appName
    -- end

    return appName -- .. " — " .. title
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

local function screenContainingPoint(point)
    for _, screen in ipairs(hs.screen.allScreens()) do
        -- fullFrame() 包含菜单栏和 Dock 区域，更适合判断一个全局坐标
        -- 实际属于哪块显示器；窗口边界限制仍使用下面的 frame()。
        local frame = screen:fullFrame()

        if point.x >= frame.x and
            point.x < frame.x + frame.w and
            point.y >= frame.y and
            point.y < frame.y + frame.h then
            return screen
        end
    end

    return nil
end

local function constrainWindowFrameToScreen(win, requestedFrame)
    local center = {
        x = requestedFrame.x + requestedFrame.w / 2,
        y = requestedFrame.y + requestedFrame.h / 2,
    }
    local screen = screenContainingPoint(center) or win:screen()

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
        hs.alert.show("There is no window to undo")
        return
    end

    local stack = windowUndoStacks[win:id()]
    if not stack or #stack == 0 then
        hs.alert.show("The current window has no state to undo")
        return
    end

    applyConstrainedWindowFrame(win, table.remove(stack))
end

local function assignWindow(slot)
    local win = hs.window.focusedWindow()

    if not win then
        hs.alert.show("There is no window to register")
        return
    end

    local spaces, err = hs.spaces.windowSpaces(win)

    if not spaces or #spaces == 0 then
        hs.alert.show(
            "Unable to read the window's desktop" ..
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

    local truncatedDescription = slots[slot].description
    if #truncatedDescription > maxDescriptionLength then
        truncatedDescription = truncatedDescription:sub(1, maxDescriptionLength) .. "..."
    end

    local message = "Window " .. keys[slot]:upper() .. ":\n" ..
        truncatedDescription

    if #releasedKeys > 0 then
        message = message .. "\nReleased previous key: " ..
            table.concat(releasedKeys, "  ")
    end

    hs.alert.show(message)
end

local function focusSavedWindow(slot)
    local saved = slots[slot]

    if not saved then
        hs.alert.show(
            "Window " .. keys[slot]:upper() .. " is not registered"
        )
        return
    end

    local win = saved.window

    -- 窗口对象在关闭后可能仍被 Lua 引用，但已经失效
    if not win or not win:application() then
        slots[slot] = nil
        hs.alert.show(
            "Window " .. keys[slot]:upper() .. " is closed; please register it again"
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

moveMouseToWindowCenter = function(win)
    if not validWindow(win) then
        return false
    end

    local ok, frame = pcall(function()
        return win:frame()
    end)
    if not ok or not frame then
        return false
    end

    local center = {
        x = frame.x + frame.w / 2,
        y = frame.y + frame.h / 2,
    }
    if not screenContainingPoint(center) then
        return false
    end

    hs.mouse.absolutePosition({
        x = center.x,
        y = center.y,
    })
    return true
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

local function stopMouseFollow(message)
    if mouseFollowTap then
        mouseFollowTap:stop()
        mouseFollowTap = nil
    end

    mouseFollowWindow = nil
    if message then
        hs.alert.show(message)
    end
end

local function moveFollowingWindowToMouse()
    local win = mouseFollowWindow
    if not validWindow(win) then
        stopMouseFollow("The attached window was closed; following stopped")
        return
    end

    local mousePosition = hs.mouse.absolutePosition()
    local frame = win:frame()
    applyConstrainedWindowFrame(win, {
        x = mousePosition.x - frame.w / 2,
        y = mousePosition.y - frame.h / 2,
        w = frame.w,
        h = frame.h,
    })
end

local function toggleMouseFollow()
    if mouseFollowTap then
        stopMouseFollow()
        return
    end

    local win = hs.window.focusedWindow()
    if not validWindow(win) then
        hs.alert.show("There is no window to move")
        return
    end

    mouseFollowWindow = win
    mouseFollowTap = hs.eventtap.new({
        hs.eventtap.event.types.mouseMoved,
        hs.eventtap.event.types.leftMouseDragged,
        hs.eventtap.event.types.rightMouseDragged,
        hs.eventtap.event.types.otherMouseDragged,
    }, function()
        moveFollowingWindowToMouse()
        return false
    end)
    mouseFollowTap:start()
    moveFollowingWindowToMouse()
end

local function focusWhenSpaceIsReady(
    slot,
    generation,
    attempt,
    attemptStartedAt
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

    if hs.timer.secondsSinceEpoch() - attemptStartedAt >=
        spaceSwitchAttemptTimeout then
        if attempt < maxSpaceSwitchAttempts then
            local ok, err = hs.spaces.gotoSpace(saved.spaceID)
            if not ok then
                hs.alert.show(
                    "Retrying the desktop switch failed" ..
                    (err and "\n" .. tostring(err) or "")
                )
                return
            end

            focusWhenSpaceIsReady(
                slot,
                generation,
                attempt + 1,
                hs.timer.secondsSinceEpoch()
            )
            return
        end

        hs.alert.show("Both attempts to switch desktops failed")
        return
    end

    hs.timer.doAfter(spaceSwitchPollInterval, function()
        focusWhenSpaceIsReady(
            slot,
            generation,
            attempt,
            attemptStartedAt
        )
    end)
end

local function jumpToWindow(slot)
    local saved = slots[slot]

    if not saved then
        hs.alert.show(
            "Window " .. keys[slot]:upper() .. " is not registered"
        )
        return
    end

    local win = saved.window

    if not win or not win:application() then
        slots[slot] = nil
        hs.alert.show(
            "Window " .. keys[slot]:upper() .. " is closed; please register it again"
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

    if isSpaceVisible(saved.spaceID) then
        focusWhenSpaceIsReady(
            slot,
            generation,
            1,
            hs.timer.secondsSinceEpoch()
        )
        return
    end

    -- gotoSpace() 自己会打开并关闭 Mission Control。预先强制关闭
    -- 反而可能与它的打开动作竞争。
    local ok, err = hs.spaces.gotoSpace(saved.spaceID)
    if not ok then
        hs.alert.show(
            "Unable to switch to the desktop containing window " ..
            keys[slot]:upper() ..
            (err and "\n" .. tostring(err) or "")
        )
        return
    end

    focusWhenSpaceIsReady(
        slot,
        generation,
        1,
        hs.timer.secondsSinceEpoch()
    )
end

local function moveSavedWindowToMouse(slot)
    local saved = slots[slot]

    if not saved then
        hs.alert.show(
            "Window " .. keys[slot]:upper() .. " is not registered"
        )
        return
    end

    local win = saved.window
    if not win or not win:application() then
        slots[slot] = nil
        hs.alert.show(
            "Window " .. keys[slot]:upper() .. " is closed; please register it again"
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
            hs.alert.show("Unable to move the window to the desktop under the pointer")
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
    local descriptionsStr = ""

    for slot, key in ipairs(keys) do
        local saved = slots[slot]
        -- 使用与焦点历史相同的强校验：窗口必须仍有有效的应用、ID、
        -- WindowServer Space 归属和非零尺寸。
        local isAvailable = saved ~= nil and validWindow(saved.window)

        if not isAvailable then
            slots[slot] = nil
            saved = nil
            table.insert(assignableKeys, key:upper())

            local pendingTimer = pendingJumpTimers[slot]
            if pendingTimer then
                pendingTimer:stop()
                pendingJumpTimers[slot] = nil
            end
        end

        if saved then
            local truncateDescription = saved.description
            if #truncateDescription > maxDescriptionLength then
                truncateDescription = truncateDescription:sub(
                    1,
                    maxDescriptionLength
                ) .. "..."
            end

            descriptionsStr = descriptionsStr .. key:upper() .. ": " ..
                truncateDescription .. "\n"
        end
    end

    hs.alert.show(
        descriptionsStr ..
        "Keys available for registration:\n" .. table.concat(assignableKeys, "  "),
        3
    )
end

local function layoutActiveWindow(side, fraction)
    local win = hs.window.focusedWindow()
    if not win then
        hs.alert.show("There is no window to resize")
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

local function layoutActiveWindowVertical(side, fraction)
    local win = hs.window.focusedWindow()
    if not win then
        hs.alert.show("There is no window to resize")
        return
    end

    local screen = win:screen()
    if not screen then
        return
    end

    local screenFrame = screen:frame()
    local height = screenFrame.h * fraction
    local y = screenFrame.y

    if side == "bottom" then
        y = screenFrame.y + screenFrame.h - height
    end

    setWindowFrameWithUndo(win, {
        x = screenFrame.x,
        y = y,
        w = screenFrame.w,
        h = height,
    })
end

local function maximizeActiveWindow()
    local win = hs.window.focusedWindow()
    if not win then
        hs.alert.show("There is no window to resize")
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
        hs.alert.show("There is no window to resize")
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

hs.hotkey.bind({ "alt" }, "z", function()
    navigateFocusHistory(
        focusBackStack,
        focusForwardStack,
        "There is no earlier window"
    )
end)

hs.hotkey.bind({ "alt", "shift" }, "z", function()
    navigateFocusHistory(
        focusForwardStack,
        focusBackStack,
        "There is no later window"
    )
end)

hs.hotkey.bind({ "alt", "shift" }, "x", function()
    cleanAndShowAssignableKeys()
end)

hs.hotkey.bind({ "alt" }, "x", function()
    toggleMouseFollow()
end)

hs.hotkey.bind({ "alt" }, "left", function()
    layoutActiveWindow("left", 1 / 2)
end)

hs.hotkey.bind({ "alt" }, "right", function()
    layoutActiveWindow("right", 1 / 2)
end)

hs.hotkey.bind({ "alt" }, "up", function()
    layoutActiveWindowVertical("top", 1 / 2)
end)

hs.hotkey.bind({ "alt" }, "down", function()
    layoutActiveWindowVertical("bottom", 1 / 2)
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

hs.hotkey.bind({ "alt", "shift" }, "-", function()
    scaleActiveWindow(scaleFactors[1])
end)

hs.hotkey.bind({ "alt", "shift" }, "=", function()
    scaleActiveWindow(scaleFactors[2])
end)

hs.hotkey.bind({ "alt" }, "`", function()
  hs.spaces.openMissionControl()
end)

hs.alert.show("Window shortcuts loaded")
