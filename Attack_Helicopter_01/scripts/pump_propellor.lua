local ENGINE = peripheral.wrap("front")
local FLUID_TANK = peripheral.wrap("back")
local TRANSMISSION = peripheral.wrap("top")

local OUT_THROTTLE = "back"
local INP_INCREASE = "left"
local INP_DECREASE = "right"
local INP_ENGINE = "bottom"
local DEBOUNCE = 0.25

rs.setOutput(OUT_THROTTLE, false)
rs.setOutput(peripheral.getName(ENGINE), true)
TRANSMISSION.setTransmissionMode("direct")
TRANSMISSION.setShiftLevel(3)

local enable_engine = false

--- @NOTE: does not handle button spamming well due to debounce being a sleep.
--- @TODO: change it back to os.sleep(0.05) with the last_changed idea
local function propellor()
    while true do
        os.pullEvent("redstone")
        if rs.getInput(INP_ENGINE) then
            enable_engine = not enable_engine
            rs.setOutput(peripheral.getName(ENGINE), not enable_engine)
        end
        if rs.getInput(INP_INCREASE) or rs.getInput(INP_DECREASE) then
            repeat
                local ii, id = rs.getInput(INP_INCREASE), rs.getInput(INP_DECREASE)
                local change = (ii and 1 or 0) - (id and 1 or 0)
                if change ~= 0 then
                    local output = rs.getAnalogOutput(OUT_THROTTLE) + change
                    if 0 > output or output > 15 then break end
                    rs.setAnalogOutput(OUT_THROTTLE, output)
                end
                os.sleep(DEBOUNCE)
            until not (ii or id)
        end
    end
end

local function fuel()
    while true do
        if enable_engine then
            ENGINE.pullFluid(peripheral.getName(FLUID_TANK))
        else
            FLUID_TANK.pullFluid(peripheral.getName(ENGINE))
        end
    end
end

parallel.waitForAny(propellor, fuel)
