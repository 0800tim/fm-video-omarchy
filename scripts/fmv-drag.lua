-- Lets the FM.video window be moved with a plain drag, no Super key needed.
--
-- The window is a web page with no title bar, so there is nothing to grab.
-- This watches the left mouse button. When it goes down over the FM.video
-- window and the pointer then moves, the window follows the pointer until
-- the button comes up. Clicks still reach the page, and no other window is
-- touched. Loaded by scripts/fmv-window with `hyprctl eval`, and gone again
-- on the next Hyprland reload or when the plugin calls fmvideo_drag.unload().

local CLASS = "^[%a-]+%-fm%.video__mini%-"   -- a Lua pattern
local THRESHOLD = 6     -- pixels the pointer must move before the window does
local MAX_TICKS = 1800  -- give up after 30 seconds, in case a release is missed

local old = rawget(_G, "fmvideo_drag")
if old and old.unload then pcall(old.unload) end

local M = { window = nil, moving = false, ticks = 0 }

local function stop()
  if M.timer then M.timer:set_enabled(false) end
  if M.window and M.moving then
    pcall(hl.dispatch, hl.dsp.window.set_prop({ window = M.window, prop = "no_anim", value = "unset" }))
  end
  M.window = nil
  M.moving = false
end

local function tick()
  M.ticks = M.ticks + 1
  local pos = hl.get_cursor_pos()
  if not M.window or not pos or M.ticks > MAX_TICKS then return stop() end
  if not M.moving then
    if math.abs(pos.x - M.start_x) < THRESHOLD and math.abs(pos.y - M.start_y) < THRESHOLD then return end
    M.moving = true
    -- Follow the pointer exactly, without the usual glide.
    pcall(hl.dispatch, hl.dsp.window.set_prop({ window = M.window, prop = "no_anim", value = "1" }))
  end
  hl.dispatch(hl.dsp.window.move({
    window = M.window,
    x = math.floor(pos.x - M.grab_x),
    y = math.floor(pos.y - M.grab_y),
  }))
end

function M.press()
  local pos = hl.get_cursor_pos()
  if not pos then return end
  for _, w in ipairs(hl.get_windows({ floating = true })) do
    local at, size = w.at, w.size
    if tostring(w.class):find(CLASS) and w.fullscreen == 0
        and pos.x >= at.x and pos.x < at.x + size.x
        and pos.y >= at.y and pos.y < at.y + size.y then
      M.window = "address:" .. tostring(w.address):gsub("^address:", "")
      M.grab_x, M.grab_y = pos.x - at.x, pos.y - at.y
      M.start_x, M.start_y = pos.x, pos.y
      M.moving = false
      M.ticks = 0
      M.timer:set_enabled(true)
      return
    end
  end
end

function M.release()
  if M.window then stop() end
end

function M.unload()
  stop()
  if M.press_bind then pcall(function() M.press_bind:remove() end) end
  if M.release_bind then pcall(function() M.release_bind:remove() end) end
  M.press_bind, M.release_bind = nil, nil
end

M.timer = hl.timer(function() pcall(tick) end, { timeout = 16, type = "repeat" })
M.timer:set_enabled(false)

-- Non consuming, so every click still goes to whatever is under the pointer.
if not rawget(_G, "fmvideo_drag_no_binds") then
  M.press_bind = hl.bind("mouse:272", function() pcall(M.press) end, { non_consuming = true })
  M.release_bind = hl.bind("mouse:272", function() pcall(M.release) end, { non_consuming = true, release = true })
end

fmvideo_drag = M
