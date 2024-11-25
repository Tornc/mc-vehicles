-- Inputs
local REVERSE = "bottom"
local FORWARD = "top"
-- Output
local SIDES = peripheral.getNames()
local COOLDOWN = 4 -- ticks

local ENGINE_SIDE
for _, side in pairs(SIDES) do
    local side_type = peripheral.getType(side)
    if side_type == "CDG_DieselEngine" then
        ENGINE_SIDE = side
        break
    end
end
-- Peripherals
local ENGINE_PERIPHERAL = peripheral.wrap(ENGINE_SIDE)
-- State Variables
local current_time = 0
local last_changed_direction = 0
local going_forward, reversing
while true do
    current_time = math.floor(os.epoch("utc") * 0.02 + 0.5)
    going_forward, reversing = rs.getInput(FORWARD), rs.getInput(REVERSE)
    rs.setOutput(ENGINE_SIDE, not (going_forward or reversing))
    if current_time - last_changed_direction >= COOLDOWN then
        ENGINE_PERIPHERAL.setMovementDirection(not reversing)
        last_changed_direction = current_time
    end
    sleep()
end
