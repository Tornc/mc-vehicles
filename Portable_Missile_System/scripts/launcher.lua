-- [[ PERIPHERALS ]]

local MODEM = peripheral.find("modem")
local SPEAKER = peripheral.find("speaker")
local RADAR = peripheral.find("create_radar:plane_radar") or { getRange = function() return 250 end }
local SIDE_LOCK_ON = "front"

--[[ CONSTANTS ]]

local MY_ID = "portable_launcher"
local INC_CHANNEL, OUT_CHANNEL = 1234, 1234

local MAX_PAIR_RANGE = 10              -- blocks
local MISSILE_FUEL_TIME = 50           -- seconds (min: 1000mB / 20mB, max: 3000mB)
local TARGET_TYPES = { "Sable:ship", } -- can add more
local DEFAULT_ANGLE_LEEWAY = 15        -- degrees
local MAX_RANGE = RADAR.getRange()     -- blocks

--- @TODO: auto-install when files don't exist.
local AUDIO_PAIR_READY = shell.resolve("./pair_ready.dfpwm")
local AUDIO_PAIR_SUCCESS = shell.resolve("./pair_success.dfpwm")

-- [[ STATE / CONFIG ]]

local angle_leeway = DEFAULT_ANGLE_LEEWAY -- degrees
local missile_uuid, armed, static_position

-- [[ FUNCTIONS ]]

local function time() return os.epoch("utc") * 0.001 end
local function upv(v) return v.x, v.y, v.z end
local function contains(t, v) for _, _v in pairs(t) do if _v == v then return true end end end
-- Janky hack to force the GUI to update. Having GUI pullEvent
-- with no filter would rob await_pairing()'s "modem_message" events.
-- Uses dummy parameters to avoid errors.
local function force_gui_update() os.queueEvent("key", -1, false) end
local function inject_nb(fn) return function(...) coroutine.resume(coroutine.create(fn), ...) end end
--- @NOTE: this sounds better in-game but dogshit in CraftOS!
local function decode(input)
    local output = {}
    for i = 1, #input do
        local b = input:byte(i)
        for j = 0, 7 do
            table.insert(output,
                bit32.rshift(b, j) % 2 == 1 and 127 or -128
            )
        end
    end
    return output
end
local function play_audio(path)
    for chunk in io.lines(path, 16 * 1024) do
        local b = decode(chunk)
        while not SPEAKER.playAudio(b) do
            os.pullEvent("speaker_audio_empty")
        end
    end
end

--- @return string
local function await_pairing()
    MODEM.open(INC_CHANNEL)
    while true do
        local _, _, channel, _, packet, _
        repeat
            _, _, channel, _, packet, _ = os.pullEvent("modem_message")
        until channel == INC_CHANNEL
        local p = packet["position"]
        if
            type(packet["id"]) == "string" and
            packet["recipient"] == MY_ID and
            type(p) == "table" and
            type(p.x) == "number" and
            type(p.y) == "number" and
            type(p.z) == "number"
        then
            local pos = sublevel.getLogicalPose().position
            local dist = (vector.new(upv(p)) - pos):length()
            if dist <= MAX_PAIR_RANGE then
                return packet["id"]
            end
        end
    end
end

local function get_info()
    -- These both yield for 1 tick so I'm doing this weird thing.
    local pose, tracks
    parallel.waitForAll(
        function() pose = sublevel.getLogicalPose() end,
        function() tracks = RADAR.getTracks() end
    )
    -- use own time because getTracks()'s scannedTime is relative to sth not useful
    local t = time()
    -- Ignore our missile and any tracks not in TARGET_TYPES
    for i = #tracks, 1, -1 do
        tracks[i].time = t
        if
            not contains(TARGET_TYPES, tracks[i].entityType) or
            tracks[i].id == missile_uuid
        then
            table.remove(tracks, i)
        end
    end
    return pose, tracks
end

--- @return table?
local function select_target(pos, q, tracks)
    local forward = q:mul(vector.new(0, 0, 1))
    local cos_a = math.cos(math.rad(angle_leeway))
    local d_max_sq = MAX_RANGE ^ 2

    local best_uuid, best_d_perp_sq = nil, math.huge

    for _, t in ipairs(tracks) do
        local d = vector.new(upv(t.position)) - pos
        local d_sq = d:dot(d)
        if d_sq >= d_max_sq then goto continue end

        local d_fwd = d:dot(forward)
        if d_fwd < 1e-6 then goto continue end
        if d_fwd ^ 2 < cos_a ^ 2 * d_sq then goto continue end

        local d_perp_sq = d_sq - d_fwd ^ 2
        if d_perp_sq < best_d_perp_sq then
            best_uuid, best_d_perp_sq = t.id, d_perp_sq
        end

        ::continue::
    end

    return best_uuid
end

local function find_lock(uuid, tracks)
    for _, t in ipairs(tracks) do
        if t.id == uuid then return t end
    end
end

local function main()
    play_audio(AUDIO_PAIR_READY)
    missile_uuid = await_pairing()
    play_audio(AUDIO_PAIR_SUCCESS)
    force_gui_update()

    local next_note_time = 0

    --- @TODO: implement static_position mode (no valid position = normal mode)
    --- also, make it possible to switch modes while still in search phase
    --- after transmitting info once, we can immediately terminate program.

    -- search phase
    local target_uuid
    while true do
        -- We can still disarm while in search phase.
        if not armed then os.pullEvent("arm") end

        local pose, tracks = get_info() -- yields
        local t = os.clock()

        target_uuid = select_target(pose.position, pose.orientation, tracks)
        if target_uuid then
            if rs.getInput(SIDE_LOCK_ON) then break end

            if next_note_time < t then
                SPEAKER.playNote("pling", 1, 24)
                next_note_time = t + 0.1
            end
        end
    end

    -- missile guidance phase
    local launch_time = os.clock()
    while true do
        local _, tracks = get_info() -- yields
        local t = os.clock()

        local target = find_lock(target_uuid, tracks)
        if target then
            MODEM.transmit(OUT_CHANNEL, INC_CHANNEL, {
                ["id"] = MY_ID,
                ["recipient"] = missile_uuid,
                ["position"] = target.position, --- @diagnostic disable-line: need-check-nil
                ["velocity"] = target.velocity, --- @diagnostic disable-line: need-check-nil
                ["time"] = target.time,         --- @diagnostic disable-line: need-check-nil
            })

            if next_note_time < t then
                SPEAKER.playNote("bit", 1, 16)
                next_note_time = t + 0.75
            end
        end

        if t - launch_time > MISSILE_FUEL_TIME then break end
    end
end

local function ui()
    local tw, th = term.getSize()
    local line = ("-"):rep(tw)
    local function printf(str, ...) print(string.format(str, ...)) end

    -- I hate this.
    local KEY_MAP = {
        ["one"] = 1,
        ["two"] = 2,
        ["three"] = 3,
        ["four"] = 4,
        ["five"] = 5,
        ["six"] = 6,
        ["seven"] = 7,
        ["eight"] = 8,
        ["nine"] = 9,
        ["zero"] = 0,
    }
    -- This system has a hard limit of 10 items.
    local menu = {
        { "Toggle arm/disarm", function()
            armed = not armed
            if armed then os.queueEvent("arm") end
        end },
        { "Set aim leeway angle", function()
            term.setCursorPos(1, th - 1)
            print("Leeway angle: [0, 90]")
            write("> ")

            term.setCursorBlink(true)
            os.pullEvent("key") -- dont want to bleed into read

            local n = tonumber(read())
            if n and 0 <= n and n <= 90 then angle_leeway = n end
        end },
        { "Fire position", function()
            term.setCursorPos(1, th - 1)
            print("Position: (X Y Z. Nothing to clear.)")
            write("> ")

            term.setCursorBlink(true)
            os.pullEvent("key") -- dont want to bleed into read

            local i = read()
            local xyz = {}
            for v in i:gmatch("%S+") do
                table.insert(xyz, tonumber(v))
            end
            if #xyz ~= 3 then return end
            static_position = vector.new(table.unpack(xyz))
        end },
    }

    force_gui_update()
    while true do
        local _, key, _ = os.pullEvent("key")

        local k = KEY_MAP[keys.getName(key)]
        if menu[k] and menu[k][2] then menu[k][2]() end

        term.clear()
        term.setCursorPos(1, 1)

        print(line)
        printf("Paired:             %s", missile_uuid and "YES" or "NO")
        printf("Radar range:        %d", MAX_RANGE)
        printf("Armed:              %s", armed and "YES" or "NO")
        printf("Aim leeway angle:   %d\xb0", angle_leeway)
        printf("Fire position:      %s",
            static_position and string.format("%d,%d,%d", upv(static_position)) or "n/a"
        )
        print(line)
        for i, v in ipairs(menu) do
            print(i .. ". " .. v[1])
        end
        print(line)
    end
end

SPEAKER.playNote = inject_nb(SPEAKER.playNote)
play_audio = inject_nb(play_audio)

parallel.waitForAny(main, ui)
