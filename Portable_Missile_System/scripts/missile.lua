--- @alias Vector table
--- @alias Quaternion table

local function clamp(val, min, max) return math.max(math.min(val, max), min) end
local function inject_nb(fn) return function(...) coroutine.resume(coroutine.create(fn), ...) end end
local function time() return os.epoch("utc") * 0.001 end
local function upv(v) return v.x, v.y, v.z end

local function apn_zem()
    --- See: https://youtu.be/dFpCL6jjIJg for APN ZEM derivation.
    --- See: https://youtu.be/sbcPfnm30vA for t_go derivation.
    --- @param r_p Vector Pursuer position
    --- @param v_p Vector Pursuer velocity
    --- @param r_t Vector Target position
    --- @param v_t Vector Target velocity
    --- @param a_t Vector Target acceleration
    --- @return Vector a_p Acceleration command
    return function(r_p, v_p, r_t, v_t, a_t)
        local z1 = r_t - r_p               -- relative position
        local z2 = v_t - v_p               -- relative velocity
        local z3 = a_t                     -- target acceleration

        local R = z1:length()              -- range
        local Vc = -z2:dot(z1:normalize()) -- closing velocity
        -- Vc can be negative; added minimum to prevent nan/negative t_go
        local t_go = R / math.max(Vc, 1e-3)

        -- zem is implicitly perpendicular to LOS because z1,2,3 are.
        local zem_pl = z1 + z2 * t_go + z3 * t_go ^ 2
        return zem_pl * (3 / t_go)
    end
end

local function pi(kp, ki, i_max)
    local prev_t, i = os.clock(), 0
    return function(err)
        local t = os.clock()
        local dt = t - prev_t
        -- ideally this should never happen, maybe due to floating point bs with os.clock()
        if dt <= 1e-3 then return kp * err + ki * i end

        i = clamp(i + err * dt, -i_max, i_max)

        prev_t = t
        return kp * err + ki * i
    end
end

--- Direction of acceleration
--- @param a Vector Desired acceleration command
--- @return number desired_yaw
--- @return number desired_pitch
local function cmd_to_angles(a)
    return
        -math.atan2(a.x, a.z),
        math.atan2(a.y, math.sqrt(a.x ^ 2 + a.z ^ 2))
end

--- Account for roll
--- @param desired_yaw number Inertial frame
--- @param desired_pitch number Inertial frame
--- @param q Quaternion Orientation of the body
--- @return number err_yaw Body frame
--- @return number err_pitch Body frame
local function angles_to_errors(desired_yaw, desired_pitch, q)
    local des_q = quaternion.fromEuler(desired_pitch, desired_yaw, 0)
    -- Error in body frame!
    local err_q = q:conjugate():mul(des_q)
    local err_pitch, err_yaw, _ = err_q:toEuler()
    return -err_yaw, -err_pitch
end

local MODEM = peripheral.find("modem")
local MY_ID = sublevel.getUniqueId() --- @type string
local LAUNCHER_ID = "portable_launcher"
local INC_CHANNEL, OUT_CHANNEL = 1234, 1234

local FLUID_TANK = peripheral.find("createbigcannons:fluid_shell")
local THRUSTER = peripheral.find("liquid_vector_thruster")
THRUSTER.setVector = inject_nb(THRUSTER.setVector)
THRUSTER.setThrustNormalized = inject_nb(THRUSTER.setThrustNormalized)

local LAUNCH_DURATION = 0.15
local ROCKET_THRUST = 1.0
local CTRL_NAV = apn_zem()
--- @TODO: Don't bother tuning until THRUSTER.setVector(x, y) isn't quantised to 1/15ths
--- under the hood anymore. Who on earth thought that was a good idea 😭
local CTRL_YAW = pi(0.3, 0.1, 0.25)
local CTRL_PITCH = pi(0.3, 0.1, 0.25)

local GRAVITY_VEC = aero.getGravity()

local prev_tgt, tgt
local has_launched

local function receiver()
    MODEM.open(INC_CHANNEL)
    while true do
        local _, _, channel, _, packet, _
        repeat
            _, _, channel, _, packet, _ = os.pullEvent("modem_message")
        until channel == INC_CHANNEL

        local p, v = packet["position"], packet["velocity"]
        if
            packet["id"] == LAUNCHER_ID and
            packet["recipient"] == MY_ID and
            type(packet["time"]) == "number" and
            type(p) == "table" and
            type(v) == "table" and
            type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number" and
            type(v.x) == "number" and type(v.y) == "number" and type(v.z) == "number"
        then
            if tgt then prev_tgt = tgt end -- not first time
            if not tgt then tgt = {} end   -- first time

            tgt.pos = vector.new(upv(p))
            tgt.vel = vector.new(upv(v))
            tgt.time = packet["time"]

            if not has_launched then
                os.queueEvent("launch"); has_launched = true
            end
        end
    end
end

local function main()
    local fuel_amount, tanks = 0, THRUSTER.tanks()
    if #tanks > 0 then fuel_amount = tanks[1].amount end
    print("Fuel: " .. fuel_amount .. "mB")

    -- Register
    MODEM.transmit(OUT_CHANNEL, INC_CHANNEL, {
        ["id"] = MY_ID,
        ["recipient"] = LAUNCHER_ID,
        ["position"] = sublevel.getLogicalPose().position,
    })
    print("Pairing message sent.")

    -- Idle
    THRUSTER.setThrustNormalized(0)
    THRUSTER.setVector(0, 0)
    os.pullEvent("launch") -- wait (can be a long time)

    -- Launch
    THRUSTER.setThrustNormalized(ROCKET_THRUST)
    os.sleep(LAUNCH_DURATION)

    -- Homing
    while true do
        -- This yields for 0.05s
        local pose, vel
        parallel.waitForAll(
            function() pose = sublevel.getLogicalPose() end,
            function() vel = sublevel.getLinearVelocity() end
        )
        local pos, q = pose.position, pose.orientation

        local est_tgt_acc = vector.new(0, 0, 0)
        if prev_tgt then
            -- Only in relation to previous sample we've received.
            -- Assume acceleration stays constant (big if), unlike pos and vel.
            local _dt = tgt.time - prev_tgt.time
            est_tgt_acc = (tgt.vel - prev_tgt.vel) / _dt
        end

        -- Account for time lag between command sending and us receiving messages
        local dt = time() - tgt.time
        local est_tgt_vel = tgt.vel + est_tgt_acc * dt
        local est_tgt_pos = tgt.pos + est_tgt_vel * dt

        local acc_cmd_inertial = CTRL_NAV(pos, vel, est_tgt_pos, est_tgt_vel, est_tgt_acc)
        local des_yaw, des_pitch = cmd_to_angles(acc_cmd_inertial - GRAVITY_VEC)
        local err_yaw, err_pitch = angles_to_errors(des_yaw, des_pitch, q)

        local x = CTRL_YAW(err_yaw)
        local y = CTRL_PITCH(err_pitch)
        THRUSTER.setVector(x, y)
    end
end

if arg[1] then
    local invalid
    if arg[1] ~= "fuel" then invalid = true end
    if arg[2] and tonumber(arg[2]) == nil then invalid = true end
    if not invalid then
        local n = tonumber(arg[2])
        if not n or n >= 0 then
            THRUSTER.pullFluid(peripheral.getName(FLUID_TANK), n)
        else
            THRUSTER.pushFluid(peripheral.getName(FLUID_TANK), -n)
        end
    else
        print("Run normally:")
        print("> missile")
        print("Manage fuel with:")
        print("> missile fuel <optional: number, negative pulls out>")
    end
else
    if FLUID_TANK then
        parallel.waitForAny(main, receiver, function()
            while true do THRUSTER.pullFluid(peripheral.getName(FLUID_TANK)) end
        end)
    else
        parallel.waitForAny(main, receiver)
    end
end
