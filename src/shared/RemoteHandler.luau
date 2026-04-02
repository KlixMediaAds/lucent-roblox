local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config            = require(script.Parent.Config)

local folder: Folder

if RunService:IsServer() then
	local existing = ReplicatedStorage:FindFirstChild("Remotes")
	if existing then
		folder = existing :: Folder
	else
		folder = Instance.new("Folder")
		folder.Name   = "Remotes"
		folder.Parent = ReplicatedStorage
		for _, name in Config.REMOTES do
			local e  = Instance.new("RemoteEvent")
			e.Name   = name
			e.Parent = folder
		end
	end
else
	folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

local RemoteHandler = {}

function RemoteHandler.get(name: string): RemoteEvent
	return (folder:WaitForChild(name) :: RemoteEvent)
end

return RemoteHandler
