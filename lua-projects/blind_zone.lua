BlindspotDriver = class('BlindspotDriver')

function BlindspotDriver:initialize(distance, isLeft, isRight, splinePosition)
    self.distance = distance
    self.isLeft = isLeft
    self.isRight = isRight
    self.splinePosition = splinePosition
end

Driver = class('Driver')

function Driver:initialize()
    self.car = ac.getCar(0)
    self.nearbyCars = {}
    
    self.mirrorLeftMesh = ac.findNodes('carRoot:0'):findMeshes('ext_mirror_l_glass_main_sig')
    self.mirrorRightMesh = ac.findNodes('carRoot:0'):findMeshes('ext_mirror_r_glass_main_sig')

    self.blinkTimer = 0
    self.blinkState = false 
    self.blinkInterval = 0.15

    -- Проверка, найдены ли меши
    if not self.mirrorLeftMesh then
    
    end
    if not self.mirrorRightMesh then
    
    end
end

function Driver:updateRadar(dt)
    local car = self.car
    self.currentWorldPosition = car.position:clone()
    self.wheelFLContact = car.wheels[0].contactPoint:clone()
    self.wheelFRContact = car.wheels[1].contactPoint:clone()
    self.blinkTimer = self.blinkTimer + dt
    if self.blinkTimer > self.blinkInterval then
        self.blinkTimer = 0
        self.blinkState = not self.blinkState
    end

    local newList = {}
    local hasLeftBlindspot = false 
    local hasRightBlindspot = false 
    
    for i = 0, ac.getSim().carsCount - 1 do
        if i ~= 0 then
            local otherCar = ac.getCar(i)
            local distance = self.currentWorldPosition:distance(otherCar.position)

            if distance < 6.35 then
                local myVector = (self.wheelFLContact + self.wheelFRContact) / 2 - self.wheelFRContact
                local other = (self.wheelFLContact + self.wheelFRContact) / 2 - otherCar.position

                local rad = math.acos(((myVector.x * other.x) + (myVector.y * other.y) + (myVector.z * other.z)) /
                    ((myVector.x ^ 2 + myVector.y ^ 2 + myVector.z ^ 2) ^ 0.5 *
                    (other.x ^ 2 + other.y ^ 2 + other.z ^ 2) ^ 0.5))

                local angleDeg = math.deg(rad)
                local isToLeft = angleDeg > 100 
                local isToRight = angleDeg < 80

                if isToLeft and not isToRight then
                    table.insert(newList, BlindspotDriver(distance, true, false, otherCar.splinePosition))
                    hasLeftBlindspot = true
                elseif isToRight and not isToLeft then
                    table.insert(newList, BlindspotDriver(distance, false, true, otherCar.splinePosition))
                    hasRightBlindspot = true
                end
            end
        end
    end
    self.nearbyCars = newList

    local indicatorColor = rgb(255, 51, 0)
    local offColor = rgb(0, 0, 0)

    -- Управление подсветкой левого зеркала
    if self.mirrorLeftMesh then
        if hasLeftBlindspot then
            if car.turningLeftLights then
                if self.blinkState then
                    self.mirrorLeftMesh:setMaterialProperty('ksEmissive', indicatorColor)
                else
                    self.mirrorLeftMesh:setMaterialProperty('ksEmissive', offColor)
                end
            else
                self.mirrorLeftMesh:setMaterialProperty('ksEmissive', indicatorColor)
            end
        else
            self.mirrorLeftMesh:setMaterialProperty('ksEmissive', offColor)
        end
    end

    if self.mirrorRightMesh then
        if hasRightBlindspot then
            if car.turningRightLights then
                if self.blinkState then
                    self.mirrorRightMesh:setMaterialProperty('ksEmissive', indicatorColor)
                else
                    self.mirrorRightMesh:setMaterialProperty('ksEmissive', offColor)
                end
            else
                self.mirrorRightMesh:setMaterialProperty('ksEmissive', indicatorColor)
            end
        else
            self.mirrorRightMesh:setMaterialProperty('ksEmissive', offColor)
        end
    end
end

MY_DRIVER = Driver()

function script.update(dt)
    MY_DRIVER.car = ac.getCar(0)
    MY_DRIVER:updateRadar(dt)
end
