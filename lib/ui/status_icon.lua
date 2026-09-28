--[[

Footer countdown indicator for Reading Ruler.

Draws a small clock-face emoji in the reader footer while auto scroll is
dwelling on the last line of a page, so the remaining wait is visible
without any popup notification.

The emoji advances through the twelve whole-hour clock faces as the
countdown runs down, giving a coarse "clock" at a glance:

    🕛  just started        🕕  about half left        🕚  nearly done

Only the 12 whole-hour faces are used (U+1F550 .. U+1F55B) because they
are by far the most widely available clock glyphs; the half-hour faces
are far less reliably present in device fonts.

The indicator is deliberately self-contained: it paints itself into the
footer area of the screen and never touches ReaderFooter's internals.

]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local logger = require("logger")

local Screen = Device.screen

-- Twelve whole-hour clock faces, U+1F550 .. U+1F55B.
local CLOCK_FACES = {
    "\u{1F55B}", -- 12 o'clock, right at the start of the wait
    "\u{1F550}",
    "\u{1F551}",
    "\u{1F552}",
    "\u{1F553}",
    "\u{1F554}",
    "\u{1F555}",
    "\u{1F556}",
    "\u{1F557}",
    "\u{1F558}",
    "\u{1F559}",
    "\u{1F55A}",
}

--- Pick the clock face for a fraction of the wait already elapsed.
--- `elapsed_fraction` 0 -> first face, 1 -> last face.
---@param elapsed_fraction number
---@return string
local function faceForFraction(elapsed_fraction)
    if elapsed_fraction < 0 then elapsed_fraction = 0 end
    if elapsed_fraction > 1 then elapsed_fraction = 1 end
    local idx = math.floor(elapsed_fraction * (#CLOCK_FACES - 1) + 0.5) + 1
    if idx < 1 then idx = 1 end
    if idx > #CLOCK_FACES then idx = #CLOCK_FACES end
    return CLOCK_FACES[idx]
end

---@class StatusIcon
local StatusIcon = Widget:extend{
    -- text to draw (single clock emoji)
    text = nil,
    -- face used for drawing
    face = nil,
    -- optional background fill; nil = transparent (only the glyph is drawn)
    background = nil,
    -- padding inside the drawn box
    padding = 2,
}

function StatusIcon:init()
    if not self.face then
        self.face = Font:getFace("infofont")
    end
    self:_layout()
end

--- (Re)measure the widget for the current text.
function StatusIcon:_layout()
    local text = self.text
    if not text or text == "" then
        self.dimen = Geom:new{ w = 0, h = 0 }
        return
    end
    if not self.face then
        -- Defensive: setText can be reached before init() in some widget
        -- construction orders; resolve the face lazily rather than crash.
        self.face = Font:getFace("infofont")
    end
    local w, h = self.face:getSize(text)
    self._text_size = { w = w, h = h }
    self.dimen = Geom:new{
        w = w + 2 * self.padding,
        h = h + 2 * self.padding,
    }
end

--- Set the glyph to display and re-measure.
---@param text string
function StatusIcon:setText(text)
    if self.text == text then
        return false
    end
    self.text = text
    self:_layout()
    return true
end

function StatusIcon:paintTo(bb, x, y)
    if not self.text or self.text == "" then
        return
    end
    local size = self.dimen
    if self.background then
        bb:paintRect(x, y, size.w, size.h, self.background)
    end
    local text_w = self._text_size and self._text_size.w or 0
    local text_h = self._text_size and self._text_size.h or 0
    -- Vertically centre the glyph inside the padding box
    local tx = x + math.floor((size.w - text_w) / 2)
    local ty = y + math.floor((size.h - text_h) / 2)
    self.face:displayUtf8Text(bb, tx, ty, self.text, text_w)
end

-- ---------------------------------------------------------------------------
-- Controller: owns the widget and drives its position/appearance while the
-- end-of-page countdown is running.
-- ---------------------------------------------------------------------------

---@class DwellIndicator
local DwellIndicator = {
    widget = nil,
    -- set by the caller
    getRemaining = nil,   -- function() -> number? (nil = no countdown)
    getTotal = nil,       -- function() -> number?
}

function DwellIndicator:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.widget = StatusIcon:new{}
    return o
end

--- Whether the indicator should currently be on screen.
---@return boolean
function DwellIndicator:isActive()
    return self.getRemaining ~= nil and self:getRemaining() ~= nil
end

--- Compute where to paint: right-aligned inside the footer strip.
---@param icon_w number
---@param icon_h number
---@return number x, number y, boolean ok
function DwellIndicator:_resolvePosition(icon_w, icon_h)
    local view = self.ui and self.ui.view
    local footer = view and view.footer
    if not view or not view.footer_visible or not footer then
        return 0, 0, false
    end

    local ok, footer_h = pcall(function() return footer:getHeight() end)
    if not ok or type(footer_h) ~= "number" or footer_h <= 0 then
        return 0, 0, false
    end

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Keep the icon inside the footer strip
    local max_icon_h = footer_h - 2
    if icon_h > max_icon_h and max_icon_h > 0 then
        -- Footer too short for the glyph: skip rather than overdraw content
        return 0, 0, false
    end

    local right_margin = Screen:scaleBySize(4)
    local x = screen_w - icon_w - right_margin
    if x < 0 then
        return 0, 0, false
    end
    local y = screen_h - footer_h + math.floor((footer_h - icon_h) / 2)
    return x, y, true
end

--- Repaint the indicator. Call whenever the countdown ticks or the reading
--- view changes the footer.
function DwellIndicator:refresh()
    local active = self:isActive()
    if not active then
        if self._painted then
            self._painted = false
            self:_invalidate()
        end
        return
    end

    local remaining = self:getRemaining()
    local total = remaining
    if self.getTotal then
        total = self:getTotal() or remaining
    end
    if total <= 0 then total = remaining end

    local elapsed_fraction = 0
    if total and total > 0 then
        elapsed_fraction = (total - remaining) / total
    end
    local face = faceForFraction(elapsed_fraction)
    self.widget:setText(face)

    local icon_w = self.widget.dimen.w
    local icon_h = self.widget.dimen.h
    local x, y, ok = self:_resolvePosition(icon_w, icon_h)
    if not ok then
        -- No usable footer: nothing to draw. Leave no stale pixels behind.
        if self._painted then
            self._painted = false
            self:_invalidate()
        end
        return
    end

    self._last_box = Geom:new{ x = x, y = y, w = icon_w, h = icon_h }
    self._painted = true
    UIManager:setDirty(self.ui.dialog or "all", function()
        return "ui", self._last_box
    end)
end

--- Ask UIManager to repaint the strip the icon occupies (or used to).
function DwellIndicator:_invalidate()
    local box = self._last_box
    if not box then
        return
    end
    UIManager:setDirty(self.ui.dialog or "all", function()
        return "ui", box
    end)
end

--- Drop the indicator (e.g. plugin disabled, document closed).
function DwellIndicator:clear()
    if self._painted then
        self._painted = false
        self:_invalidate()
    end
end

--- Paint hook, called by RulerUI's own paintTo chain.
function DwellIndicator:paintTo(bb, x, y)
    if not self._painted or not self._last_box then
        return
    end
    local box = self._last_box
    self.widget:paintTo(bb, box.x, box.y)
end

return {
    DwellIndicator = DwellIndicator,
    StatusIcon = StatusIcon,
    faceForFraction = faceForFraction,
    CLOCK_FACES = CLOCK_FACES,
}
