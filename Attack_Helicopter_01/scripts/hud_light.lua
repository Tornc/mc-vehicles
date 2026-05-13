-- [[ PERIPHERAL SETUP ]]

local MONITOR = peripheral.find("monitor")
MONITOR.setPaletteColour(colours.white, colours.packRGB(0, 1, 0)) -- Full green
MONITOR.setPaletteColour(colours.black, colours.packRGB(0, 0, 0)) -- Full black
MONITOR.setTextScale(0.5)

-- [[ ALIASES ]]

local abs, floor = math.abs, math.floor
local min, max = math.min, math.max
local deg = math.deg
local cos, sin, asin = math.cos, math.sin, math.asin

-- [[ UTILITY FUNCTIONS ]] --

local function clamp(val, min_val, max_val) return min(max(val, min_val), max_val) end
local function round(n) return floor(n + 0.5) end
local function polar_offset(x, y, l, a) return round(x + l * cos(a)), round(y + l * sin(a)) end
local function write_at(self, x, y, str)
    self.setCursorPos(x, y); self.write(str)
end

-- [[ DISPLAY LIBARY FUNCTIONS (simplified version) ]]

--- @param w integer
--- @param h integer
--- @param fg string
--- @param bg string
--- @return Canvas
local function canvas(w, h, fg, bg)
    --- @class Canvas
    local self = {}
    self.w = w
    self.h = h
    self.fg = fg
    self.bg = bg

    self.frame = 0
    self.mark = {}

    function self.clear() self.frame = self.frame + 1 end

    function self.put(x, y)
        if x < 1 or x > self.w or y < 1 or y > self.h then return end
        self.mark[(y - 1) * self.w + x] = self.frame
    end

    function self.is_set(i) return self.mark[i] == self.frame end

    function self.draw_line(x1, y1, x2, y2)
        local dx = math.abs(x2 - x1)
        local sx = x1 < x2 and 1 or -1
        local dy = -math.abs(y2 - y1)
        local sy = y1 < y2 and 1 or -1
        local err = dx + dy

        local put = self.put --- @type function
        while true do
            put(x1, y1)
            local err2 = 2 * err
            if err2 >= dy then
                if x1 == x2 then break end
                err = err + dy
                x1 = x1 + sx
            end
            if err2 <= dx then
                if y1 == y2 then break end
                err = err + dx
                y1 = y1 + sy
            end
        end
    end

    return self
end

local function shrink_bitmap_2x3(b1, b2, b3, b4, b5, b6)
    local count =
        (b1 and 1 or 0) +
        (b2 and 1 or 0) +
        (b3 and 1 or 0) +
        (b4 and 1 or 0) +
        (b5 and 1 or 0) +
        (b6 and 1 or 0)

    if count == 0 then return " ", false end
    if count == 6 then return " ", true end

    local swap = count >= 3
    if b6 ~= swap then swap = not swap end -- Special case for the last bit

    local ch = 128
    if b1 ~= swap then ch = ch + 1 end
    if b2 ~= swap then ch = ch + 2 end
    if b3 ~= swap then ch = ch + 4 end
    if b4 ~= swap then ch = ch + 8 end
    if b5 ~= swap then ch = ch + 16 end
    return string.char(ch), swap
end

--- @param cv Canvas
--- @param x integer?
--- @param y integer?
local function blit_canvas(win, cv, x, y)
    assert(cv.w % 2 == 0, cv.w .. " not multiple of 2.")
    assert(cv.h % 3 == 0, cv.h .. " not multiple of 3.")

    -- Location of canvas, from top-left corner.
    x = x and x or 1
    y = y and y or 1

    -- Actual width, height
    local aw, ah = cv.w / 2, cv.h / 3
    local cvw, cvfg, cvbg = cv.w, cv.fg, cv.bg

    local isset = cv.is_set --- @type function
    local concat = table.concat
    for _y = 1, ah do
        local chrs = {}
        local tcs = {}
        local bgcs = {}

        for _x = 1, aw do
            local i = ((_y - 1) * 3 * cvw) + ((_x - 1) * 2) + 1

            local b1 = isset(i)                 -- top-left
            local b2 = isset(i + 1)             -- top-right
            local b3 = isset(i + cvw)           -- middle-left
            local b4 = isset(i + cvw + 1)       -- middle-right
            local b5 = isset(i + (2 * cvw))     -- bottom-left
            local b6 = isset(i + (2 * cvw) + 1) -- bottom-right

            local ch, sw = shrink_bitmap_2x3(b1, b2, b3, b4, b5, b6)
            chrs[_x] = ch
            tcs[_x] = sw and cvbg or cvfg
            bgcs[_x] = sw and cvfg or cvbg
        end
        -- Do NOT blit separately for every pixel; it will cause massive stutters!
        win.setCursorPos(x, y + _y - 1)
        win.blit(concat(chrs), concat(tcs), concat(bgcs))
    end
end

-- [[ DRAW FUNCTIONS ]] --

local function draw_vertical_velocity(window, x, y, velocity)
    local strip_length = 7
    for i = 0, strip_length - 1 do
        window:write_at(x, i + y, i % 2 == 0 and "-" or "\183")
    end

    local speed = velocity:length()
    if speed < 0.1 then return end
    local fpa = deg(asin(velocity.y / speed))

    fpa = clamp(fpa, -30, 30)
    local normalised = (30 - fpa) / 60
    local fpa_indicator_y = y + round((strip_length - 1) * normalised)
    window:write_at(x + 1, fpa_indicator_y, "\27")
end

local function draw_pitch(window, x, y, pitch)
    local strip_length = 7
    local hl = floor(strip_length / 2)
    local p = round(deg(pitch) / 10)
    for i = 9, -9, -2 do
        local y_off = i - p -- (i - p + 9) % 18 - 9
        if abs(y_off) <= hl then
            window:write_at(x - (i < 0 and 1 or 0), y + hl - y_off, i)
        end
    end
end

--- @param _canvas Canvas
local function draw_roll(window, _canvas, x, y, roll)
    local cx, cy = floor(_canvas.w / 2) + 1, floor(_canvas.h / 2) + 1
    local wing_length, tail_length, gap = 7, 3, 3

    _canvas.clear()

    -- Left, right, up, down angular offset
    local l_roll = roll + math.pi
    local r_roll = roll + 0
    local d_roll = roll + math.pi / 2
    local u_roll = roll + -math.pi / 2

    -- left wing
    local lw_x1, lw_y1 = polar_offset(cx, cy, gap + 1, l_roll)
    local lw_x2, lw_y2 = polar_offset(lw_x1, lw_y1, wing_length - 1, l_roll)
    _canvas.draw_line(lw_x1, lw_y1, lw_x2, lw_y2)
    -- left wing joint
    local lw_x3, lw_y3 = polar_offset(cx, cy, gap + 1 + 1, l_roll)
    local lw_x4, lw_y4 = polar_offset(lw_x3, lw_y3, 1, d_roll)
    _canvas.draw_line(lw_x3, lw_y3, lw_x4, lw_y4)

    -- right wing
    local rw_x1, rw_y1 = polar_offset(cx, cy, gap + 1, r_roll)
    local rw_x2, rw_y2 = polar_offset(rw_x1, rw_y1, wing_length - 1, r_roll)
    _canvas.draw_line(rw_x1, rw_y1, rw_x2, rw_y2)
    -- right wing joint
    local rw_x3, rw_y3 = polar_offset(cx, cy, gap + 1 + 1, r_roll)
    local rw_x4, rw_y4 = polar_offset(rw_x3, rw_y3, 1, d_roll)
    _canvas.draw_line(rw_x3, rw_y3, rw_x4, rw_y4)

    -- tail
    local t_x1, t_y1 = polar_offset(cx, cy, gap, u_roll)
    local t_x2, t_y2 = polar_offset(t_x1, t_y1, tail_length, u_roll)
    _canvas.draw_line(t_x1, t_y1, t_x2, t_y2)

    blit_canvas(window, _canvas, x, y)
end

local function draw_aoa(window, x, y, velocity, pitch)
    local speed = velocity:length()
    local aoa
    if speed < 0.1 then
        aoa = round(deg(pitch))
    else
        local fpa = asin(velocity.y / speed)
        aoa = round(deg(pitch - fpa))
        aoa = (aoa + 90) % 180 - 90
    end
    local smb = aoa > 0 and "\24" or (aoa < 0 and "\25" or "\18")
    local str_aoa = smb .. string.format("%2d", abs(aoa))
    window:write_at(x, y, str_aoa)
end

-- [[ HUD MAIN LOOP ]] --

local function hud()
    local HUD_WIDTH, HUD_HEIGHT = 15, 10
    local HHWF = floor(HUD_WIDTH / 2)
    local CV_ROLL = canvas(
        (HUD_WIDTH - 4) * 2, (HUD_HEIGHT - 3) * 3,
        colours.toBlit(colours.white),
        colours.toBlit(colours.black)
    )
    local WIN = window.create(MONITOR, 1, 1, HUD_WIDTH, HUD_HEIGHT)
    WIN.write_at = write_at -- I love monkey patching

    while true do
        local pose = sublevel.getLogicalPose()
        local pos = pose.position
        local vel = sublevel.getLinearVelocity()
        local pitch, yaw, roll = pose.orientation:toEuler() -- radians

        WIN.setVisible(false)
        WIN.clear()
        -- Top
        WIN:write_at(1, 1, tostring(round(vel:length())))                    -- Speed
        WIN:write_at(HHWF, 2, string.format("%03d", (deg(yaw) + 360) % 360)) -- Heading
        local str_p_y = tostring(round(pos.y))
        WIN:write_at(HUD_WIDTH - (#str_p_y - 1), 1, str_p_y)                 -- Altitude
        -- Middle
        draw_vertical_velocity(WIN, 1, 3, vel)
        draw_roll(WIN, CV_ROLL, 3, 3, roll)
        draw_pitch(WIN, HUD_WIDTH, 3, -pitch)
        -- Bottom
        draw_aoa(WIN, HHWF, HUD_HEIGHT, vel, -pitch)

        WIN.setVisible(true)
        os.sleep(0.05)
    end
end

-- [[ LIGHT FUNCTIONALITY MAIN LOOP ]]

local function light()
    local LIGHT = "back"
    local INPUT = "bottom"
    rs.setOutput(LIGHT, false)
    while true do
        os.pullEvent("redstone")
        if rs.getInput(INPUT) then
            rs.setOutput(LIGHT, not rs.getOutput(LIGHT))
        end
    end
end

parallel.waitForAny(hud, light)
