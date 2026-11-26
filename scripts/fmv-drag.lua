-- Lets the FM.video window be moved with a plain drag, and resized by
-- dragging a corner, no Super key needed.
--
-- The window is a web page with no title bar, so there is nothing to grab.
-- This watches the left mouse button. When it goes down over the FM.video
-- window and the pointer then moves, the window follows the pointer until
-- the button comes up. A drag that starts in a corner changes the size
-- instead, keeping the window's shape and the opposite corner still, down
-- to 100 pixels high and up to as far as the pointer goes. Clicks still
-- reach the page, and no other window is touched. Loaded by scripts/fmv-window with `hyprctl eval`, and gone again
-- on the next Hyprland reload.

local CLASS = "^[%a-]+%-fm%.video__mini%-"   -- a Lua pattern
local THRESHOLD = 6     -- pixels the pointer must move before the window does
local MAX_TICKS = 1800  -- give up after 30 seconds, in case a release is missed
local MIN_HEIGHT = 100  -- the smallest the window can be dragged to

-- IMPORTANT: this file never removes a key bind. Calling remove() on a bind
-- crashes Hyprland 0.56.2 (it took a whole session down in testing). So the
-- two binds are made once and left alone. They look this module up by name
-- each time, so loading the file again swaps in new code without touching
-- them, and "unloading" only switches the module off.

local old = rawget(_G, "fmvideo_drag")
if old and old.press_bind then
  -- An older copy that kept its binds. Leave it running, and make sure
  -- nothing can ask it to remove them.
  old.unload = function() end
  return
end
if old and old.halt then pcall(old.halt) end

local M = { window = nil, moving = false, ticks = 0, off = false, bound = old and old.bound or false }

local function stop()
  if M.timer then M.timer:set_enabled(false) end
  if M.window and M.moving then
    pcall(hl.dispatch, hl.dsp.window.set_prop({ window = M.window, prop = "no_anim", value = "unset" }))
  end
  M.window = nil
  M.moving = false
  M.corner = nil
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
  if M.corner then
    -- The pointer's travel away from the fixed corner, as extra width.
    -- Whichever of the two directions asks for more wins.
    local r = M.rect
    local dx = M.corner.left and (M.start_x - pos.x) or (pos.x - M.start_x)
    local dy = M.corner.top and (M.start_y - pos.y) or (pos.y - M.start_y)
    local aspect = r.w / r.h
    local w = math.max(r.w + dx, (r.h + dy) * aspect, MIN_HEIGHT * aspect)
    w = math.floor(w + 0.5)
    local h = math.floor(w / aspect + 0.5)
    hl.dispatch(hl.dsp.window.resize({ window = M.window, x = w, y = h }))
    hl.dispatch(hl.dsp.window.move({
      window = M.window,
      x = M.corner.left and (r.x + r.w - w) or r.x,
      y = M.corner.top and (r.y + r.h - h) or r.y,
    }))
    return
  end
  hl.dispatch(hl.dsp.window.move({
    window = M.window,
    x = math.floor(pos.x - M.grab_x),
    y = math.floor(pos.y - M.grab_y),
  }))
end

function M.press()
  local pos = hl.get_cursor_pos()
  if not pos or M.off then return end
  for _, w in ipairs(hl.get_windows({ floating = true })) do
    local at, size = w.at, w.size
    if tostring(w.class):find(CLASS) and w.fullscreen == 0
        and pos.x >= at.x and pos.x < at.x + size.x
        and pos.y >= at.y and pos.y < at.y + size.y then
      M.window = "address:" .. tostring(w.address):gsub("^address:", "")
      M.grab_x, M.grab_y = pos.x - at.x, pos.y - at.y
      M.start_x, M.start_y = pos.x, pos.y
      -- A press in a corner resizes. The corner is a quarter of the
      -- shorter side, between 16 and 36 pixels.
      local zone = math.max(16, math.min(36, math.min(size.x, size.y) / 4))
      local left, right = pos.x < at.x + zone, pos.x >= at.x + size.x - zone
      local top, bottom = pos.y < at.y + zone, pos.y >= at.y + size.y - zone
      M.corner = (left or right) and (top or bottom) and { left = left, top = top } or nil
      M.rect = { x = at.x, y = at.y, w = size.x, h = size.y }
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

-- Stop any drag in progress and hold the timer still.
function M.halt()
  stop()
end

-- Switch dragging off. The binds stay (see the note at the top).
function M.unload()
  stop()
  M.off = true
end

M.timer = hl.timer(function() pcall(tick) end, { timeout = 16, type = "repeat" })
M.timer:set_enabled(false)

-- Non consuming, so every click still goes to whatever is under the pointer.
if not M.bound and not rawget(_G, "fmvideo_drag_no_binds") then
  hl.bind("mouse:272", function()
    local drag = rawget(_G, "fmvideo_drag")
    if drag then pcall(drag.press) end
  end, { non_consuming = true })
  hl.bind("mouse:272", function()
    local drag = rawget(_G, "fmvideo_drag")
    if drag then pcall(drag.release) end
  end, { non_consuming = true, release = true })
  M.bound = true
end

fmvideo_drag = M
