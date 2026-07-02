-- Load core services and modules
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local Fsys = require(ReplicatedStorage:WaitForChild("Fsys"))
local LoadModule = Fsys.load

-- Get router client upvalue (scan dynamically, don't assume index 7)
local RouterClient = LoadModule("RouterClient")
local routerClientUpvalue = nil
local routerClientUpvalueIdx = nil
for idx = 1, 50 do
    local ok, val = pcall(debug.getupvalue, RouterClient.init, idx)
    if not ok or val == nil then break end
    if type(val) == "table" then
        local isRemoteTable = false
        for _, entry in pairs(val) do
            if typeof(entry) == "Instance" and (entry:IsA("RemoteFunction") or entry:IsA("RemoteEvent")) then
                isRemoteTable = true; break
            end
        end
        if isRemoteTable then
            routerClientUpvalue    = val
            routerClientUpvalueIdx = idx
            break
        end
    end
end
if not routerClientUpvalue then
    warn("[NeonMaker] Could not find RouterClient remotes upvalue")
    routerClientUpvalue = {}
end
local originalRoutes = {}
for routeName, route in pairs(routerClientUpvalue) do
    pcall(function() route.Name = routeName end)
    originalRoutes[routeName] = route
end

-- Load UI Manager and get trade license
local UIManager = LoadModule("UIManager")
local ClientData = LoadModule("ClientData")
local Maid = LoadModule("Maid")
local TweenPromise = LoadModule("TweenPromise")
local Promise = LoadModule("package:Promise")
local CharacterHider = LoadModule("CharacterHider")
local CharacterScale = LoadModule("CharacterScale")
local GameplayFX = LoadModule("GameplayFX")
local SoundPlayer = LoadModule("SoundPlayer")
local SoundDB = LoadModule("SoundDB")
local Music = LoadModule("Music")

local originalWarn = warn
warn = function(message, ...)
    -- Suppress the ailments_completed warning safely
    if type(message) ~= "string" or not message:find("ailments_completed") then
        originalWarn(message, ...)
    end
end
local inventory = ClientData.get("inventory").toys
local tradeLicenseKey = nil
local fusionMaid = Maid.new()

for toyKey, toy in pairs(inventory) do
   if toy.id == "trade_license" then
       tradeLicenseKey = toyKey
       break
   end
end

-- Hook tool equip/unequip
local routeHooks = {
   ["ToolAPI/Equip"] = function(self, itemKey, ...)
       if itemKey == tradeLicenseKey then
           UIManager.set_app_visibility("TradeHistoryApp", true)
       end
       return originalRoutes["ToolAPI/Equip"](self, itemKey, ...)
   end,
   ["ToolAPI/Unequip"] = function(self, itemKey)
       if itemKey == tradeLicenseKey then
           UIManager.set_app_visibility("TradeHistoryApp", false)
       end
       return originalRoutes["ToolAPI/Unequip"](self, itemKey)
   end
}

if routerClientUpvalueIdx then
    debug.setupvalue(RouterClient.init, routerClientUpvalueIdx, setmetatable(routeHooks, {
   __index = originalRoutes,
   __newindex = function(tbl, key, value)
       if key == "ToolAPI/Equip" or key == "ToolAPI/Unequip" then
           rawset(tbl, key, value)
       else
           originalRoutes[key] = value
       end
   end
}))
end  -- routerClientUpvalueIdx

-- Trade history tracking
local TradeHistoryApp = UIManager.apps.TradeHistoryApp
local TradeApp = UIManager.apps.TradeApp

-- Backup original functions
if TradeHistoryApp._ORIGINAL_create_trade_frame then
   TradeHistoryApp._create_trade_frame = TradeHistoryApp._ORIGINAL_create_trade_frame
end
if TradeApp._ORIGINAL_change_local_trade_state then
   TradeApp._change_local_trade_state = TradeApp._ORIGINAL_change_local_trade_state
end
if TradeApp._ORIGINAL_overwrite_local_trade_state then
   TradeApp._overwrite_local_trade_state = TradeApp._ORIGINAL_overwrite_local_trade_state
end

TradeHistoryApp._ORIGINAL_create_trade_frame = TradeHistoryApp._create_trade_frame
TradeApp._ORIGINAL_change_local_trade_state = TradeApp._change_local_trade_state
TradeApp._ORIGINAL_overwrite_local_trade_state = TradeApp._overwrite_local_trade_state

local tradeCache = {}
local currentTradeItems = nil

function TradeApp._change_local_trade_state(self, changes, ...)
   local currentState = TradeApp.local_trade_state

   if currentState and currentState.trade_id then
       local isSender = currentState.sender == LocalPlayer
       local isRecipient = currentState.recipient == LocalPlayer

       if isSender and changes.sender_offer and changes.sender_offer.items then
           tradeCache[currentState.trade_id] = {
               items = table.clone(changes.sender_offer.items),
               isSender = true
           }
           currentTradeItems = changes.sender_offer.items
       elseif isRecipient and changes.recipient_offer and changes.recipient_offer.items then
           tradeCache[currentState.trade_id] = {
               items = table.clone(changes.recipient_offer.items),
               isSender = false
           }
           currentTradeItems = changes.recipient_offer.items
       end
   end

   return TradeApp._ORIGINAL_change_local_trade_state(self, changes, ...)
end

function TradeApp._overwrite_local_trade_state(self, tradeState, ...)
   if tradeState then
       local isSender = tradeState.sender == LocalPlayer
       local isRecipient = tradeState.recipient == LocalPlayer

       if isSender and tradeState.sender_offer and currentTradeItems then
           tradeState.sender_offer.items = currentTradeItems
       elseif isRecipient and tradeState.recipient_offer and currentTradeItems then
           tradeState.recipient_offer.items = currentTradeItems
       end
   else
       currentTradeItems = nil
       if TradeApp._last_trade_id then
           tradeCache[TradeApp._last_trade_id] = nil
           TradeApp._last_trade_id = nil
       end
   end

   return TradeApp._ORIGINAL_overwrite_local_trade_state(self, tradeState, ...)
end

function TradeHistoryApp._create_trade_frame(self, tradeData, ...)
   if tradeData.trade_id and tradeCache[tradeData.trade_id] then
       local cachedData = tradeCache[tradeData.trade_id]
       local modifiedData = table.clone(tradeData)

       if cachedData.isSender then
           modifiedData.sender_items = table.clone(cachedData.items)
       else
           modifiedData.recipient_items = table.clone(cachedData.items)
       end

       return TradeHistoryApp._ORIGINAL_create_trade_frame(self, modifiedData, ...)
   end

   return TradeHistoryApp._ORIGINAL_create_trade_frame(self, tradeData, ...)
end


-- ===============================================================
-- PET SPAWNING SYSTEM  (ported from WIP3 + friendship + fusion + rename)
-- ===============================================================
local PetData = {}
PetData.downloader = LoadModule("DownloadClient")

task.spawn(function()
    local load = require(game.ReplicatedStorage:WaitForChild('Fsys')).load
    set_thread_identity(2)
    local clientData = load('ClientData')
    local items = load('KindDB')
    local router = load('RouterClient')
    local downloader = load('DownloadClient')
    local animationManager = load('AnimationManager')
    local petRigs = load('new:PetRigs')
    local AilmentsClient = load('new:AilmentsClient')
    local AilmentsDB = load('new:AilmentsDB')
    set_thread_identity(8)

    -- Hook MegaNeonAnimator so mega neon visuals are driven by the real system
    local MegaNeonAnimator = nil
    pcall(function()
        MegaNeonAnimator = game:GetService("ReplicatedStorage").ClientModules.Game.PetEntities.PetEntitySystems.MegaNeonAnimator
    end)

    local petModels = {}
    local pets = {}
    local equippedPet = nil
    local mountedPet = nil
    local currentMountTrack = nil

    -- ----------------------------------------------------------------
    -- Time / day / season aware ailment (task) picker
    -- ----------------------------------------------------------------
    -- Returns a list of ailment kind strings appropriate for right now.
    -- Night (22:00-06:00)  -> no daily tasks (empty list)
    -- Morning (06:00-12:00) -> school, breakfast-style tasks
    -- Afternoon (12:00-17:00) -> outdoor / active tasks
    -- Evening (17:00-22:00) -> wind-down / indoor tasks
    -- Weekend bonus: extra fun/social tasks
    -- Season (by month): spring/summer lean outdoor; autumn/winter lean cosy
    local function getContextualAilmentTypes()
        local t      = os.date("*t")   -- local time table
        local hour   = t.wday and t.hour or 12  -- fallback noon
        local wday   = t.wday  -- 1=Sun,2=Mon..7=Sat
        local month  = t.month -- 1-12
        local isWeekend = (wday == 1 or wday == 7)
        local isSummer  = (month >= 6 and month <= 8)
        local isWinter  = (month == 12 or month <= 2)
        local isSpring  = (month >= 3 and month <= 5)
        -- local isAutumn  = (month >= 9 and month <= 11)

        -- Night: no tasks
        if hour >= 22 or hour < 6 then
            return {}
        end

        -- All valid DB kinds (excluding meta ones)
        local allKinds = {}
        for kind, _ in pairs(AilmentsDB) do
            if kind ~= 'at_work' and kind ~= 'mystery' and kind ~= 'walking' then
                table.insert(allKinds, kind)
            end
        end

        -- Build a weighted candidate list
        -- We tag kinds by rough category so we can weight by time/season.
        -- Unknown kinds are always included at base weight.
        local schoolKinds   = { school = true, homework = true, study = true }
        local outdoorKinds  = { walk = true, exercise = true, park = true, play = true, swim = true, run = true }
        local cozyKinds     = { sleep = true, nap = true, rest = true, read = true, movie = true, tv = true }
        local socialKinds   = { friend = true, party = true, birthday = true, playdate = true }
        local foodKinds     = { eat = true, feed = true, snack = true, lunch = true, dinner = true, breakfast = true }

        local function categorise(kind)
            local lk = kind:lower()
            for k,_ in pairs(schoolKinds)  do if lk:find(k) then return 'school'  end end
            for k,_ in pairs(outdoorKinds) do if lk:find(k) then return 'outdoor' end end
            for k,_ in pairs(cozyKinds)    do if lk:find(k) then return 'cozy'    end end
            for k,_ in pairs(socialKinds)  do if lk:find(k) then return 'social'  end end
            for k,_ in pairs(foodKinds)    do if lk:find(k) then return 'food'    end end
            return 'misc'
        end

        -- Weight multipliers by time block
        local schoolW, outdoorW, cozyW, socialW, foodW, miscW

        if hour >= 6 and hour < 12 then
            -- Morning
            schoolW  = isWeekend and 0 or 3   -- school on weekdays
            outdoorW = isSummer and 2 or 1
            cozyW    = 0
            socialW  = isWeekend and 2 or 0
            foodW    = 2   -- breakfast
            miscW    = 1
        elseif hour >= 12 and hour < 17 then
            -- Afternoon
            schoolW  = isWeekend and 0 or 1
            outdoorW = (isSummer or isSpring) and 3 or 1
            cozyW    = isWinter and 1 or 0
            socialW  = isWeekend and 2 or 1
            foodW    = 1   -- lunch
            miscW    = 1
        else
            -- Evening (17-22)
            schoolW  = 0
            outdoorW = 0
            cozyW    = isWinter and 3 or 2
            socialW  = isWeekend and 2 or 1
            foodW    = 2   -- dinner
            miscW    = 1
        end

        -- Build weighted pool
        local pool = {}
        for _, kind in ipairs(allKinds) do
            local cat = categorise(kind)
            local w = miscW
            if cat == 'school'  then w = schoolW
            elseif cat == 'outdoor' then w = outdoorW
            elseif cat == 'cozy'    then w = cozyW
            elseif cat == 'social'  then w = socialW
            elseif cat == 'food'    then w = foodW
            end
            for _ = 1, w do table.insert(pool, kind) end
        end

        -- If pool is empty (e.g. all weights zero), fall back to misc
        if #pool == 0 then
            for _, kind in ipairs(allKinds) do table.insert(pool, kind) end
        end

        -- Pick 2-4 unique kinds from the weighted pool
        local chosen, used = {}, {}
        local target = math.random(2, math.min(4, #allKinds))
        local attempts = 0
        while #chosen < target and attempts < 200 do
            attempts = attempts + 1
            local pick = pool[math.random(1, #pool)]
            if not used[pick] then
                used[pick] = true
                table.insert(chosen, pick)
            end
        end
        return chosen
    end

    -- Ailment injection: hook get_server so our spawned pets get time-aware tasks
    local cachedAilments = {}
    local originalGetServer = clientData.get_server
    clientData.get_server = function(player, key, ...)
        local data = originalGetServer(player, key, ...)
        if key == 'ailments_manager' and player == game.Players.LocalPlayer then
            local cloned = {}
            if data then
                for k, v in pairs(data) do
                    cloned[k] = type(v) == 'table' and table.clone(v) or v
                end
            end
            cloned.ailments = cloned.ailments or {}
            for petUniqueId, _ in pairs(pets) do
                if cachedAilments[petUniqueId] then
                    cloned.ailments[petUniqueId] = cachedAilments[petUniqueId]
                else
                    local ailmentTypes = getContextualAilmentTypes()
                    local ailments = {}
                    for i, ailmentType in ipairs(ailmentTypes) do
                        local ailmentId = game:GetService('HttpService'):GenerateGUID(false)
                        ailments[ailmentId] = {
                            components = {},
                            created_timestamp = os.time(),
                            kind = ailmentType,
                            progress = 0,
                            rate = 0,
                            rate_timestamp = os.time(),
                            sort_order = i * 100,
                        }
                    end
                    cachedAilments[petUniqueId] = ailments
                    cloned.ailments[petUniqueId] = ailments
                end
            end
            return cloned
        end
        return data
    end

    local function updateData(key, action)
        local data = clientData.get(key)
        local clonedData = table.clone(data)
        clientData.predict(key, action(clonedData))
    end

    local function getUniqueId()
        local HttpService = game:GetService('HttpService')
        return HttpService:GenerateGUID(false)
    end

    local function getPetModel(kind)
        if petModels[kind] then
            return petModels[kind]
        end
        local streamed = downloader.promise_download_copy('Pets', kind):expect()
        petModels[kind] = streamed
        return streamed
    end

    local function createPet(id, properties)
        local uniqueId = getUniqueId()
        local item = items[id]
        if not item then
            warn('Pet ID not found: ' .. id)
            return nil
        end
        local props = properties or {}
        props.pet_trick_level    = props.pet_trick_level or 0
        props.friendship_level   = props.friendship_level or 1
        props.age                = props.age or 6
        props.ailments_completed = 999
        props.rp_name            = props.rp_name or ''
        set_thread_identity(2)
        local new_pet = {
            unique        = uniqueId,
            category      = 'pets',
            id            = id,
            kind          = item.kind,
            newness_order = math.random(1, 900000),
            properties    = props,
        }
        local inventory = clientData.get('inventory')
        inventory.pets[uniqueId] = new_pet
        set_thread_identity(8)
        pets[uniqueId] = {
            data = new_pet,
            model = nil,
        }
        return new_pet
    end

    -- Toy spawning function
    local function createToy(id)
        local uniqueId = getUniqueId()
        local item = items[id]
        if not item then
            warn('Toy ID not found: ' .. id)
            return nil
        end
        set_thread_identity(2)
        local new_toy = {
            unique = uniqueId,
            category = 'toys',
            id = id,
            kind = item.kind,
            newness_order = math.random(1, 900000),
            properties = {},
        }
        local inventory = clientData.get('inventory')
        inventory.toys[uniqueId] = new_toy
        set_thread_identity(8)
        return new_toy
    end

    local function neonify(model, entry, isMegaNeon)
        local petModel = model:FindFirstChild('PetModel')
        if not petModel then return end
        for neonPart, configuration in pairs(entry.neon_parts) do
            local trueNeonPart =
                petRigs.get(petModel).get_geo_part(petModel, neonPart)
            trueNeonPart.Material = configuration.Material
            trueNeonPart.Color = configuration.Color
        end
        -- Drive the MegaNeonAnimator for mega neon pets
        if isMegaNeon and MegaNeonAnimator then
            pcall(function()
                -- Scan MegaNeonAnimator upvalues for the animate/start function
                local animateFn = nil
                for idx = 1, 80 do
                    local ok, val = pcall(debug.getupvalue, MegaNeonAnimator, idx)
                    if not ok or val == nil then break end
                    if type(val) == 'function' then
                        animateFn = val; break
                    end
                end
                if animateFn then
                    task.spawn(animateFn, petModel)
                else
                    -- Fallback: require and call directly if it's a ModuleScript
                    local mod = require(MegaNeonAnimator)
                    if mod and mod.animate then mod.animate(petModel)
                    elseif mod and mod.start then mod.start(petModel) end
                end
            end)
        end
    end

    local function getAnimatorTasks()
        if not MegaNeonAnimator then return nil end
        local tasks = nil
        pcall(function()
            local mod = require(MegaNeonAnimator)
            -- Scan upvalues of every function in the module for a tasks/jobs table
            local function scanFn(fn)
                if type(fn) ~= 'function' then return end
                for idx = 1, 80 do
                    local ok, val = pcall(debug.getupvalue, fn, idx)
                    if not ok or val == nil then break end
                    if type(val) == 'table' then
                        -- A tasks table typically maps model -> coroutine/thread
                        local looksLikeTasks = true
                        local count = 0
                        for k, v in pairs(val) do
                            count = count + 1
                            if type(v) ~= 'thread' and type(v) ~= 'function' and type(v) ~= 'table' then
                                looksLikeTasks = false; break
                            end
                            if count > 20 then break end
                        end
                        if looksLikeTasks and count == 0 then looksLikeTasks = true end -- empty is fine
                        if looksLikeTasks then tasks = val; return end
                    end
                end
            end
            if type(mod) == 'table' then
                for _, v in pairs(mod) do scanFn(v) end
            elseif type(mod) == 'function' then
                scanFn(mod)
            end
        end)
        return tasks
    end

    local animatorTasksTable = getAnimatorTasks()

    -- ?? Same require+upvalue pattern as getAnimatorTasks(), one per display module ??
    local RS = game:GetService('ReplicatedStorage')
    local function rsFind(...) local n=RS for _,k in ipairs({...}) do n=n and n:FindFirstChild(k) end return n end

    local function getModuleUpvalueTable(moduleScript, shapeValidator)
        if not moduleScript then return nil end
        local found = nil
        pcall(function()
            local mod = require(moduleScript)
            local function scanFn(fn)
                if type(fn) ~= 'function' then return end
                for idx = 1, 80 do
                    local ok, val = pcall(debug.getupvalue, fn, idx)
                    if not ok or val == nil then break end
                    if type(val) == 'table' then
                        if not shapeValidator or shapeValidator(val) then
                            found = val; return
                        end
                    end
                end
            end
            if type(mod) == 'table' then
                for _, v in pairs(mod) do if not found then scanFn(v) end end
            elseif type(mod) == 'function' then
                scanFn(mod)
            end
        end)
        return found
    end

    -- Shape: empty table or values are tables/Instances (entity registries)
    local function entityTableValidator(val)
        local count = 0
        for _, v in pairs(val) do
            count += 1
            if type(v) ~= 'table' and type(v) ~= 'userdata' and type(v) ~= 'function' then
                return false
            end
            if count > 10 then break end
        end
        return true
    end

    -- Grab each display module's live internal entity table at load time
    local petNameTable        = getModuleUpvalueTable(rsFind('new','modules','PlayerNameApp','PetName'),        entityTableValidator)
    local roamingPetNameTable = getModuleUpvalueTable(rsFind('new','modules','PlayerNameApp','RoamingPetName'), entityTableValidator)
    local friendshipTable     = getModuleUpvalueTable(rsFind('new','modules','PlayerNameApp','PetProgression'),                        entityTableValidator)
    local petProgressionTable = getModuleUpvalueTable(rsFind('new','modules','PetProgression','PetProgressionClientService'),          entityTableValidator)
    local petAgeBarTable      = getModuleUpvalueTable(rsFind('new','modules','PetProgression','PetAgeBar'),    entityTableValidator)
    local petReactionTable    = getModuleUpvalueTable(rsFind('new','modules','IdleProgression','PetPenClient','RoamingPetPerformances'), entityTableValidator)
    local learnTricksTable    = getModuleUpvalueTable(rsFind('new','modules','IdleProgression','PetPenClient','RoamingPetBehavior'),     entityTableValidator)

    local function addPetWrapper(wrapper)
        -- Attach the animator tasks table so tasks render over the pet model
        if animatorTasksTable ~= nil then
            wrapper.tasks = animatorTasksTable
        end
        -- Attach each display module's live entity table as a wrapper field.
        -- The game's PetEntitySystems read these fields off the wrapper to know
        -- which live table to register this pet into.
        if petNameTable        then wrapper.pet_name_entities         = petNameTable        end
        if roamingPetNameTable then wrapper.roaming_pet_name_entities = roamingPetNameTable end
        if friendshipTable     then wrapper.friendship_entities       = friendshipTable     end
        if petProgressionTable then wrapper.pet_progression_entities  = petProgressionTable end
        if petAgeBarTable      then wrapper.pet_age_bar_entities      = petAgeBarTable      end
        if petReactionTable    then wrapper.pet_reaction_entities     = petReactionTable    end
        if learnTricksTable    then wrapper.learn_tricks_entities     = learnTricksTable    end
        updateData('pet_char_wrappers', function(petWrappers)
            wrapper.unique = #petWrappers + 1
            wrapper.index = #petWrappers + 1
            petWrappers[#petWrappers + 1] = wrapper
            return petWrappers
        end)
    end

    local function addPetState(state)
        updateData('pet_state_managers', function(petStates)
            petStates[#petStates + 1] = state
            return petStates
        end)
    end

    local function findIndex(array, finder)
        for index, value in pairs(array) do
            local isIt = finder(value, index)
            if isIt then return index end
        end
        return nil
    end

    local function removePetWrapper(uniqueId)
        updateData('pet_char_wrappers', function(petWrappers)
            local index = findIndex(petWrappers, function(wrapper)
                return wrapper.pet_unique == uniqueId
            end)
            if not index then return petWrappers end
            table.remove(petWrappers, index)
            for wrapperIndex, wrapper in pairs(petWrappers) do
                wrapper.unique = wrapperIndex
                wrapper.index = wrapperIndex
            end
            return petWrappers
        end)
    end

    local function clearPetState(uniqueId)
        local pet = pets[uniqueId]
        if not pet then return end
        if not pet.model then return end
        updateData('pet_state_managers', function(states)
            local index = findIndex(states, function(state)
                return state.char == pet.model
            end)
            if not index then return states end
            local clonedStates = table.clone(states)
            clonedStates[index] = table.clone(clonedStates[index])
            clonedStates[index].states = {}
            return clonedStates
        end)
    end

    local function setPetState(uniqueId, id)
        local pet = pets[uniqueId]
        if not pet then return end
        if not pet.model then return end
        updateData('pet_state_managers', function(states)
            local index = findIndex(states, function(state)
                return state.char == pet.model
            end)
            if not index then return states end
            local clonedStates = table.clone(states)
            clonedStates[index] = table.clone(clonedStates[index])
            clonedStates[index].states = { { id = id } }
            return clonedStates
        end)
    end

    local function attachPlayerToPet(pet)
        local character = game.Players.LocalPlayer.Character
        if not character then return false end
        if not character.PrimaryPart then return false end
        local ridePosition = pet:FindFirstChild('RidePosition', true)
        if not ridePosition then return false end
        local sourceAttachment = Instance.new('Attachment')
        sourceAttachment.Parent = ridePosition
        sourceAttachment.Position = Vector3.new(0, 1.237, 0)
        sourceAttachment.Name = 'SourceAttachment'
        local stateConnection = Instance.new('RigidConstraint')
        stateConnection.Name = 'StateConnection'
        stateConnection.Attachment0 = sourceAttachment
        stateConnection.Attachment1 = character.PrimaryPart.RootAttachment
        stateConnection.Parent = character
        return true
    end

    local function clearPlayerState()
        updateData('state_manager', function(state)
            local clonedState = table.clone(state)
            clonedState.states = {}
            clonedState.is_sitting = false
            return clonedState
        end)
    end

    local function setPlayerState(id)
        updateData('state_manager', function(state)
            local clonedState = table.clone(state)
            clonedState.states = { { id = id } }
            clonedState.is_sitting = true
            return clonedState
        end)
    end

    local function removePetState(uniqueId)
        local pet = pets[uniqueId]
        if not pet then return end
        if not pet.model then return end
        updateData('pet_state_managers', function(petStates)
            local index = findIndex(petStates, function(state)
                return state.char == pet.model
            end)
            if not index then return petStates end
            table.remove(petStates, index)
            return petStates
        end)
    end

    local function unmount(uniqueId)
        local pet = pets[uniqueId]
        if not pet then return end
        if not pet.model then return end
        if currentMountTrack then
            currentMountTrack:Stop()
            currentMountTrack:Destroy()
        end
        local sourceAttachment = pet.model:FindFirstChild('SourceAttachment', true)
        if sourceAttachment then sourceAttachment:Destroy() end
        if game.Players.LocalPlayer.Character then
            for _, descendant in pairs(game.Players.LocalPlayer.Character:GetDescendants()) do
                if descendant:IsA('BasePart') and descendant:GetAttribute('HaveMass') then
                    descendant.Massless = false
                end
            end
        end
        clearPetState(uniqueId)
        clearPlayerState()
        pet.model:ScaleTo(1)
        mountedPet = nil
    end

    local function mount(uniqueId, playerState, petState)
        local pet = pets[uniqueId]
        if not pet then return end
        if not pet.model then return end
        local player = game.Players.LocalPlayer
        if not player.Character then return end
        if not player.Character.PrimaryPart then return end
        mountedPet = uniqueId
        setPetState(uniqueId, petState)
        setPlayerState(playerState)
        pet.model:ScaleTo(2)
        attachPlayerToPet(pet.model)
        currentMountTrack = player.Character.Humanoid.Animator:LoadAnimation(
            animationManager.get_track('PlayerRidingPet')
        )
        player.Character.Humanoid.Sit = true
        for _, descendant in pairs(player.Character:GetDescendants()) do
            if descendant:IsA('BasePart') and descendant.Massless == false then
                descendant.Massless = true
                descendant:SetAttribute('HaveMass', true)
            end
        end
        currentMountTrack:Play()
    end

    local function fly(uniqueId)
        mount(uniqueId, 'PlayerFlyingPet', 'PetBeingFlown')
    end

    local function ride(uniqueId)
        mount(uniqueId, 'PlayerRidingPet', 'PetBeingRidden')
    end

    local function unequip(item)
        local pet = pets[item.unique]
        if not pet then return end
        if not pet.model then return end
        unmount(item.unique)
        removePetWrapper(item.unique)
        removePetState(item.unique)
        pet.model:Destroy()
        pet.model = nil
        equippedPet = nil
        cachedAilments[item.unique] = nil
        task.defer(function()
            task.wait(0.15)
            AilmentsClient.on_ailments_changed(game.Players.LocalPlayer)
        end)
    end

    local function equip(item)
        if item.category == 'pets' then
            if equippedPet then unequip(equippedPet) end
            local petModel = getPetModel(item.kind):Clone()
            petModel.Parent = workspace
            pets[item.unique].model = petModel
            if item.properties.neon or item.properties.mega_neon then
                neonify(petModel, items[item.kind], item.properties.mega_neon == true)
            end
            equippedPet = item
            addPetWrapper({
                char              = petModel,
                mega_neon         = item.properties.mega_neon,
                neon              = item.properties.neon,
                player            = game.Players.LocalPlayer,
                entity_controller = game.Players.LocalPlayer,
                controller        = game.Players.LocalPlayer,
                rp_name           = item.properties.rp_name or '',
                pet_trick_level   = item.properties.pet_trick_level or 0,
                friendship_level  = item.properties.friendship_level or 1,
                ailments_completed = 999,
                pet_unique        = item.unique,
                pet_id            = item.id,
                location          = {
                    full_destination_id = 'housing',
                    destination_id      = 'housing',
                    house_owner         = game.Players.LocalPlayer,
                },
                pet_progression   = {
                    age              = item.properties.age or math.random(1, 6),
                    friendship_level = item.properties.friendship_level or 1,
                    xp               = 0,
                    percentage       = math.random(0, 99) / 100,
                },
                are_colors_sealed = false,
                is_pet            = true,
                transform_mode    = 1,
            })
            addPetState({
                char = petModel,
                player = game.Players.LocalPlayer,
                store_key = 'pet_state_managers',
                is_sitting = false,
                chars_connected_to_me = {},
                states = {},
            })
            task.spawn(function()
                task.wait(0.3)
                AilmentsClient.on_ailments_changed(game.Players.LocalPlayer)
                task.wait(0.5)
                AilmentsClient.on_ailments_changed(game.Players.LocalPlayer)
            end)
        else
            return oldGet('ToolAPI/Equip'):InvokeServer(item.unique)
        end
    end

    local oldGet = router.get

    local function createRemoteFunctionMock(callback)
        return { InvokeServer = function(_, ...) return callback(...) end }
    end

    local function createRemoteEventMock(callback)
        return { FireServer = function(_, ...) return callback(...) end }
    end

    local equipRemote = createRemoteFunctionMock(function(uniqueId, metadata)
        local pet = pets[uniqueId]
        if pet then
            equip(pet.data)
            return true, { action = 'equip', is_server = true }
        end
        -- Not our fake pet: pass straight to server (covers toys, pet wear, real pets)
        return oldGet('ToolAPI/Equip'):InvokeServer(uniqueId, metadata)
    end)

    local unequipRemote = createRemoteFunctionMock(function(uniqueId)
        local pet = pets[uniqueId]
        if pet then
            unequip(pet.data)
            return true, { action = 'unequip', is_server = true }
        end
        -- Not our fake pet: pass to server (covers toys and real items)
        return oldGet('ToolAPI/Unequip'):InvokeServer(uniqueId)
    end)

    local rideRemote = createRemoteFunctionMock(function(item) ride(item.pet_unique) end)
    local flyRemote = createRemoteFunctionMock(function(item) fly(item.pet_unique) end)
    local unmountRemoteFunction = createRemoteFunctionMock(function()
        unmount(mountedPet) end)
    local unmountRemoteEvent = createRemoteEventMock(function() unmount(mountedPet)
    end)

    -- Build a smart equip remote that checks if the item is our fake pet
    -- before intercepting; toys and real pets fall through to the real server.
    local smartEquipRemote = createRemoteFunctionMock(function(uniqueId, metadata)
        if pets[uniqueId] then
            equip(pets[uniqueId].data)
            return true, { action = 'equip', is_server = true }
        end
        -- Toy or real pet: use the real server remote with full animation support
        return oldGet('ToolAPI/Equip'):InvokeServer(uniqueId, metadata)
    end)
    local smartUnequipRemote = createRemoteFunctionMock(function(uniqueId)
        if pets[uniqueId] then
            unequip(pets[uniqueId].data)
            return true, { action = 'unequip', is_server = true }
        end
        return oldGet('ToolAPI/Unequip'):InvokeServer(uniqueId)
    end)

    router.get = function(name)
        if name == 'ToolAPI/Equip' then return smartEquipRemote
        elseif name == 'ToolAPI/Unequip' then return smartUnequipRemote
        elseif name == 'AdoptAPI/RidePet' then return rideRemote
        elseif name == 'AdoptAPI/FlyPet' then return flyRemote
        elseif name == 'AdoptAPI/ExitSeatStatesYield' then return unmountRemoteFunction
        elseif name == 'AdoptAPI/ExitSeatStates' then return unmountRemoteEvent
        elseif name == 'PetAPI/DoNeonFusion' or name == 'PetAPI/DoNeonFusionNormal' then
            return { InvokeServer = function(_, petUniques)
                local uids = {}
                if type(petUniques) == 'table' then
                    if #petUniques > 0 then uids = petUniques
                    else for _, v in pairs(petUniques) do table.insert(uids, v) end end
                end
                -- Only intercept if all 4 are our fake pets
                local allFake = #uids > 0
                for _, uid in ipairs(uids) do
                    if not pets[uid] then allFake = false; break end
                end
                if not allFake then return oldGet(name):InvokeServer(petUniques) end
                -- Validate: all same kind, same tier
                local first = pets[uids[1]].data
                local isNeon = first.properties.neon == true
                local isNorm = not isNeon and not (first.properties.mega_neon == true)
                for i = 2, 4 do
                    local p = pets[uids[i]].data
                    if p.kind ~= first.kind then warn('[NM] Fusion: species mismatch'); return nil, nil end
                    local pNeon = p.properties.neon == true
                    local pNorm = not pNeon and not (p.properties.mega_neon == true)
                    if isNeon and not pNeon then warn('[NM] Fusion: need all Neon'); return nil, nil end
                    if isNorm and not pNorm then warn('[NM] Fusion: need all Normal'); return nil, nil end
                end
                -- Remove old pets
                for _, uid in ipairs(uids) do
                    local p = pets[uid]
                    if p and p.model then
                        if mountedPet == uid then unmount(uid) end
                        removePetWrapper(uid); removePetState(uid)
                        p.model:Destroy(); p.model = nil
                    end
                    pets[uid] = nil
                end
                local inv = clientData.get('inventory')
                for _, uid in ipairs(uids) do
                    if inv.pets then inv.pets[uid] = nil end
                end
                -- Create fused pet
                local newProps = {
                    pet_trick_level = 5,
                    age = first.properties.age or 6,
                    ailments_completed = 0,
                    rideable = first.properties.rideable or false,
                    flyable  = first.properties.flyable  or false,
                    rp_name  = first.properties.rp_name  or '',
                }
                if isNeon then newProps.mega_neon = true; newProps.neon = false
                else newProps.neon = true; newProps.mega_neon = false end
                local newPet = createPet(first.id, newProps)
                if not newPet then return nil, nil end
                print('[NM] Fusion OK: ' .. tostring(newPet.unique))
                -- doNeonFusion (called below via routerClientUpvalue proxy) handles equip
                return newPet.unique, first.kind
            end }
        end
        return oldGet(name)
    end

    for _, charWrapper in pairs(clientData.get('pet_char_wrappers')) do
        oldGet('ToolAPI/Unequip'):InvokeServer(charWrapper.pet_unique)
    end

    -- Fusion: our fake pets don't exist server-side so we handle it locally.
    -- We DON'T define doNeonFusion yet ? we simply intercept the remote call
    -- and create the fused pet client-side instead of calling the server.
    local function doNeonFusion(petUniques)
        if #petUniques ~= 4 then return nil, nil end
        local fakePets = {}
        for _, uid in ipairs(petUniques) do
            if not pets[uid] then return nil, nil end
            table.insert(fakePets, pets[uid])
        end
        local first = fakePets[1].data
        local isNeon = first.properties.neon == true
        local isNormal = not isNeon and not (first.properties.mega_neon == true)
        for i = 2, 4 do
            local p = fakePets[i].data
            if p.kind ~= first.kind then return nil, nil end
            local pNeon = p.properties.neon == true
            local pNorm = not pNeon and not (p.properties.mega_neon == true)
            if isNeon   and not pNeon then return nil, nil end
            if isNormal and not pNorm then return nil, nil end
        end
        -- Remove old pets
        for _, uid in ipairs(petUniques) do
            local p = pets[uid]
            if p and p.model then
                p.model:Destroy(); p.model = nil
            end
            local inv = clientData.get('inventory')
            if inv.pets then inv.pets[uid] = nil end
            pets[uid] = nil
        end
        -- Create fused pet
        local newProps = {
            pet_trick_level = 5,
            age = first.properties.age or 6,
            ailments_completed = 0,
            rideable = first.properties.rideable or false,
            flyable  = first.properties.flyable  or false,
            rp_name  = first.properties.rp_name  or '',
        }
        if isNeon then
            newProps.mega_neon = true; newProps.neon = false
        else
            newProps.neon = true; newProps.mega_neon = false
        end
        local newPet = createPet(first.id, newProps)
        if not newPet then return nil, nil end
        print('[NM] Fusion OK: ' .. tostring(newPet.unique))

        -- Equip once, then float the model above the player and let it fall
        task.defer(function()
            equip(newPet)
            -- Wait one frame for the model to be parented into workspace
            task.wait()
            local pet = pets[newPet.unique]
            if not pet or not pet.model then return end
            local model = pet.model

            -- Position the pet ~12 studs above the character's root
            local char = game.Players.LocalPlayer.Character
            local rootPos = char and char.PrimaryPart and char.PrimaryPart.Position
                            or Vector3.new(0, 10, 0)
            local spawnPos = rootPos + Vector3.new(0, 12, 0)
            model:PivotTo(CFrame.new(spawnPos))

            -- Make every BasePart physical so gravity pulls it down
            local parts = {}
            for _, part in ipairs(model:GetDescendants()) do
                if part:IsA('BasePart') then
                    parts[#parts + 1] = part
                    part.Anchored = false
                end
            end

            -- Apply a small upward impulse for a gentle float-then-fall arc
            for _, part in ipairs(parts) do
                pcall(function()
                    part:ApplyImpulse(Vector3.new(
                        math.random(-2, 2),
                        part.AssemblyMass * 8,  -- light upward kick
                        math.random(-2, 2)
                    ))
                end)
            end

            -- After the pet lands (~1.4 s), re-anchor so it stays put normally
            task.wait(1.4)
            for _, part in ipairs(parts) do
                pcall(function() part.Anchored = true end)
            end
        end)

        return newPet.unique, first.kind
    end

    -- Hook the fusion remote in routerClientUpvalue so cave calls are intercepted
    pcall(function()
        local fusionKey = 'PetAPI/DoNeonFusion'
        local realRemote = routerClientUpvalue[fusionKey]
        if not realRemote then return end
        -- Replace with a proxy table whose InvokeServer runs doNeonFusion
        routerClientUpvalue[fusionKey] = setmetatable({}, {
            __index = function(_, key)
                if key == 'InvokeServer' then
                    return function(_, arg, ...)
                        local uids = {}
                        if type(arg) == 'table' then
                            if #arg > 0 then uids = arg
                            else for _, v in pairs(arg) do table.insert(uids, v) end end
                        end
                        local anyFake = false
                        for _, uid in ipairs(uids) do
                            if pets[uid] then anyFake = true; break end
                        end
                        if anyFake then
                            print('[NM] Fusion intercepted')
                            return doNeonFusion(uids)
                        end
                        return realRemote:InvokeServer(arg, ...)
                    end
                end
                return realRemote[key]
            end
        })
        print('[NM] Fusion remote proxied in routerClientUpvalue V')
    end)


    local Loads = require(game.ReplicatedStorage.Fsys).load
    local InventoryDB = Loads('InventoryDB')

    function GetPetByName(name)
        for i, v in pairs(InventoryDB.pets) do
            if v.name:lower() == name:lower() then return v.id end
        end
        return false
    end

    function GetToyByName(name)
        for i, v in pairs(InventoryDB.toys) do
            if v.name:lower() == name:lower() then return v.id end
        end
        return false
    end

    local friendshipEnabled = true

    local function renamePet(uniqueId, newName)
        local pet = pets[uniqueId]
        if not pet then return end
        newName = newName or ''
        pet.data.properties.rp_name = newName

        -- Remove the current wrapper then re-add it with the updated rp_name.
        -- This forces PlayerNameApp through its full registration path so the
        -- label above the pet re-renders with the new name.
        removePetWrapper(uniqueId)
        addPetWrapper({
            char              = pet.model,
            mega_neon         = pet.data.properties.mega_neon,
            neon              = pet.data.properties.neon,
            player            = game.Players.LocalPlayer,
            entity_controller = game.Players.LocalPlayer,
            controller        = game.Players.LocalPlayer,
            rp_name           = newName,
            pet_trick_level   = pet.data.properties.pet_trick_level or 0,
            friendship_level  = pet.data.properties.friendship_level or 1,
            ailments_completed = 999,
            pet_unique        = uniqueId,
            pet_id            = pet.data.id,
            location          = {
                full_destination_id = 'housing',
                destination_id      = 'housing',
                house_owner         = game.Players.LocalPlayer,
            },
            pet_progression   = {
                age              = pet.data.properties.age or 6,
                friendship_level = pet.data.properties.friendship_level or 1,
                xp               = 0,
                percentage       = 0,
            },
            are_colors_sealed = false,
            is_pet            = true,
            transform_mode    = 1,
        })
    end

    -- Pet Wear spawning function
    local function createPetWear(id)
        local uniqueId = getUniqueId()
        -- pet wear items may not be in KindDB; look up kind from InventoryDB directly
        local Loads2 = require(game.ReplicatedStorage.Fsys).load
        local IDB2 = nil
        pcall(function() IDB2 = Loads2('InventoryDB') end)
        local kind = id  -- fallback: use id as kind
        if IDB2 then
            for _, tbl in ipairs({IDB2.pet_wear, IDB2.pet_accessories, IDB2.accessories, IDB2.clothing}) do
                if tbl and tbl[id] then kind = tbl[id].kind or id; break end
                if tbl then
                    for _, v in pairs(tbl) do
                        if v.id == id then kind = v.kind or id; break end
                    end
                end
            end
        end
        set_thread_identity(2)
        local new_wear = {
            unique        = uniqueId,
            category      = 'pet_wear',
            id            = id,
            kind          = kind,
            newness_order = math.random(1, 900000),
            properties    = {},
        }
        local inv = clientData.get('inventory')
        if not inv.pet_wear        then inv.pet_wear        = {} end
        if not inv.pet_accessories then inv.pet_accessories = {} end
        inv.pet_wear[uniqueId]        = new_wear
        inv.pet_accessories[uniqueId] = new_wear
        set_thread_identity(8)
        return new_wear
    end

    function GetPetWearByName(name)
        local lname = name:lower()
        for _, tbl in ipairs({InventoryDB.pet_wear, InventoryDB.pet_accessories,
                               InventoryDB.accessories, InventoryDB.clothing}) do
            if tbl then
                for i, v in pairs(tbl) do
                    if v.name and v.name:lower() == lname then return v.id end
                end
            end
        end
        return false
    end

    -- ----------------------------------------------------------------
    -- DressUp rename hook
    -- Watches for the DressUpApp UI to open and injects a rename
    -- TextBox above each spawned pet's entry so you can rename directly
    -- from the Dress Up menu without using the GUI tab.
    -- ----------------------------------------------------------------
    task.spawn(function()
        -- Wait for the DressUpApp to exist in UIManager
        local DressUpApp = nil
        local attempts = 0
        repeat
            task.wait(0.5)
            attempts = attempts + 1
            pcall(function() DressUpApp = UIManager.apps.DressUpApp end)
        until DressUpApp or attempts > 30

        if not DressUpApp then return end

        local function injectRenameIntoFrame(frame, uniqueId)
            -- Don't double-inject
            if frame:FindFirstChild("NM_RenameBox") then return end

            local pet = pets[uniqueId]
            if not pet then return end

            local box = Instance.new("TextBox")
            box.Name            = "NM_RenameBox"
            box.Size            = UDim2.new(1, -8, 0, 22)
            box.Position        = UDim2.new(0, 4, 0, -26)
            box.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
            box.BackgroundTransparency = 0.1
            box.TextColor3      = Color3.fromRGB(240, 240, 255)
            box.PlaceholderColor3 = Color3.fromRGB(140, 135, 165)
            box.Font            = Enum.Font.FredokaOne
            box.TextSize        = 13
            box.PlaceholderText = "Rename pet..."
            box.Text            = pet.data.properties.rp_name or ""
            box.ClearTextOnFocus = false
            box.ZIndex          = frame.ZIndex + 5
            box.Parent          = frame

            local ts = Instance.new("UIStroke")
            ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
            ts.Color = Color3.new(0,0,0); ts.Thickness = 1.5; ts.Parent = box
            local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0,5); c.Parent = box

            -- Confirm rename on FocusLost
            box.FocusLost:Connect(function(enterPressed)
                if enterPressed or box.Text ~= "" then
                    local newName = ""
                    -- auto-capitalise
                    local capitalizeNext = true
                    for i = 1, #box.Text do
                        local ch = box.Text:sub(i,i)
                        if ch == " " then capitalizeNext = true; newName = newName..ch
                        elseif capitalizeNext then newName = newName..ch:upper(); capitalizeNext = false
                        else newName = newName..ch:lower() end
                    end
                    box.Text = newName
                    renamePet(uniqueId, newName)
                end
            end)
        end

        -- Scan the DressUpApp's GUI tree for frames that correspond to spawned pets
        local function scanForPetFrames(root)
            if not root then return end
            for _, desc in ipairs(root:GetDescendants()) do
                -- Pet entry frames typically have an Attribute or Name containing the unique id
                -- Try reading pet_unique attribute first, then check Name against our pets table
                local uid = nil
                pcall(function() uid = desc:GetAttribute("pet_unique") end)
                if not uid then
                    -- Fallback: check if the frame name is a GUID-like key in our pets table
                    if desc:IsA("Frame") and pets[desc.Name] then
                        uid = desc.Name
                    end
                end
                if uid and pets[uid] and desc:IsA("Frame") then
                    injectRenameIntoFrame(desc, uid)
                end
            end
        end

        -- Re-scan every time DressUpApp visibility changes or new descendants are added
        local function onDressUpOpened()
            task.wait(0.25) -- let the app finish rendering
            local root = nil
            pcall(function()
                root = DressUpApp.frame or DressUpApp._frame or DressUpApp.gui
            end)
            -- Also search PlayerGui directly
            if not root then
                pcall(function()
                    root = LocalPlayer.PlayerGui:FindFirstChild("DressUpApp", true)
                            or LocalPlayer.PlayerGui:FindFirstChild("DressUp", true)
                end)
            end
            if root then scanForPetFrames(root) end
        end

        -- Hook visibility / open calls if available
        if DressUpApp.on_open then
            local orig = DressUpApp.on_open
            DressUpApp.on_open = function(...)
                local r = orig(...)
                onDressUpOpened()
                return r
            end
        end

        -- Also watch PlayerGui for the DressUp ScreenGui appearing
        LocalPlayer.PlayerGui.ChildAdded:Connect(function(child)
            if child.Name:find("DressUp") or child.Name:find("Dress") then
                onDressUpOpened()
            end
        end)

        -- Poll as a fallback every 2s while pets exist
        task.spawn(function()
            while true do
                task.wait(2)
                if next(pets) then onDressUpOpened() end
            end
        end)
    end)

    -- Expose for GUI buttons
    _G.__NM_INTERNAL = {
        SC               = { pets = pets, equippedPet = nil },  -- equippedPet kept in sync below
        createPet        = createPet,
        createToy        = createToy,
        createPetWear    = createPetWear,
        GetPetByName     = GetPetByName,
        GetToyByName     = GetToyByName,
        GetPetWearByName = GetPetWearByName,
        renamePet        = renamePet,
        getFriendshipEnabled = function() return friendshipEnabled end,
        setFriendshipEnabled = function(v) friendshipEnabled = v end,
    }

    -- Keep SC.equippedPet in sync so the GUI rename button can read it directly
    local _origEquip = equip
    equip = function(item)
        _origEquip(item)
        if _G.__NM_INTERNAL then
            _G.__NM_INTERNAL.SC.equippedPet = equippedPet
        end
    end
    local _origUnequip = unequip
    unequip = function(item)
        _origUnequip(item)
        if _G.__NM_INTERNAL then
            _G.__NM_INTERNAL.SC.equippedPet = nil
        end
    end
    _G.NM_READY = true
    print("[OK] NeonMaker pet system loaded")
end)


-- Auto-capitalize helper function
local function autoCapitalize(text)
   if not text or text == "" then
       return text
   end

   local result = ""
   local capitalizeNext = true

   for i = 1, #text do
       local char = text:sub(i, i)
       if char == " " then
           capitalizeNext = true
           result = result .. char
       elseif capitalizeNext then
           result = result .. char:upper()
           capitalizeNext = false
       else
           result = result .. char:lower()
       end
   end

   return result
end

-- ================================================================
-- GUI  ?  prada style with RGB border
-- ================================================================

local playerGui = LocalPlayer:WaitForChild("PlayerGui")
if playerGui:FindFirstChild("NM_Spawner") then playerGui.NM_Spawner:Destroy() end

local SG = Instance.new("ScreenGui")
SG.Name           = "NM_Spawner"
SG.ResetOnSpawn   = false
SG.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
SG.Parent         = playerGui

local FONT = Enum.Font.FredokaOne

local C = {
    bg     = Color3.fromRGB(30, 30, 40),
    panel  = Color3.fromRGB(50, 50, 65),
    input  = Color3.fromRGB(40, 40, 50),
    purple = Color3.fromRGB(170, 0, 255),
    blue   = Color3.fromRGB(0, 100, 200),
    green  = Color3.fromRGB(0, 200, 100),
    pink   = Color3.fromRGB(255, 50, 150),
    orange = Color3.fromRGB(200, 100, 0),
    text   = Color3.fromRGB(240, 240, 255),
    sub    = Color3.fromRGB(160, 155, 185),
    border = Color3.fromRGB(255, 255, 255),
}

local VALID   = Color3.fromRGB(120, 255, 150)
local INVALID = Color3.fromRGB(255, 120, 120)
local NEUTRAL = Color3.fromRGB(220, 220, 255)

local function corner(p, r)
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 8); c.Parent = p
end
local function stroke(p, col, th, tr)
    local s = Instance.new("UIStroke")
    s.Color = col or C.border; s.Thickness = th or 1.5; s.Transparency = tr or 0; s.Parent = p
end
local function strokeCtx(p, col, th)
    local s = Instance.new("UIStroke")
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
    s.Color = col or Color3.new(0,0,0); s.Thickness = th or 1.5; s.Transparency = 0; s.Parent = p
end
local function label(p, txt, size, col, xAlign)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1; l.Font = FONT; l.Text = txt
    l.TextSize = size or 14; l.TextColor3 = col or C.text
    l.TextXAlignment = xAlign or Enum.TextXAlignment.Center
    local ls = Instance.new("UIStroke")
    ls.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
    ls.Color = Color3.new(0,0,0); ls.Thickness = 1.5; ls.Transparency = 0; ls.Parent = l
    l.Parent = p; return l
end

-- ?? window dimensions ?????????????????????????????????????????????
local W, H = 330, 460

-- shadow frame
local shadowFrame = Instance.new("Frame")
shadowFrame.Name = "Shadow"
shadowFrame.Size = UDim2.new(0, W+10, 0, H+10)
shadowFrame.BackgroundColor3 = Color3.new(0,0,0)
shadowFrame.BackgroundTransparency = 0
shadowFrame.BorderSizePixel = 0
shadowFrame.ZIndex = 0
shadowFrame.Parent = SG
corner(shadowFrame, 15)

-- main frame
local win = Instance.new("Frame")
win.Name             = "Win"
win.Size             = UDim2.new(0, W, 0, H)
win.Position         = UDim2.new(0.5, -W/2, 0.5, -H/2)
win.BackgroundColor3 = C.bg
win.BorderSizePixel  = 0
win.ZIndex           = 1
win.Parent           = SG
corner(win, 10)

-- RGB border stroke
local rgbStroke = Instance.new("UIStroke")
rgbStroke.Color     = C.purple
rgbStroke.Thickness = 3
rgbStroke.Transparency = 0
rgbStroke.Parent    = win

-- shadow follows window
win:GetPropertyChangedSignal("Position"):Connect(function()
    shadowFrame.Position = UDim2.new(
        win.Position.X.Scale, win.Position.X.Offset - 5,
        win.Position.Y.Scale, win.Position.Y.Offset - 5)
end)
shadowFrame.Position = UDim2.new(0.5, -W/2-5, 0.5, -H/2-5)

-- RGB animation
local rgbPalette = {
    Color3.fromRGB(170, 0,   255),
    Color3.fromRGB(120, 0,   255),
    Color3.fromRGB(0,   100, 255),
    Color3.fromRGB(0,   200, 255),
    Color3.fromRGB(0,   255, 150),
    Color3.fromRGB(0,   255, 100),
    Color3.fromRGB(255, 100, 0  ),
    Color3.fromRGB(255, 50,  150),
}
local rgbIdx = 1
local function cycleRGB()
    rgbIdx = rgbIdx % #rgbPalette + 1
    TweenService:Create(rgbStroke, TweenInfo.new(4, Enum.EasingStyle.Linear), {Color = rgbPalette[rgbIdx]}):Play()
    task.wait(4)
    cycleRGB()
end
task.spawn(cycleRGB)

-- ?? header ????????????????????????????????????????????????????????
local hdr = Instance.new("Frame")
hdr.Size             = UDim2.new(1, 0, 0, 38)
hdr.BackgroundColor3 = C.panel
hdr.BorderSizePixel  = 0
hdr.Parent           = win
corner(hdr, 10)
local hdrFill = Instance.new("Frame")
hdrFill.Size = UDim2.new(1,0,0,14); hdrFill.Position = UDim2.new(0,0,1,-14)
hdrFill.BackgroundColor3 = C.panel; hdrFill.BorderSizePixel = 0; hdrFill.Parent = hdr

local titleLbl = label(hdr, "neonmaker - oscarkz649", 15, C.text, Enum.TextXAlignment.Left)
titleLbl.Size = UDim2.new(1,-70,1,0); titleLbl.Position = UDim2.new(0,12,0,0)
strokeCtx(titleLbl, Color3.new(0,0,0), 1.2)

-- pet counter shown in header
local counterLbl = label(hdr, "pets: 0", 11, C.sub, Enum.TextXAlignment.Left)
counterLbl.Size = UDim2.new(0,60,0,14); counterLbl.Position = UDim2.new(0,12,1,-16)
strokeCtx(counterLbl, Color3.new(0,0,0), 1.2)
local spawnedCount = 0
local function bumpCounter(delta)
    spawnedCount = math.max(0, spawnedCount + delta)
    counterLbl.Text = "pets: "..spawnedCount
end

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.new(0,24,0,24); minBtn.Position = UDim2.new(1,-60,0,7)
minBtn.Text = "-"; minBtn.Font = FONT; minBtn.TextSize = 16
minBtn.TextColor3 = Color3.fromRGB(220,220,100)
minBtn.BackgroundColor3 = Color3.fromRGB(50,50,20); minBtn.BackgroundTransparency = 0.3
minBtn.BorderSizePixel = 0; minBtn.Parent = hdr
corner(minBtn, 6)
strokeCtx(minBtn, Color3.new(0,0,0), 1.5)

local minimized = false
local fullH = H
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    local targetH = minimized and 38 or fullH
    TweenService:Create(win, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        {Size = UDim2.new(0, W, 0, targetH)}):Play()
    minBtn.Text = minimized and "+" or "-"
end)
local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0,24,0,24); closeBtn.Position = UDim2.new(1,-32,0,7)
closeBtn.Text = "x"; closeBtn.Font = FONT; closeBtn.TextSize = 14
closeBtn.TextColor3 = Color3.fromRGB(255,100,100)
closeBtn.BackgroundColor3 = Color3.fromRGB(60,30,30); closeBtn.BackgroundTransparency = 0.3
closeBtn.BorderSizePixel = 0; closeBtn.Parent = hdr
corner(closeBtn, 6)
strokeCtx(closeBtn, Color3.new(0,0,0), 1.5)
closeBtn.MouseButton1Click:Connect(function()
    TweenService:Create(win, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
        {Size=UDim2.new(0,0,0,0), Position=UDim2.new(0.5,0,0.5,0)}):Play()
    task.delay(0.25, function() SG:Destroy() end)
end)

-- ?? tab bar ???????????????????????????????????????????????????????
local tabY = 44
local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1,-16,0,28); tabBar.Position = UDim2.new(0,8,0,tabY)
tabBar.BackgroundTransparency = 1; tabBar.Parent = win

local TAB_NAMES = {"Pets","Toys"}
local tabs, contents = {}, {}

for i, name in ipairs(TAB_NAMES) do
    local tb = Instance.new("TextButton")
    tb.Size = UDim2.new(1/#TAB_NAMES,-3,1,0)
    tb.Position = UDim2.new((i-1)*(1/#TAB_NAMES), i==1 and 0 or 3, 0, 0)
    tb.Text = name; tb.Font = FONT; tb.TextSize = 15
    tb.TextColor3 = C.text
    tb.BackgroundColor3 = Color3.fromRGB(60,60,80); tb.BackgroundTransparency = 0.1
    tb.BorderSizePixel = 0; tb.Parent = tabBar
    corner(tb, 6)
    local tts = Instance.new("UIStroke")
    tts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
    tts.Color = Color3.new(0,0,0); tts.Thickness = 1.5; tts.Transparency = 0; tts.Parent = tb
    tabs[i] = tb

    local ct = Instance.new("Frame")
    ct.Size = UDim2.new(1,-16,0, H-tabY-36)
    ct.Position = UDim2.new(0,8,0,tabY+34)
    ct.BackgroundTransparency = 1; ct.Visible = (i==1); ct.Parent = win
    contents[i] = ct
end

local function activateTab(idx)
    for i,tb in ipairs(tabs) do
        tb.BackgroundColor3 = i==idx and Color3.fromRGB(80,80,100) or Color3.fromRGB(60,60,80)
        contents[i].Visible = (i==idx)
    end
end
for i,tb in ipairs(tabs) do tb.MouseButton1Click:Connect(function() activateTab(i) end) end
activateTab(1)

-- ?? widget helpers ????????????????????????????????????????????????
local function makeInput(parent, yOff, placeholder)
    local box = Instance.new("TextBox")
    box.Size = UDim2.new(1,0,0,28); box.Position = UDim2.new(0,0,0,yOff)
    box.BackgroundColor3 = C.input; box.BackgroundTransparency = 0.2
    box.TextColor3 = C.text; box.PlaceholderColor3 = C.sub
    box.Font = FONT; box.TextSize = 14
    box.PlaceholderText = placeholder; box.Text = ""; box.ClearTextOnFocus = false
    box.Parent = parent
    corner(box, 6)
    -- single UIStroke: Contextual = black text outline; also tweened for input validation glow
    local bg = Instance.new("UIStroke")
    bg.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
    bg.Color = Color3.new(0,0,0); bg.Thickness = 1.5; bg.Transparency = 0; bg.Parent = box
    return box, bg
end

local function makeBtn(parent, yOff, h, txt, bg)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1,0,0,h); b.Position = UDim2.new(0,0,0,yOff)
    b.Text = txt; b.Font = FONT; b.TextSize = 15
    b.TextColor3 = C.text; b.BackgroundColor3 = bg or C.blue
    b.BackgroundTransparency = 0.1; b.BorderSizePixel = 0; b.Parent = parent
    corner(b, 8)
    -- single UIStroke in Contextual mode = black outline on the text glyphs
    local ts = Instance.new("UIStroke")
    ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
    ts.Color = Color3.new(0,0,0); ts.Thickness = 1.5; ts.Transparency = 0; ts.Parent = b
    b.MouseEnter:Connect(function() TweenService:Create(b,TweenInfo.new(0.1),{BackgroundTransparency=0}):Play() end)
    b.MouseLeave:Connect(function() TweenService:Create(b,TweenInfo.new(0.1),{BackgroundTransparency=0.1}):Play() end)
    return b
end

local function sectionLabel(parent, yOff, txt)
    local l = label(parent, txt, 11, C.sub, Enum.TextXAlignment.Left)
    l.Size = UDim2.new(1,0,0,13); l.Position = UDim2.new(0,2,0,yOff)
    return l
end

local function divider(parent, yOff)
    local d = Instance.new("Frame")
    d.Size = UDim2.new(1,0,0,1); d.Position = UDim2.new(0,0,0,yOff)
    d.BackgroundColor3 = Color3.fromRGB(80,80,100); d.BackgroundTransparency = 0.4
    d.BorderSizePixel = 0; d.Parent = parent
end

-- ================================================================
-- PET TAB
-- ================================================================
local PC = contents[1]

-- pet name input
sectionLabel(PC, 0, "Pet Name")
local petInput, petGlow = makeInput(PC, 14, "Enter Pet Name to Spawn")
local gwTween
local function setGlow(col)
    if gwTween then gwTween:Cancel() end
    gwTween = TweenService:Create(petGlow, TweenInfo.new(0.8, Enum.EasingStyle.Quad), {Color=col}); gwTween:Play()
end
setGlow(NEUTRAL)

petInput:GetPropertyChangedSignal("Text"):Connect(function()
    local cur = petInput.CursorPosition
    local raw = petInput.Text
    local cap = autoCapitalize(raw)
    if cap ~= raw then petInput.Text = cap; petInput.CursorPosition = cur; return end
    if raw == "" then setGlow(NEUTRAL); return end
    local found = false
    if _G.NM_READY and _G.__NM_INTERNAL then found = _G.__NM_INTERNAL.GetPetByName(raw) ~= false end
    setGlow(found and VALID or INVALID)
end)

-- age row
sectionLabel(PC, 52, "Age")
local ageRow = Instance.new("Frame")
ageRow.Size = UDim2.new(1,0,0,25); ageRow.Position = UDim2.new(0,0,0,66)
ageRow.BackgroundTransparency = 1; ageRow.Parent = PC

local AGES = {"Newborn","Junior","Pre-Teen","Teen","Post-Teen","Full Grown"}
local selAge = 1
local ageBtns = {}
for i, age in ipairs(AGES) do
    local ab = Instance.new("TextButton")
    ab.Size = UDim2.new(1/#AGES,-2,1,0)
    ab.Position = UDim2.new((i-1)/#AGES,1,0,0)
    ab.Text = age:sub(1,1); ab.Font = FONT; ab.TextSize = 12
    ab.TextColor3 = C.text
    ab.BackgroundColor3 = i==1 and Color3.fromRGB(80,80,100) or Color3.fromRGB(50,50,60)
    ab.BackgroundTransparency = 0.1; ab.BorderSizePixel = 0; ab.Parent = ageRow
    corner(ab, 4)
    strokeCtx(ab, Color3.new(0,0,0), 1.5)
    local tip = label(ab, age, 10, C.text)
    tip.Size = UDim2.new(0,64,0,18); tip.Position = UDim2.new(0.5,-32,-1.1,0)
    tip.BackgroundColor3 = C.panel; tip.BackgroundTransparency = 0.1
    tip.Visible = false; tip.ZIndex = 10
    corner(tip,4); stroke(tip, Color3.fromRGB(80,80,100), 1, 0.4)
    ab.MouseEnter:Connect(function() tip.Visible = true end)
    ab.MouseLeave:Connect(function() tip.Visible = false end)
    ab.MouseButton1Click:Connect(function()
        selAge = i
        for j,b in ipairs(ageBtns) do
            b.BackgroundColor3 = j==i and Color3.fromRGB(80,80,100) or Color3.fromRGB(50,50,60)
        end
    end)
    ageBtns[i] = ab
end

-- flags (M N F R)
sectionLabel(PC, 101, "Properties")
local flagRow = Instance.new("Frame")
flagRow.Size = UDim2.new(1,0,0,26); flagRow.Position = UDim2.new(0,0,0,115)
flagRow.BackgroundTransparency = 1; flagRow.Parent = PC

local flagColors = {
    M = Color3.fromRGB(170, 0,   255),
    N = Color3.fromRGB(0,   255, 100),
    F = Color3.fromRGB(0,   200, 255),
    R = Color3.fromRGB(255, 50,  150),
}
local FLAGS = {
    {k="M", lbl="Mega"},
    {k="N", lbl="Neon"},
    {k="F", lbl="Fly" },
    {k="R", lbl="Ride"},
}
local activeFlags = {M=false,N=false,F=false,R=false}
local fBtns = {}
for i, f in ipairs(FLAGS) do
    local fb = Instance.new("TextButton")
    fb.Size = UDim2.new(0.23,-2,1,0)
    fb.Position = UDim2.new((i-1)*0.25,1,0,0)
    fb.Text = f.lbl; fb.Font = FONT; fb.TextSize = 13
    fb.TextColor3 = C.text
    fb.BackgroundColor3 = Color3.fromRGB(60,60,70); fb.BackgroundTransparency = 0.2
    fb.BorderSizePixel = 0; fb.Parent = flagRow
    corner(fb, 6)
    local fs = Instance.new("UIStroke")
    fs.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
    fs.Color = Color3.new(0,0,0); fs.Thickness = 1.5; fs.Transparency = 0; fs.Parent = fb
    fb.MouseButton1Click:Connect(function()
        if f.k=="M" and activeFlags.N then return end
        if f.k=="N" and activeFlags.M then return end
        activeFlags[f.k] = not activeFlags[f.k]
        local on = activeFlags[f.k]
        fb.BackgroundColor3 = on and Color3.fromRGB(100,100,100) or Color3.fromRGB(60,60,70)
        TweenService:Create(fb, TweenInfo.new(0.3), {
            TextColor3  = on and flagColors[f.k] or C.text,
        }):Play()
    end)
    fBtns[f.k] = fb
end

divider(PC, 150)

-- friendship level selector
sectionLabel(PC, 155, "Friendship Level (1-999)")

local selFriendship = 1

-- Custom input box for any friendship value
local friendInputRow = Instance.new("Frame")
friendInputRow.Size = UDim2.new(1,0,0,26); friendInputRow.Position = UDim2.new(0,0,0,169)
friendInputRow.BackgroundTransparency = 1; friendInputRow.Parent = PC

local friendCustomInput = Instance.new("TextBox")
friendCustomInput.Size = UDim2.new(0.56,-3,1,0); friendCustomInput.Position = UDim2.new(0,0,0,0)
friendCustomInput.BackgroundColor3 = C.input; friendCustomInput.BackgroundTransparency = 0.2
friendCustomInput.TextColor3 = C.text; friendCustomInput.PlaceholderColor3 = C.sub
friendCustomInput.Font = FONT; friendCustomInput.TextSize = 14
friendCustomInput.PlaceholderText = "Custom value"; friendCustomInput.Text = "1"
friendCustomInput.ClearTextOnFocus = false; friendCustomInput.Parent = friendInputRow
corner(friendCustomInput, 6)
local friendInputCtxStroke = Instance.new("UIStroke")
friendInputCtxStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
friendInputCtxStroke.Color = Color3.new(0,0,0); friendInputCtxStroke.Thickness = 1.5
friendInputCtxStroke.Transparency = 0; friendInputCtxStroke.Parent = friendCustomInput

friendCustomInput:GetPropertyChangedSignal("Text"):Connect(function()
    local n = tonumber(friendCustomInput.Text)
    if n and n >= 1 then
        selFriendship = math.floor(n)
        friendInputStroke.Color = Color3.fromRGB(100,255,140)
    else
        friendInputStroke.Color = Color3.fromRGB(255,100,100)
    end
end)

-- Quick preset buttons: 1 2 3 4 5 6 ?
local friendRow = Instance.new("Frame")
friendRow.Size = UDim2.new(0.44,-2,1,0); friendRow.Position = UDim2.new(0.56,3,0,0)
friendRow.BackgroundTransparency = 1; friendRow.Parent = friendInputRow

local friendBtns = {}
for i = 1, 6 do
    local fb = Instance.new("TextButton")
    fb.Size = UDim2.new(1/7,-1,1,0)
    fb.Position = UDim2.new((i-1)/7,0,0,0)
    fb.Text = tostring(i); fb.Font = FONT; fb.TextSize = 12
    fb.TextColor3 = C.text
    fb.BackgroundColor3 = i==1 and Color3.fromRGB(180,50,90) or Color3.fromRGB(50,50,60)
    fb.BackgroundTransparency = 0.1; fb.BorderSizePixel = 0; fb.Parent = friendRow
    corner(fb, 4)
    stroke(fb, Color3.fromRGB(255,100,140), 1.2, i==1 and 0.2 or 0.7)
    strokeCtx(fb, Color3.new(0,0,0), 1.5)
    fb.MouseButton1Click:Connect(function()
        selFriendship = i
        friendCustomInput.Text = tostring(i)
        for j, b in ipairs(friendBtns) do
            b.BackgroundColor3 = j==i and Color3.fromRGB(180,50,90) or Color3.fromRGB(50,50,60)
            local s = b:FindFirstChildWhichIsA("UIStroke")
            if s and s.ApplyStrokeMode == Enum.ApplyStrokeMode.Border then
                TweenService:Create(s, TweenInfo.new(0.2), {Transparency = j==i and 0.2 or 0.7}):Play()
            end
        end
    end)
    friendBtns[i] = fb
end

-- random ?
local rndFriendBtn = Instance.new("TextButton")
rndFriendBtn.Size = UDim2.new(1/7,-1,1,0); rndFriendBtn.Position = UDim2.new(6/7,0,0,0)
rndFriendBtn.Text = "Rnd"; rndFriendBtn.Font = FONT; rndFriendBtn.TextSize = 12
rndFriendBtn.TextColor3 = C.text
rndFriendBtn.BackgroundColor3 = Color3.fromRGB(40,80,60); rndFriendBtn.BackgroundTransparency = 0.1
rndFriendBtn.BorderSizePixel = 0; rndFriendBtn.Parent = friendRow
corner(rndFriendBtn, 4)
stroke(rndFriendBtn, Color3.fromRGB(0,255,150), 1.2, 0.4)
strokeCtx(rndFriendBtn, Color3.new(0,0,0), 1.5)
rndFriendBtn.MouseButton1Click:Connect(function()
    local r = math.random(1,999)
    selFriendship = r
    friendCustomInput.Text = tostring(r)
    for j, b in ipairs(friendBtns) do
        b.BackgroundColor3 = j==r and Color3.fromRGB(180,50,90) or Color3.fromRGB(50,50,60)
        local s = b:FindFirstChildWhichIsA("UIStroke")
        if s and s.ApplyStrokeMode == Enum.ApplyStrokeMode.Border then
            TweenService:Create(s, TweenInfo.new(0.2), {Transparency = j==r and 0.2 or 0.7}):Play()
        end
    end
    rndFriendBtn.Text = "OK"
    task.delay(0.8, function() rndFriendBtn.Text = "Rnd" end)
end)

divider(PC, 204)

-- spawn + high tier buttons
local spawnBtn    = makeBtn(PC, 210, 28, "Spawn Pet",            C.blue)
local highTierBtn = makeBtn(PC, 244, 26, "Spawn All High Tier",  Color3.fromRGB(200,0,200))

divider(PC, 278)

-- friendship stack toggle
local ftBtn = makeBtn(PC, 284, 24, "Friendship Stack: ON", Color3.fromRGB(180,50,90))

divider(PC, 316)

-- rename row
sectionLabel(PC, 320, "Rename Equipped Pet")
local renRow = Instance.new("Frame")
renRow.Size = UDim2.new(1,0,0,26); renRow.Position = UDim2.new(0,0,0,334)
renRow.BackgroundTransparency = 1; renRow.Parent = PC
local renInput, _ = makeInput(renRow, 0, "New nickname")
renInput.Size = UDim2.new(0.68,-3,1,0)
local renBtn = makeBtn(renRow, 0, 26, "Rename", C.blue)
renBtn.Size = UDim2.new(0.32,-1,1,0); renBtn.Position = UDim2.new(0.68,2,0,0)

divider(PC, 368)

-- clear all spawned pets
local clearAllBtn = makeBtn(PC, 374, 26, "Clear All Spawned Pets", Color3.fromRGB(160,30,30))

-- ================================================================
-- TOY TAB
-- ================================================================
local TC = contents[2]
sectionLabel(TC, 0, "Toy Name")
local toyInput, toyGlow = makeInput(TC, 14, "Enter Toy Name to Spawn")
local tgTween
local function setToyGlow(col)
    if tgTween then tgTween:Cancel() end
    tgTween = TweenService:Create(toyGlow, TweenInfo.new(0.8, Enum.EasingStyle.Quad), {Color=col}); tgTween:Play()
end
setToyGlow(NEUTRAL)

toyInput:GetPropertyChangedSignal("Text"):Connect(function()
    local cur = toyInput.CursorPosition
    local raw = toyInput.Text; local cap = autoCapitalize(raw)
    if cap ~= raw then toyInput.Text = cap; toyInput.CursorPosition = cur; return end
    if raw == "" then setToyGlow(NEUTRAL); return end
    local found = false
    if _G.NM_READY and _G.__NM_INTERNAL then found = _G.__NM_INTERNAL.GetToyByName(raw) ~= false end
    setToyGlow(found and VALID or INVALID)
end)

local spawnToyBtn = makeBtn(TC, 54, 28, "Spawn Toy", C.orange)

-- (Pet Wear tab removed)

-- ================================================================
-- BUTTON LOGIC
-- ================================================================
local function waitForNM()
    local t = 0
    while not _G.NM_READY and t < 15 do task.wait(0.1); t = t+0.1 end
    return _G.NM_READY
end

local function notify(title, text, dur)
    game:GetService("StarterGui"):SetCore("SendNotification",
        {Title=title, Text=text, Duration=dur or 3})
end

-- spawn pet
spawnBtn.MouseButton1Click:Connect(function()
    local name = petInput.Text
    if name == "" then notify("Error","Enter a pet name."); return end
    if not waitForNM() then notify("Not ready","Pet system loading"); return end
    local nm = _G.__NM_INTERNAL
    local id = nm.GetPetByName(name)
    if not id then notify("Error","Pet not found: "..name); return end
    local pet = nm.createPet(id, {
        pet_trick_level  = 0,
        mega_neon        = activeFlags.M,
        neon             = (not activeFlags.M) and activeFlags.N or false,
        rideable         = activeFlags.R,
        flyable          = activeFlags.F,
        age              = selAge,
        ailments_completed = 999,
        rp_name          = "",
        friendship_level = selFriendship,
    })
    if pet then
        spawnBtn.Text = "Spawned!"
        task.delay(1.2, function() spawnBtn.Text = "Spawn Pet" end)
        notify("Spawned!", name.." (friendship "..selFriendship..")", 4)
        bumpCounter(1)
    end
end)

-- high tier
local highTierPets = {
    "Shadow Dragon","Bat Dragon","Frost Dragon","Giraffe","Owl","Parrot",
    "Crow","Evil Unicorn","Arctic Reindeer","Hedgehog","Dalmatian","Turtle",
    "Kangaroo","Lion","Cupid Dragon","Undead Jousting Horse","Diamond Amazon",
    "Glacier Moth","Cabbit","Sakura Spirit","Arctic Dusk Dragon","Elephant",
    "Dango Penguins","Cryptid","Jekyll Hydra","Chocolate Chip Bat Dragon",
    "Cow","Mermicorn","Vampire Dragon","Christmas Pudding Pup","Blazing Lion",
    "African Wild Dog","Flamingo","Diamond Butterfly","Mini Pig","Caterpillar",
    "Albino Monkey","Candyfloss Chick","Pelican","Blue Dog","Pink Cat","Haetae",
    "Peppermint Penguin","Winged Tiger","Sugar Glider","Shark Puppy","Goat",
    "Sheeeeep","Frost Fury","Lion Cub","Nessie","Frostbite Bear",
    "Balloon Unicorn","Honey Badger","Hot Doggo","Crocodile","Hare","Ram","Yeti",
    "Lava Dragon","Meerkat","Jellyfish","Orchid Butterfly","Many Mackerel",
    "Strawberry Shortcake Bat Dragon","Zombie Buffalo","Fairy Bat Dragon",
    "Giant Panda","Pirate Ghost Capuchin Monkey","Dragonfruit Fox",
    "Pineapple Owl","Siamese Cat","Owlbear","Arctic Fox",
}
highTierBtn.MouseButton1Click:Connect(function()
    if not waitForNM() then return end
    local nm = _G.__NM_INTERNAL
    highTierBtn.Text = "Spawning..."; highTierBtn.AutoButtonColor = false
    task.spawn(function()
        local count = 0
        for _, name in ipairs(highTierPets) do
            local id = nm.GetPetByName(name)
            if id then
                nm.createPet(id, {
                    pet_trick_level  = 0,
                    mega_neon        = activeFlags.M,
                    neon             = (not activeFlags.M) and activeFlags.N or false,
                    rideable         = activeFlags.R,
                    flyable          = activeFlags.F,
                    age              = selAge,
                    ailments_completed = 999,
                    rp_name          = "",
                    friendship_level = selFriendship,
                })
                count = count+1
            end
            task.wait()
        end
        highTierBtn.Text = "Spawn All High Tier"; highTierBtn.AutoButtonColor = true
        notify("Done!","Spawned "..count.." high-tier pets.",4)
        bumpCounter(count)
    end)
end)

-- friendship stack toggle
ftBtn.MouseButton1Click:Connect(function()
    if not _G.__NM_INTERNAL then return end
    local nm = _G.__NM_INTERNAL
    local now = not nm.getFriendshipEnabled()
    nm.setFriendshipEnabled(now)
    ftBtn.Text = "Friendship Stack: "..(now and "ON" or "OFF")
    ftBtn.BackgroundColor3 = now and Color3.fromRGB(180,50,90) or Color3.fromRGB(60,60,70)
end)

-- rename
renBtn.MouseButton1Click:Connect(function()
    if not _G.__NM_INTERNAL then return end
    local nm = _G.__NM_INTERNAL
    local eq = nm.SC.equippedPet
    if not eq then notify("No pet","Equip a spawned pet first."); return end
    local newName = autoCapitalize(renInput.Text)
    nm.renamePet(eq.unique, newName)
    renBtn.Text = "OK"; task.delay(1.2, function() renBtn.Text = "Rename" end)
    notify("Renamed!", eq.id.." -> "..newName, 3)
end)

-- spawn toy
spawnToyBtn.MouseButton1Click:Connect(function()
    local name = toyInput.Text
    if name == "" then notify("Error","Enter a toy name."); return end
    if not waitForNM() then return end
    local nm = _G.__NM_INTERNAL
    local id = nm.GetToyByName(name)
    if not id then notify("Error","Toy not found: "..name); return end
    if nm.createToy(id) then
        spawnToyBtn.Text = "Spawned!"
        task.delay(1.2, function() spawnToyBtn.Text = "Spawn Toy" end)
    end
end)

-- clear all spawned pets
clearAllBtn.MouseButton1Click:Connect(function()
    if not _G.__NM_INTERNAL then return end
    local nm = _G.__NM_INTERNAL
    local removed = 0
    -- collect keys first to avoid mutating while iterating
    local toRemove = {}
    for uid, _ in pairs(nm.SC.pets) do table.insert(toRemove, uid) end
    for _, uid in ipairs(toRemove) do
        local pet = nm.SC.pets[uid]
        if pet then
            pcall(function()
                local inv = require(game.ReplicatedStorage:WaitForChild("Fsys")).load("ClientData").get("inventory")
                inv.pets[uid] = nil
            end)
            if pet.model then
                pcall(function() pet.model:Destroy() end)
                pet.model = nil
            end
            nm.SC.pets[uid] = nil
            removed = removed + 1
        end
    end
    nm.SC.equippedPet = nil
    bumpCounter(-removed)
    notify("Cleared", "Removed "..removed.." spawned pet(s).", 3)
    clearAllBtn.Text = "Cleared!"
    task.delay(1.5, function() clearAllBtn.Text = "Clear All Spawned Pets" end)
end)

-- ?? drag (header only) ????????????????????????????????????????????
local dragging, dStart, dPos
hdr.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
        dragging = true; dStart = inp.Position; dPos = win.Position
        inp.Changed:Connect(function()
            if inp.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
hdr.InputChanged:Connect(function(inp)
    if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
        local d = inp.Position - dStart
        win.Position = UDim2.new(dPos.X.Scale, dPos.X.Offset+d.X, dPos.Y.Scale, dPos.Y.Offset+d.Y)
    end
end)

-- ?? pop-in animation ??????????????????????????????????????????????
win.Size = UDim2.new(0,0,0,0); win.Position = UDim2.new(0.5,0,0.5,0)
TweenService:Create(win, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
    {Size=UDim2.new(0,W,0,H), Position=UDim2.new(0.5,-W/2,0.5,-H/2)}):Play()

print("[OK] NeonMaker loaded")

