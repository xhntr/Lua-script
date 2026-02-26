local carPhysics = ac.accessCarPhysics()

-- ==========================================
-- SAFE PHYSICS DATA LOADING
-- ==========================================

local function loadCarData()
   
    local engineIni = ac.INIConfig.carData(0, 'engine.ini')
 
    local drivetrainIni = ac.INIConfig.carData(0, 'drivetrain.ini')

    
    return {
        limit = engineIni:get('ENGINE', 'LIMITER', 7000),
        idle = engineIni:get('ENGINE', 'IDLE', 800),
        shiftTime = drivetrainIni:get('GEARBOX', 'SHIFT_UP_TIME', 150) / 1000
    }
end

local carSpecs = loadCarData()
local MAX_RPM = carSpecs.limit
local IDLE_RPM = carSpecs.idle
local SHIFT_TIME_UP = carSpecs.shiftTime

-- ==========================================
-- LOGIC SETTINGS
-- ==========================================

local MANUAL_TIMEOUT = 8.0
local KICKDOWN_DELAY = 0.150
local COAST_HOLD_TIME = 5.0       
local LOW_THROTTLE_DELAY = 11.0     
local LOW_THROTTLE_THRESHOLD = 0.35 
local UPSHIFT_DELAY_ON_LIFT = 5.0 

local DRIFT_ANGLE_THRESHOLD = 15 
local DRIFT_MIN_SPEED = 30
local SHIFT_COOLDOWN_TIME = SHIFT_TIME_UP + 0.550 
local SMOOTH_CUT_TIME = SHIFT_TIME_UP 
local SMOOTH_CUT_AMOUNT = 0.1 

-- Gear IDs
local GEAR_N = 1
local GEAR_1 = 2
local GEAR_8 = 9
local GEAR_R = 0

-- Variables
local gasIntervalId = nil
local isGasOn = false
local launchActive = false
local savedFinalRatio = nil

-- State Enum
local State = {
    PARK_NEUTRAL = 1,
    DRIVE = 2,
    MANUAL = 3,
    REVERSE = 4
}

-- ==========================================
-- DYNAMIC SHIFT MAP
-- ==========================================
local SHIFT_MAPS = {
    [0.0] = { up = MAX_RPM * 0.25, down = MAX_RPM * 0.16 },
    [0.3] = { up = MAX_RPM * 0.35, down = MAX_RPM * 0.20 }, 
    [0.5] = { up = MAX_RPM * 0.45, down = MAX_RPM * 0.28 }, 
    [0.7] = { up = MAX_RPM * 0.78, down = MAX_RPM * 0.50 },
    [0.9] = { up = MAX_RPM * 0.97, down = MAX_RPM * 0.57 },
    [1.0] = { up = MAX_RPM,        down = MAX_RPM * 0.60 }
}

-- ==========================================
-- HELPERS
-- ==========================================

local function toggleGas()
    if isGasOn then ac.overrideGasInput(0); isGasOn = false
    else ac.overrideGasInput(0.4); isGasOn = true end
end

local function startGasControl()
    if gasIntervalId == nil then gasIntervalId = setInterval(toggleGas, 0.15) end
end

local function stopGasControl()
    if gasIntervalId ~= nil then clearInterval(gasIntervalId); gasIntervalId = nil end
    ac.overrideGasInput(-1)
end

-- ==========================================
-- AUTO SHIFTER CLASS
-- ==========================================

local AutoShifter = {}

function AutoShifter:new()
    local obj = {}
    self.__index = self
    setmetatable(obj, self)
    obj.state = State.PARK_NEUTRAL
    obj.lastShiftTime = 0
    obj.manualTimer = 0
    obj.smoothThrottle = 0
    obj.prevThrottle = 0
    obj.kickdownCooldown = 0
    obj.kickdownHoldTimer = 0 
    obj.coastTimer = 0          
    obj.lowThrottleHoldTimer = 0 
    obj.upshiftHoldTimer = 0
    obj.launchCooldown = 0 
    obj.smoothCutTimer = 0 
    if carPhysics.gearsFinalRatio then savedFinalRatio = carPhysics.gearsFinalRatio end
    return obj
end

function AutoShifter:getShiftPoints(throttle)
    local t_low, t_high = 0.0, 1.0
    local keys = {0.0, 0.3, 0.5, 0.7, 0.9, 1.0}
    for i = 1, #keys - 1 do
        if throttle >= keys[i] and throttle <= keys[i+1] then
            t_low = keys[i]; t_high = keys[i+1]
            break
        end
    end
    local map_low = SHIFT_MAPS[t_low]
    local map_high = SHIFT_MAPS[t_high]
    local t = (throttle - t_low) / (t_high - t_low)
    return map_low.up + (map_high.up - map_low.up) * t, map_low.down + (map_high.down - map_low.down) * t
end

function AutoShifter:isDrifting()
    local car = ac.getCar(0)
    if not car or not car.wheels then return false end
    local fl, fr, rl, rr = car.wheels[0], car.wheels[1], car.wheels[2], car.wheels[3]
    if not rl or not rr or not fl or not fr then return false end
    
    local rearSlip = math.deg((math.abs(rl.slipAngle) + math.abs(rr.slipAngle)) / 2)
    local frontSlip = math.deg((math.abs(fl.slipAngle) + math.abs(fr.slipAngle)) / 2)
    local speed = car.speedKmh or 0
    
    return (speed > DRIFT_MIN_SPEED) and (rearSlip > DRIFT_ANGLE_THRESHOLD) and (rearSlip > frontSlip + 5)
end

function AutoShifter:calculateKickdownGear(currentGear, currentRPM)
    local TARGET_RPM_MIN = MAX_RPM * 0.65 
    local TARGET_RPM_MAX = MAX_RPM * 0.92 
    local GEAR_RATIO_MULT = 1.35 
    local RPM_SAFETY_BUFFER = MAX_RPM * 0.12
    
    local testGear = currentGear
    local projectedRPM = currentRPM
    
    while testGear > GEAR_1 do
        local nextGear = testGear - 1
        projectedRPM = projectedRPM * GEAR_RATIO_MULT
        if projectedRPM > MAX_RPM - RPM_SAFETY_BUFFER then break end
        if projectedRPM >= TARGET_RPM_MIN and projectedRPM <= TARGET_RPM_MAX then return nextGear end
        if projectedRPM < TARGET_RPM_MIN and (projectedRPM * GEAR_RATIO_MULT) > MAX_RPM - RPM_SAFETY_BUFFER then return nextGear end
        testGear = nextGear
    end
    if currentGear > GEAR_1 and (currentRPM * GEAR_RATIO_MULT) < MAX_RPM - RPM_SAFETY_BUFFER then return currentGear - 1 end
    return currentGear
end

function AutoShifter:update(dt)
    local now = os.clock()
    local car = ac.getCar(0)
    
    local gear = carPhysics.gear
    local rpm = carPhysics.rpm
    local throttle = carPhysics.gas
    local brake = carPhysics.brake
    local speed = carPhysics.speedKmh

    if savedFinalRatio == nil and carPhysics.gearsFinalRatio ~= 0 then savedFinalRatio = carPhysics.gearsFinalRatio end
    
    if self.smoothCutTimer > 0 then
        self.smoothCutTimer = self.smoothCutTimer - dt
        ac.overrideGasInput(SMOOTH_CUT_AMOUNT) 
    elseif not launchActive then
         if gasIntervalId == nil then ac.overrideGasInput(-1) end 
    end
    
    if self.launchCooldown > 0 then self.launchCooldown = self.launchCooldown - dt end
    
    -- LAUNCH CONTROL
    if gear == GEAR_1 and throttle >= 0.98 and brake >= 0.2 and speed <= 5 and car.tractionControlMode == 0 then
        if self.state == State.MANUAL then self.state = State.DRIVE; self.manualTimer = 0; ac.setMessage("Launch Control", "Auto Mode Active") end
        if not launchActive then launchActive = true; ac.setGearsFinalRatio(0); ac.setMessage("Launch Control", "Release Brake") end
        carPhysics.brake = 1 
        ac.setEngineRPMLimit(MAX_RPM * 0.4, true)
        if rpm >= (MAX_RPM * 0.35) then startGasControl() else stopGasControl(); ac.overrideGasInput(1) end
        return 
    elseif launchActive then
        launchActive = false; stopGasControl()
        if savedFinalRatio then ac.setGearsFinalRatio(savedFinalRatio) end
        ac.setEngineRPMLimit(MAX_RPM, true); ac.overrideGasInput(-1); ac.setMessage("Launch!")
        self.launchCooldown = 0.5; self.lastShiftTime = now + 0.15
        return
    end
    if self.launchCooldown > 0 then return end

    -- LOGIC
    self.smoothThrottle = self.smoothThrottle + (throttle - self.smoothThrottle) * 10 * dt
    local throttleDelta = throttle - self.prevThrottle
    if (self.prevThrottle - throttle) > 0.05 then self.upshiftHoldTimer = UPSHIFT_DELAY_ON_LIFT end
    if self.upshiftHoldTimer > 0 then
        self.upshiftHoldTimer = self.upshiftHoldTimer - dt
        if throttle > 0.8 or brake > 0.2 then self.upshiftHoldTimer = 0 end
    end

    local isKickdownInput = (throttle > 0.90) or (throttleDelta > 0.4 and throttle > 0.8)
    if isKickdownInput then self.kickdownHoldTimer = self.kickdownHoldTimer + dt else self.kickdownHoldTimer = 0 end
    local isKickdownReady = self.kickdownHoldTimer >= KICKDOWN_DELAY
    if self.kickdownCooldown > 0 then self.kickdownCooldown = self.kickdownCooldown - dt end
    self.prevThrottle = throttle
    
    if throttle < 0.05 and brake < 0.05 then self.coastTimer = self.coastTimer + dt else self.coastTimer = 0 end
    if throttle >= 0.05 and throttle < LOW_THROTTLE_THRESHOLD then self.lowThrottleHoldTimer = self.lowThrottleHoldTimer + dt else self.lowThrottleHoldTimer = 0 end

    if (carPhysics.gearUp or carPhysics.gearDown) and gear > GEAR_N then self.state = State.MANUAL; self.manualTimer = now + MANUAL_TIMEOUT end
    local isDrifting = self:isDrifting()

    if self.state == State.PARK_NEUTRAL then
        if gear == GEAR_R then self.state = State.REVERSE elseif gear > GEAR_N then self.state = State.DRIVE end
    elseif self.state == State.REVERSE then
        if gear ~= GEAR_R then self.state = State.PARK_NEUTRAL end
    elseif self.state == State.MANUAL then
        if now > self.manualTimer and gear > GEAR_N then self.state = State.DRIVE end
        if gear > GEAR_N then
            if rpm > MAX_RPM - 100 and gear < GEAR_8 then carPhysics.gearUp = true
            elseif rpm < IDLE_RPM + 200 and gear > GEAR_1 then carPhysics.gearDown = true end
        end
    elseif self.state == State.DRIVE then
        if gear <= GEAR_N then return end
        if isKickdownReady and self.kickdownCooldown <= 0 and gear > GEAR_1 and brake < 0.1 then
            local targetGear = self:calculateKickdownGear(gear, rpm)
            if targetGear < gear then
                carPhysics.requestedGearIndex = targetGear; self.lastShiftTime = now; self.kickdownCooldown = 0.5; self.kickdownHoldTimer = 0
                return
            end
        end
        if now - self.lastShiftTime < SHIFT_COOLDOWN_TIME then return end
        local upRPM, downRPM = self:getShiftPoints(self.smoothThrottle)
        if brake > 0.05 then
             local targetBrakeDownRPM = (MAX_RPM * 0.28) + (brake * (MAX_RPM * 0.35))
             if targetBrakeDownRPM > downRPM then downRPM = targetBrakeDownRPM end
             upRPM = 99999
        end
        
        if rpm > upRPM and gear < GEAR_8 then
             if not isDrifting then 
                local isRedlining = rpm > (MAX_RPM - 500)
                local isHoldActive = self.upshiftHoldTimer > 0
                if (not isHoldActive) or isRedlining then
                    if (rpm / 1.3) > downRPM then 
                        carPhysics.gearUp = true; self.lastShiftTime = now; self.smoothCutTimer = SMOOTH_CUT_TIME
                    end
                end
             end
        elseif rpm < downRPM and gear > GEAR_1 then
             local isCriticalRPM = rpm < (IDLE_RPM + 300)
             local isBraking = brake > 0.1    
             local allowCoastShift = (throttle < 0.05 and self.coastTimer > COAST_HOLD_TIME) 
             local allowLowThrottleShift = (throttle >= 0.05 and throttle < LOW_THROTTLE_THRESHOLD and self.lowThrottleHoldTimer > LOW_THROTTLE_DELAY) 
             local allowHighThrottleShift = (throttle >= LOW_THROTTLE_THRESHOLD) 
             if isCriticalRPM or isBraking or allowCoastShift or allowLowThrottleShift or allowHighThrottleShift then
                 if (rpm * 1.3) < MAX_RPM then carPhysics.gearDown = true; self.lastShiftTime = now end
             end
        end
    end
end

-- ==========================================
-- MAIN
-- ==========================================
local shifter = AutoShifter:new()
local init = false
local isActive = false

local function autoshiftscript(dt)
    if not init then
        init = true
        ac.setMessage("Auto Shifter", string.format("RPM: %d", MAX_RPM))
    end
    -- Ctrl + G to toggle
    if ac.isKeyDown(ac.KeyIndex.Control) and ac.isKeyPressed(ac.KeyIndex.G) then
        isActive = not isActive
        if isActive then ac.setMessage("AUTO MAGA", "ON") else ac.setMessage("AUTO MAGA", "OFF") end
    end
    if not isActive then 
        if shifter.smoothCutTimer > 0 then ac.overrideGasInput(-1); shifter.smoothCutTimer = 0 end
        return 
    end
    
    local car = ac.getCar(0)
    if car.isAIControlled then return end
    shifter:update(dt)
end

return autoshiftscript
