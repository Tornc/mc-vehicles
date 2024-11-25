-- Modification of @crocblancyt"s pump code

local FLUID_TARGET_TYPES = {
    "createdieselgenerators:huge_diesel_engine_block_entity"
}

local FLUID_SOURCE_TYPES = {
    "create:creative_fluid_tank",
    "create:fluid_tank",
    "create:portable_fluid_interface",
    "createbigcannons:fluid_shell",
    "createdieselgenerators:oil_barrel_block_entity",
    "createendertransmission:fluid_transmitter",
    "create_connected:creative_fluid_vessel",
    "create_connected:fluid_vessel",
    -- Azure Armada stupidity
    "fluidTank",
}

local SIDES = peripheral.getNames()

local function contains(value, list)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
end

local function refueling()
    local fuel_tanks = {}
    local engines = {}

    for _, side in pairs(SIDES) do
        local side_type = peripheral.getType(side)
        if contains(side_type, FLUID_TARGET_TYPES) then
            table.insert(engines, peripheral.wrap(side))
        elseif contains(side_type, FLUID_SOURCE_TYPES) then
            table.insert(fuel_tanks, peripheral.wrap(side))
        end
    end

    if #fuel_tanks == 0 then error("NO FUEL TANK FOUND") end
    if #engines == 0 then error("NO ENGINE FOUND") end

    while true do
        for _, fuel_tank in pairs(fuel_tanks) do
            for _, engine in pairs(engines) do
				engine.pullFluid(peripheral.getName(fuel_tank))
            end
        end

        sleep()
    end
end

-- Bit overkill, but this allows you to add 
-- extra functionality without the program 
-- freezing for a tick after every fluid push.
parallel.waitForAny(refueling)
