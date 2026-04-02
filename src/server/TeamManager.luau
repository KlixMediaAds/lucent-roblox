local Players = game:GetService("Players")
local Teams   = game:GetService("Teams")

local TEAM_COLORS = {
	BrickColor.new("Bright blue"),
	BrickColor.new("Bright red"),
	BrickColor.new("Bright green"),
	BrickColor.new("Bright yellow"),
}

local TeamManager = {}
local teamList: {Team} = {}

function TeamManager.init()
	for i, color in TEAM_COLORS do
		local team             = Instance.new("Team")
		team.Name              = "Team " .. i
		team.TeamColor         = color
		team.AutoAssignable    = false
		team.Parent            = Teams
		teamList[i]            = team
	end

	Players.PlayerAdded:Connect(function(player)
		-- Assign to smallest team
		local best, minCount = teamList[1], math.huge
		for _, team in teamList do
			local n = #team:GetPlayers()
			if n < minCount then
				minCount = n
				best     = team
			end
		end
		player.Team      = best
		player.TeamColor = best.TeamColor
	end)
end

return TeamManager
