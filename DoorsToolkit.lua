--[[
    DOORS Toolkit (WindUI) - client-side Luau for a script executor.

    STATUS: written without access to the game or an executor. It has NOT been run in-game.
    Every game-specific instance name lives in `Config` below, tagged with where it came from:
      [seen]    appeared in public DOORS scripts found while writing this (older builds, not re-checked on yours)
      [memory]  general knowledge of the game, not confirmed from a source here
      [assumed] a guess you are expected to tune with the Remotes tab tools
    Use the Remotes tab (Dump Remotes / Dump Prompts / Remote Spy) to confirm names on your build.
]]

local cloneref = cloneref or function(inst) return inst end
local function svc(name) return cloneref(game:GetService(name)) end

local Players = svc("Players")
local RunService = svc("RunService")
local Lighting = svc("Lighting")
local ReplicatedStorage = svc("ReplicatedStorage")
local VirtualUser = svc("VirtualUser")
local ProximityPromptService = svc("ProximityPromptService")
local CoreGui = svc("CoreGui")
local StarterGui = svc("StarterGui")
local Workspace = svc("Workspace")
local LocalPlayer = Players.LocalPlayer

----------------------------------------------------------------------
-- Single-instance guard
----------------------------------------------------------------------
local env = (getgenv and getgenv()) or _G
if env.DoorsToolkitUnload then pcall(env.DoorsToolkitUnload) end

----------------------------------------------------------------------
-- Config: every build-dependent name in one place
----------------------------------------------------------------------
local Config = {
    WindUIUrl = "https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua",

    RoomsContainer   = "CurrentRooms",   -- [seen]   workspace.CurrentRooms[roomNumberAsString]
    DoorModel        = "Door",           -- [seen]   room.Door
    DoorPart         = "Door",           -- [seen]   room.Door.Door (BasePart)
    DoorOpenRemote   = "ClientOpen",     -- [seen]   room.Door.ClientOpen:FireServer()
    DoorLock         = "Lock",           -- [seen]   room.Door.Lock
    DoorUnlockPrompt = "UnlockPrompt",   -- [seen]   room.Door.Lock.UnlockPrompt
    GameData         = "GameData",       -- [memory] ReplicatedStorage.GameData
    LatestRoom       = "LatestRoom",     -- [memory] ReplicatedStorage.GameData.LatestRoom (number value)
    DoorMaxAttempts  = 3,                -- [assumed] bounded retries per door

    Entities = {
        RushMoving   = { label = "Rush",   verified = true  },  -- [seen]
        AmbushMoving = { label = "Ambush", verified = true  },  -- [seen]
        Eyes         = { label = "Eyes",   verified = false },  -- [memory]
        Screech      = { label = "Screech", verified = false }, -- [memory]
        Halt         = { label = "Halt",   verified = false },  -- [memory]
    },

    -- [assumed] substrings of ProximityPrompt.ActionText that Auto Loot will fire. Tune via Dump Prompts.
    DefaultLootActions = "collect,take,pick",
}

----------------------------------------------------------------------
-- Executor capability checks
----------------------------------------------------------------------
local Caps = {
    fireproximityprompt = typeof(fireproximityprompt) == "function",
    spy = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"
        and typeof(checkcaller) == "function" and typeof(newcclosure) == "function",
    setclipboard = typeof(setclipboard) == "function",
    gethui = typeof(gethui) == "function",
}
local GuiParent = (Caps.gethui and gethui()) or CoreGui

----------------------------------------------------------------------
-- State, connections, notifications
----------------------------------------------------------------------
local alive = true
local conns = {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    conns[#conns + 1] = c
    return c
end

local State = {
    EspDoors = false, EspEntities = false, EspInteractables = false, InteractableFilter = "",
    EntityAlerts = true, EntityLog = false,
    Fullbright = false,
    Speed = false, SpeedExtra = 6,
    Noclip = false,
    Fov = false, FovValue = 90,
    InstantPrompts = false,
    PromptReach = false, PromptReachMult = 1.5,
    AutoLoot = false, AutoLootRange = 12,
    AutoDoor = false, AutoDoorRange = 14,
    AntiAfk = true,
    Spy = false,
}

local WindUI
local function notify(title, content, duration)
    local ok = false
    if WindUI then
        ok = pcall(function()
            WindUI:Notify({ Title = title, Content = content, Duration = duration or 4 })
        end)
    end
    if not ok then
        pcall(function()
            StarterGui:SetCore("SendNotification", { Title = title, Text = content, Duration = duration or 4 })
        end)
    end
    print(("[DoorsToolkit] %s: %s"):format(title, content))
end

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function getRooms() return Workspace:FindFirstChild(Config.RoomsContainer) end
local function getRoot()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function getHum()
    local c = LocalPlayer.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function readLatestRoom()
    local gd = ReplicatedStorage:FindFirstChild(Config.GameData)
    local v = gd and gd:FindFirstChild(Config.LatestRoom)
    if v and typeof(v.Value) == "number" then return v.Value end
    return nil
end

local function nextDoor()
    local rooms, latest = getRooms(), readLatestRoom()
    local room = rooms and latest and rooms:FindFirstChild(tostring(latest))
    local door = room and room:FindFirstChild(Config.DoorModel)
    local part = door and door:FindFirstChild(Config.DoorPart)
    if part and part:IsA("BasePart") then return door, part end
    return nil, nil
end

local function emit(lines, title)
    local text = table.concat(lines, "\n")
    print(("[DoorsToolkit] %s (%d lines)\n%s"):format(title, #lines, text))
    if Caps.setclipboard then pcall(setclipboard, text) end
    notify(title, ("%d lines printed to the console (F9)%s"):format(#lines, Caps.setclipboard and " and copied" or ""), 4)
end

----------------------------------------------------------------------
-- ESP (BillboardGui label for everything, Highlight for doors/entities within Roblox's limit)
----------------------------------------------------------------------
local COLORS = {
    Door = Color3.fromRGB(80, 200, 120),
    Entity = Color3.fromRGB(255, 70, 70),
    Item = Color3.fromRGB(90, 170, 255),
}
local HIGHLIGHT_BUDGET = 28 -- Roblox only renders a limited number of Highlights at once
local highlightCount = 0
local ESPCat = { Door = {}, Entity = {}, Item = {} }

local function anchorOf(target)
    if target:IsA("BasePart") then return target end
    if target:IsA("Model") then
        return target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end

local function espRemove(cat, target)
    local entry = ESPCat[cat][target]
    if not entry then return end
    ESPCat[cat][target] = nil
    if entry.gui then entry.gui:Destroy() end
    if entry.hl then
        entry.hl:Destroy()
        highlightCount -= 1
    end
end

local function espClear(cat)
    for target in pairs(ESPCat[cat]) do espRemove(cat, target) end
end

local function espAdd(cat, target, base, color, withHighlight)
    if ESPCat[cat][target] then return end
    local anchor = anchorOf(target)
    if not anchor then return end

    local gui = Instance.new("BillboardGui")
    gui.Name = "DT_ESP"
    gui.AlwaysOnTop = true
    gui.Size = UDim2.fromOffset(180, 24)
    gui.StudsOffset = Vector3.new(0, 2, 0)
    gui.Adornee = anchor
    gui.ResetOnSpawn = false

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 13
    label.TextColor3 = color
    label.TextStrokeTransparency = 0.4
    label.Text = base
    label.Parent = gui
    gui.Parent = GuiParent

    local entry = { gui = gui, label = label, base = base }
    if withHighlight and highlightCount < HIGHLIGHT_BUDGET then
        local hl = Instance.new("Highlight")
        hl.Name = "DT_HL"
        hl.Adornee = target
        hl.FillColor = color
        hl.OutlineColor = color
        hl.FillTransparency = 0.75
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = GuiParent
        entry.hl = hl
        highlightCount += 1
    end
    ESPCat[cat][target] = entry
end

local espAccum = 0
bind(RunService.Heartbeat, function(dt)
    espAccum += dt
    if espAccum < 0.2 then return end
    espAccum = 0
    local root = getRoot()
    for cat, bucket in pairs(ESPCat) do
        for target, entry in pairs(bucket) do
            if not target:IsDescendantOf(Workspace) then
                espRemove(cat, target)
            elseif root then
                local ok, pivot = pcall(target.GetPivot, target)
                if ok then
                    local dist = math.floor((pivot.Position - root.Position).Magnitude)
                    entry.label.Text = ("%s [%d]"):format(entry.base, dist)
                end
            end
        end
    end
end)

----------------------------------------------------------------------
-- Doors ESP
----------------------------------------------------------------------
local function trackRoom(room)
    task.spawn(function()
        local door = room:WaitForChild(Config.DoorModel, 10)
        if door and alive and State.EspDoors then
            espAdd("Door", door, "Door " .. room.Name, COLORS.Door, true)
        end
    end)
end

local function refreshDoorEsp()
    espClear("Door")
    if not State.EspDoors then return end
    local rooms = getRooms()
    if not rooms then return end
    for _, room in ipairs(rooms:GetChildren()) do trackRoom(room) end
end

----------------------------------------------------------------------
-- Entities: alerts, ESP, name logger
----------------------------------------------------------------------
local seenEntities = setmetatable({}, { __mode = "k" })

local function onEntityCandidate(inst)
    if not inst:IsA("Model") then return end
    local def = Config.Entities[inst.Name]
    if not def or seenEntities[inst] then return end
    seenEntities[inst] = true
    if State.EntityAlerts then
        notify("Entity spawned", def.label .. (def.verified and "" or " (name not confirmed on this build)"), 5)
    end
    if State.EspEntities then
        espAdd("Entity", inst, def.label, COLORS.Entity, true)
    end
end

local function scanExistingEntities()
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("Model") and Config.Entities[d.Name] then
            local def = Config.Entities[d.Name]
            seenEntities[d] = true
            espAdd("Entity", d, def.label, COLORS.Entity, true)
        end
    end
end

bind(Workspace.ChildAdded, function(inst)
    onEntityCandidate(inst)
    if State.EntityLog and inst:IsA("Model") and not Players:GetPlayerFromCharacter(inst) then
        print(("[DoorsToolkit] new workspace model: %s"):format(inst:GetFullName()))
    end
end)

----------------------------------------------------------------------
-- Proximity prompts: registry, reach, interactable ESP, auto loot, instant prompts
----------------------------------------------------------------------
local Prompts = setmetatable({}, { __mode = "k" }) -- prompt -> { distance, los }

local function promptPosition(p)
    local parent = p.Parent
    if not parent then return nil end
    if parent:IsA("Attachment") then return parent.WorldPosition end
    if parent:IsA("BasePart") then return parent.Position end
    if parent:IsA("Model") then return parent:GetPivot().Position end
    return nil
end

local function matchesFilter(p)
    local f = State.InteractableFilter:lower()
    if f == "" then return true end
    local hay = (p.ObjectText .. " " .. p.ActionText .. " " .. (p.Parent and p.Parent.Name or "")):lower()
    return hay:find(f, 1, true) ~= nil
end

local function interactableTarget(p)
    local holder = p.Parent
    if holder and holder:IsA("Attachment") then holder = holder.Parent end
    if not holder then return nil end
    if holder:IsA("Model") then return holder end
    if holder:IsA("BasePart") then
        local rooms = getRooms()
        local m = holder:FindFirstAncestorOfClass("Model")
        if m and m.Parent ~= rooms and m ~= Workspace then return m end
        return holder
    end
    return nil
end

local function espInteractable(p)
    if not p.Parent or not matchesFilter(p) then return end
    local target = interactableTarget(p)
    if not target then return end
    local name = (p.ObjectText ~= "" and p.ObjectText) or target.Name
    local label = p.ActionText ~= "" and ("%s (%s)"):format(name, p.ActionText) or name
    espAdd("Item", target, label, COLORS.Item, false)
end

local function refreshInteractableEsp()
    espClear("Item")
    if not State.EspInteractables then return end
    for p in pairs(Prompts) do espInteractable(p) end
end

local function applyReach(p)
    local orig = Prompts[p]
    if not orig or not p.Parent then return end
    if State.PromptReach then
        p.MaxActivationDistance = orig.distance * State.PromptReachMult
        p.RequiresLineOfSight = false
    else
        p.MaxActivationDistance = orig.distance
        p.RequiresLineOfSight = orig.los
    end
end

local function applyReachAll()
    for p in pairs(Prompts) do applyReach(p) end
end

local function registerPrompt(p)
    if Prompts[p] then return end
    Prompts[p] = { distance = p.MaxActivationDistance, los = p.RequiresLineOfSight }
    if State.PromptReach then applyReach(p) end
    if State.EspInteractables then espInteractable(p) end
end

local lootWords = {}
local function setLootActions(text)
    lootWords = {}
    for word in tostring(text):gmatch("[^,]+") do
        local w = word:match("^%s*(.-)%s*$"):lower()
        if w ~= "" then lootWords[#lootWords + 1] = w end
    end
end
setLootActions(Config.DefaultLootActions)

local function lootActionMatches(p)
    local act = p.ActionText:lower()
    for _, w in ipairs(lootWords) do
        if act:find(w, 1, true) then return true end
    end
    return false
end

bind(ProximityPromptService.PromptButtonHoldBegan, function(p)
    if State.InstantPrompts and Caps.fireproximityprompt then
        fireproximityprompt(p)
    end
end)

----------------------------------------------------------------------
-- Rooms hook (runs once CurrentRooms exists; in the lobby it waits)
----------------------------------------------------------------------
local roomsHooked = false
local function hookRooms(rooms)
    if roomsHooked then return end
    roomsHooked = true
    for _, d in ipairs(rooms:GetDescendants()) do
        if d:IsA("ProximityPrompt") then registerPrompt(d) end
    end
    bind(rooms.DescendantAdded, function(d)
        if d:IsA("ProximityPrompt") then registerPrompt(d) end
        onEntityCandidate(d)
    end)
    bind(rooms.ChildAdded, function(room)
        if State.EspDoors then trackRoom(room) end
    end)
end

task.spawn(function()
    local rooms = Workspace:WaitForChild(Config.RoomsContainer, 30)
    if not alive then return end
    if rooms then
        hookRooms(rooms)
    else
        notify("Rooms not found", "workspace." .. Config.RoomsContainer .. " did not appear (are you in a run?)", 6)
    end
end)

----------------------------------------------------------------------
-- Fullbright, speed, noclip, FOV, anti-AFK
----------------------------------------------------------------------
local lightingBackup
local function fullbrightApply()
    if not lightingBackup then
        lightingBackup = {
            Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime,
            FogStart = Lighting.FogStart, FogEnd = Lighting.FogEnd,
            GlobalShadows = Lighting.GlobalShadows,
            Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
        }
    end
    Lighting.Brightness = 2
    Lighting.ClockTime = 14
    Lighting.FogStart = 1e5
    Lighting.FogEnd = 1e5
    Lighting.GlobalShadows = false
    Lighting.Ambient = Color3.fromRGB(170, 170, 170)
    Lighting.OutdoorAmbient = Color3.fromRGB(170, 170, 170)
end

local function fullbrightRestore()
    if not lightingBackup then return end
    for k, v in pairs(lightingBackup) do
        pcall(function() Lighting[k] = v end)
    end
    lightingBackup = nil
end

bind(RunService.RenderStepped, function(dt)
    if State.Fullbright then fullbrightApply() end

    if State.Speed then
        local char, hum = LocalPlayer.Character, getHum()
        if char and hum and hum.MoveDirection.Magnitude > 0 then
            char:TranslateBy(hum.MoveDirection * State.SpeedExtra * dt)
        end
    end

    if State.Fov then
        local cam = Workspace.CurrentCamera
        if cam then cam.FieldOfView = State.FovValue end
    end
end)

local noclipChanged = setmetatable({}, { __mode = "k" })
bind(RunService.Stepped, function()
    if not State.Noclip then return end
    local char = LocalPlayer.Character
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.CanCollide then
            noclipChanged[part] = true
            part.CanCollide = false
        end
    end
end)

local function noclipRestore()
    for part in pairs(noclipChanged) do
        if part.Parent then part.CanCollide = true end
        noclipChanged[part] = nil
    end
end

bind(LocalPlayer.Idled, function()
    if State.AntiAfk then
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end
end)

----------------------------------------------------------------------
-- Automation loop: auto loot + auto door (bounded, cooled down, pcall-wrapped)
----------------------------------------------------------------------
local lastFired = setmetatable({}, { __mode = "k" })
local doorAttempts = setmetatable({}, { __mode = "k" })

local function autoStep()
    local root = getRoot()
    if not root then return end
    local now = os.clock()

    if State.AutoLoot and Caps.fireproximityprompt then
        for p in pairs(Prompts) do
            if p.Parent and p.Enabled and (lastFired[p] or 0) + 1 < now then
                local pos = promptPosition(p)
                if pos and (pos - root.Position).Magnitude <= State.AutoLootRange and lootActionMatches(p) then
                    lastFired[p] = now
                    fireproximityprompt(p)
                end
            end
        end
    end

    if State.AutoDoor then
        local door, part = nextDoor()
        local remote = door and door:FindFirstChild(Config.DoorOpenRemote)
        if part and remote and remote:IsA("RemoteEvent")
            and (part.Position - root.Position).Magnitude <= State.AutoDoorRange then
            local rec = doorAttempts[door]
            if not rec then
                rec = { count = 0, last = 0 }
                doorAttempts[door] = rec
            end
            if rec.count < Config.DoorMaxAttempts and now - rec.last >= 1.5 then
                rec.count += 1
                rec.last = now
                local lock = door:FindFirstChild(Config.DoorLock)
                local unlock = lock and lock:FindFirstChild(Config.DoorUnlockPrompt)
                if unlock and unlock:IsA("ProximityPrompt") and Caps.fireproximityprompt then
                    fireproximityprompt(unlock)
                end
                remote:FireServer()
            end
        end
    end
end

task.spawn(function()
    local lastErr
    while alive do
        task.wait(0.3)
        local ok, err = pcall(autoStep)
        if not ok and err ~= lastErr then
            lastErr = err
            warn("[DoorsToolkit] automation error: " .. tostring(err))
        end
    end
end)

local function teleportToNextDoor()
    local root = getRoot()
    local _, part = nextDoor()
    if not root then notify("Teleport", "No character", 3) return end
    if not part then notify("Teleport", "Next door not found (LatestRoom or door path differs on this build)", 5) return end
    root:PivotTo(CFrame.new(part.Position))
end

----------------------------------------------------------------------
-- Remote / prompt discovery tools
----------------------------------------------------------------------
local function dumpRemotes()
    local lines = {}
    for _, container in ipairs({ ReplicatedStorage, Workspace }) do
        for _, d in ipairs(container:GetDescendants()) do
            if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("UnreliableRemoteEvent") then
                if #lines < 600 then
                    lines[#lines + 1] = ("%s  [%s]"):format(d:GetFullName(), d.ClassName)
                end
            end
        end
    end
    table.sort(lines)
    emit(lines, "Remote dump")
end

local function dumpPrompts()
    local lines = {}
    for p in pairs(Prompts) do
        if p.Parent and #lines < 600 then
            lines[#lines + 1] = ("%s | action=%q object=%q dist=%s hold=%s"):format(
                p:GetFullName(), p.ActionText, p.ObjectText, tostring(p.MaxActivationDistance), tostring(p.HoldDuration))
        end
    end
    table.sort(lines)
    emit(lines, "Prompt dump")
end

local SpyLog = {}
local spyInstalled = false

local function fmtArg(a)
    local t = typeof(a)
    if t == "string" then return ("%q"):format(a) end
    if t == "table" then return "{table}" end
    if t == "Instance" then
        local ok, path = pcall(a.GetFullName, a)
        return ok and path or tostring(a)
    end
    return tostring(a)
end

local function recordSpy(remote, method, args)
    if not alive or typeof(remote) ~= "Instance" then return end
    local ok, path = pcall(remote.GetFullName, remote)
    path = ok and path or tostring(remote)
    local entry = SpyLog[path]
    if not entry then
        entry = { count = 0, method = method, samples = {} }
        SpyLog[path] = entry
    end
    entry.count += 1
    if #entry.samples < 3 then
        local parts = {}
        for i = 1, args.n do parts[i] = fmtArg(args[i]) end
        local sample = table.concat(parts, ", ")
        entry.samples[#entry.samples + 1] = sample
        print(("[RemoteSpy] %s:%s(%s)"):format(path, method, sample))
    end
end

local function installSpy()
    if spyInstalled then return true end
    if not Caps.spy then return false end
    local old
    old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if State.Spy and (method == "FireServer" or method == "InvokeServer") and not checkcaller() then
            task.defer(recordSpy, self, method, table.pack(...))
        end
        return old(self, ...)
    end))
    spyInstalled = true
    return true
end

local function spySummary()
    local lines = {}
    for path, e in pairs(SpyLog) do
        lines[#lines + 1] = ("%s:%s x%d  e.g. (%s)"):format(path, e.method, e.count, e.samples[1] or "")
    end
    table.sort(lines)
    emit(lines, "Remote spy summary")
end

----------------------------------------------------------------------
-- Unload
----------------------------------------------------------------------
local Window
local function unload()
    if not alive then return end
    alive = false
    State.Spy = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    for cat in pairs(ESPCat) do espClear(cat) end
    fullbrightRestore()
    noclipRestore()
    State.PromptReach = false
    applyReachAll()
    if Window then pcall(function() Window:Destroy() end) end
    env.DoorsToolkitUnload = nil
end
env.DoorsToolkitUnload = unload

----------------------------------------------------------------------
-- UI (WindUI)
----------------------------------------------------------------------
local okLib, lib = pcall(function()
    return loadstring(game:HttpGet(Config.WindUIUrl))()
end)
if not okLib or not lib then
    warn("[DoorsToolkit] could not load WindUI: " .. tostring(lib))
    unload()
    return
end
WindUI = lib

Window = WindUI:CreateWindow({
    Title = "DOORS Toolkit",
    Author = "Hacking Everything",
    Folder = "DoorsToolkit",
    Icon = "door-open",
    Theme = "Dark",
})
if not Window then
    warn("[DoorsToolkit] WindUI returned no window (only one window can exist at a time)")
    unload()
    return
end
pcall(function() Window:SetToggleKey(Enum.KeyCode.RightShift) end)

-- Visuals
local Visuals = Window:Tab({ Title = "Visuals", Icon = "eye" })
local EspSec = Visuals:Section({ Title = "ESP" })
EspSec:Toggle({ Title = "Door ESP", Value = false, Callback = function(v)
    State.EspDoors = v
    refreshDoorEsp()
end })
EspSec:Toggle({ Title = "Entity ESP", Value = false, Callback = function(v)
    State.EspEntities = v
    if v then scanExistingEntities() else espClear("Entity") end
end })
EspSec:Toggle({ Title = "Interactable ESP (every proximity prompt)", Value = false, Callback = function(v)
    State.EspInteractables = v
    refreshInteractableEsp()
end })
EspSec:Input({ Title = "Interactable filter (empty = all)", Value = "", Callback = function(text)
    State.InteractableFilter = tostring(text or "")
    refreshInteractableEsp()
end })

local WorldSec = Visuals:Section({ Title = "World" })
WorldSec:Toggle({ Title = "Fullbright", Value = false, Callback = function(v)
    State.Fullbright = v
    if not v then fullbrightRestore() end
end })
WorldSec:Toggle({ Title = "Custom FOV", Value = false, Callback = function(v) State.Fov = v end })
WorldSec:Slider({ Title = "FOV", Value = { Min = 60, Max = 120, Default = 90 }, Step = 1, Callback = function(v)
    State.FovValue = v
end })

-- Movement
local Movement = Window:Tab({ Title = "Movement", Icon = "footprints" })
local MoveSec = Movement:Section({ Title = "Movement" })
MoveSec:Toggle({ Title = "Speed boost (CFrame translate)", Value = false, Callback = function(v) State.Speed = v end })
MoveSec:Slider({ Title = "Extra studs per second", Value = { Min = 1, Max = 25, Default = 6 }, Step = 1, Callback = function(v)
    State.SpeedExtra = v
end })
MoveSec:Toggle({ Title = "Noclip", Value = false, Callback = function(v)
    State.Noclip = v
    if not v then noclipRestore() end
end })
MoveSec:Button({ Title = "Teleport to next door", Callback = teleportToNextDoor })

-- Automation
local Auto = Window:Tab({ Title = "Automation", Icon = "zap" })
local PromptSec = Auto:Section({ Title = "Prompts" })
PromptSec:Toggle({ Title = "Instant prompts (skip hold time)", Value = false, Callback = function(v)
    if v and not Caps.fireproximityprompt then
        notify("Unsupported", "Your executor has no fireproximityprompt", 5)
    end
    State.InstantPrompts = v
end })
PromptSec:Toggle({ Title = "Prompt reach", Value = false, Callback = function(v)
    State.PromptReach = v
    applyReachAll()
end })
PromptSec:Slider({ Title = "Reach multiplier", Value = { Min = 1, Max = 3, Default = 1.5 }, Step = 0.1, Callback = function(v)
    State.PromptReachMult = v
    applyReachAll()
end })

local LootSec = Auto:Section({ Title = "Auto loot" })
LootSec:Toggle({ Title = "Auto loot", Value = false, Callback = function(v)
    if v and not Caps.fireproximityprompt then
        notify("Unsupported", "Your executor has no fireproximityprompt", 5)
    end
    State.AutoLoot = v
end })
LootSec:Slider({ Title = "Loot range (studs)", Value = { Min = 5, Max = 25, Default = 12 }, Step = 1, Callback = function(v)
    State.AutoLootRange = v
end })
LootSec:Input({ Title = "Action words (comma separated, assumed defaults)", Value = Config.DefaultLootActions, Callback = function(text)
    setLootActions(text)
end })

local DoorSec = Auto:Section({ Title = "Doors" })
DoorSec:Toggle({ Title = "Auto open next door", Value = false, Callback = function(v) State.AutoDoor = v end })
DoorSec:Slider({ Title = "Door range (studs)", Value = { Min = 5, Max = 25, Default = 14 }, Step = 1, Callback = function(v)
    State.AutoDoorRange = v
end })

-- Alerts
local Alerts = Window:Tab({ Title = "Alerts", Icon = "bell" })
local AlertSec = Alerts:Section({ Title = "Entities" })
AlertSec:Toggle({ Title = "Entity spawn alerts", Value = true, Callback = function(v) State.EntityAlerts = v end })
AlertSec:Toggle({ Title = "Log new workspace models (find entity names)", Value = false, Callback = function(v)
    State.EntityLog = v
end })

-- Remotes
local Remotes = Window:Tab({ Title = "Remotes", Icon = "terminal" })
local RemSec = Remotes:Section({ Title = "Discovery" })
RemSec:Button({ Title = "Dump remotes", Callback = dumpRemotes })
RemSec:Button({ Title = "Dump proximity prompts", Callback = dumpPrompts })
RemSec:Toggle({ Title = "Remote spy (game-originated FireServer/InvokeServer)", Value = false, Callback = function(v)
    if v and not installSpy() then
        notify("Unsupported", "Your executor lacks hookmetamethod/getnamecallmethod/checkcaller/newcclosure", 6)
        return
    end
    State.Spy = v
end })
RemSec:Button({ Title = "Remote spy summary", Callback = spySummary })

-- Settings
local Settings = Window:Tab({ Title = "Settings", Icon = "settings" })
local SetSec = Settings:Section({ Title = "General" })
SetSec:Dropdown({
    Title = "Theme",
    Values = { "Dark", "Light", "Rose", "Plant", "Indigo", "Sky", "Violet", "Amber" },
    Value = "Dark",
    Callback = function(name)
        pcall(function() WindUI:SetTheme(name) end)
    end,
})
SetSec:Toggle({ Title = "Anti-AFK", Value = true, Callback = function(v) State.AntiAfk = v end })
SetSec:Button({ Title = "Unload toolkit", Callback = unload })

notify("DOORS Toolkit", ("loaded. fireproximityprompt=%s spy=%s clipboard=%s"):format(
    tostring(Caps.fireproximityprompt), tostring(Caps.spy), tostring(Caps.setclipboard)), 6)
