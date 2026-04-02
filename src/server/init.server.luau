local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")

-- Create all RemoteEvents before other modules need them
require(Shared:WaitForChild("RemoteHandler"))

local TeamManager     = require(script:WaitForChild("TeamManager"))
local ResourceManager = require(script:WaitForChild("ResourceManager"))
local UnitManager     = require(script:WaitForChild("UnitManager"))
local BuildingManager = require(script:WaitForChild("BuildingManager"))

TeamManager.init()
ResourceManager.init()
UnitManager.init(ResourceManager)
BuildingManager.init(ResourceManager)

print("[Server] RTS initialized")
