local targetMeshes = {
    "tailights_dho_body", 
    "tailights_dho_trunk",
    "tailights_dho_sec_body", 
    "tailights_dho_sec_trunk",
    "tailights_dho_brake_body", 
    "tailights_dho_brake_trunk",
    "tailights_dho_brake_sec_body", 
    "tailights_dho_brake_sec_trunk"
}

local baseR = 35
local baseG = 11
local baseB = 0

local multExtra = 0.75   -- Extra A
local multBrake = 1.4    -- Normal 
local multABS   = 1.75   -- Emergency 

local flashSpeed = 0.15  -- Flash interval
local minGForce = 7.0    -- G-Force 
local minSpeed = 20      -- Minimum speed to activate

local timer = 0
local isFlashOn = false

function script.update(dt)
    local car = ac.getCar(0)
    if not car then return end

    -- 1. BMW Dynamic Brake Force Logic
    local acceleration = car.acceleration:length()
    
    -- Check wheel slip
    local isSlip = false
    for i=0,3 do
        if math.abs(car.wheels[i].ndSlip) > 0.5 then isSlip = true end
    end

    -- Emergency Condition: ABS active OR High G-Force OR Slip
    local isEmergency = (car.absInAction or acceleration > minGForce or isSlip) 
                        and car.speedKmh > minSpeed 
                        and car.brake > 0.5

    -- 2. Determine Brightness Multiplier
    local currentMult = 0

    if isEmergency then
        --Emergency Flashing
        timer = timer + dt
        if timer > flashSpeed then
            timer = 0
            isFlashOn = not isFlashOn
        end

        if isFlashOn then
            currentMult = multABS
        else
            currentMult = 0.7 -- Dim state between flashes
        end

    elseif car.brake > 0.1 then
        --Normal Braking
        currentMult = multBrake
        timer = 0
        isFlashOn = false

    elseif car.extraA then
        --(Parking Lights)
        currentMult = multExtra
        timer = 0
        isFlashOn = false

    else

        currentMult = 0
    end

    -- 3. Apply Color to Meshes
    local finalColor = rgb(baseR * currentMult, baseG * currentMult, baseB * currentMult)

    for _, meshName in ipairs(targetMeshes) do
        local node = ac.findNodes(meshName)
        if node then
            local meshObj = node:findMeshes(meshName)
            if meshObj then
                meshObj:setMaterialProperty('ksEmissive', finalColor)
            end
        else
            local meshSimple = ac.findMeshes(meshName)
            if meshSimple and meshSimple.setMaterialProperty then
                meshSimple:setMaterialProperty('ksEmissive', finalColor)
            end
        end
    end
end