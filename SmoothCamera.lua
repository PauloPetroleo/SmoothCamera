local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------

local BIND_NAME = "PremiumDynamicCamera"
local TOGGLE_KEY = Enum.KeyCode.V

------------------------------------------------------------
-- MOVIMENTO
------------------------------------------------------------

-- Spring da posição.
-- Maior = acompanha mais rápido.
local POSITION_FREQUENCY = 5.2

------------------------------------------------------------
-- MIRA / ROTAÇÃO
------------------------------------------------------------

-- Quando o jogador está perto do centro:
-- câmera fica mais relaxada.
local AIM_FREQUENCY_MIN = 3.2

-- Quando o jogador se afasta do centro:
-- câmera começa a corrigir mais forte.
local AIM_FREQUENCY_MAX = 8.5

-- Região central onde pequenos desvios são permitidos.
local SOFT_ZONE_YAW = math.rad(4.5)
local SOFT_ZONE_PITCH = math.rad(3.2)

-- A partir deste multiplicador da soft-zone,
-- a assistência chega praticamente ao máximo.
local AIM_FULL_ASSIST = 3.0

------------------------------------------------------------
-- COLISÃO
------------------------------------------------------------

local CAMERA_RADIUS = 0.35
local WALL_PADDING = 0.2

------------------------------------------------------------
-- ROTEAMENTO
------------------------------------------------------------

local WAYPOINT_REACHED_DISTANCE = 0.45
local ROUTE_REPLAN_INTERVAL = 0.075

-- Evita ficar alternando rota nas quinas.
local DIRECT_PATH_HOLD = 0.075

local ROUTE_SAMPLE_DISTANCES = {
	1.1,
	2.1,
	3.4,
}

-- Prefere contornar lateralmente em vez
-- de fazer movimentos verticais estranhos.
local VERTICAL_ROUTE_PENALTY = 0.45

local TURN_ROUTE_PENALTY = 0.35

------------------------------------------------------------
-- ALVO
------------------------------------------------------------

local LOOK_OFFSET = Vector3.new(0, 1.45, 0)

------------------------------------------------------------
-- SPRING
-- Mesmo estilo matemático da Freecam do Roblox.
------------------------------------------------------------

local Spring = {}
Spring.__index = Spring

function Spring.new(frequency, position)
	local self = setmetatable({}, Spring)

	self.f = frequency
	self.p = position
	self.v = position * 0

	return self
end

function Spring:Update(dt, goal)
	local f = self.f * 2 * math.pi

	local p0 = self.p
	local v0 = self.v

	local offset = goal - p0
	local decay = math.exp(-f * dt)

	local p1 =
		goal
		+ (
			v0 * dt
			- offset * (f * dt + 1)
		) * decay

	local v1 =
		(
			f * dt * (
				offset * f - v0
			)
			+ v0
		) * decay

	self.p = p1
	self.v = v1

	return p1
end

function Spring:Reset(position)
	self.p = position
	self.v = position * 0
end

function Spring:SetFreq(frequency)
	self.f = frequency
end

------------------------------------------------------------
-- STATE
------------------------------------------------------------

local enabled = false

local positionSpring
local aimSpring

local route = {}
local routeIndex = 1

local lastRoutePlan = 0
local directClearTimer = 0

------------------------------------------------------------
-- CAST PARAMS
------------------------------------------------------------

local castParams = RaycastParams.new()

castParams.FilterType =
	Enum.RaycastFilterType.Exclude

castParams.IgnoreWater = true
castParams.RespectCanCollide = true

------------------------------------------------------------
-- CHARACTER
------------------------------------------------------------

local function getCharacter()
	local character = player.Character

	if not character then
		return nil, nil
	end

	local root =
		character:FindFirstChild(
			"HumanoidRootPart"
		)

	if not root then
		return nil, nil
	end

	return character, root
end

local function getLookTarget()
	local character, root = getCharacter()

	if not character or not root then
		return nil
	end

	return root.Position + LOOK_OFFSET
end

local function updateFilter()
	local character = player.Character

	if character then
		castParams.FilterDescendantsInstances = {
			character
		}
	else
		castParams.FilterDescendantsInstances = {}
	end
end

------------------------------------------------------------
-- UTILS
------------------------------------------------------------

local function safeUnit(vector, fallback)
	if vector.Magnitude > 0.0001 then
		return vector.Unit
	end

	return fallback or Vector3.new(0, 0, -1)
end

local function clearRoute()
	table.clear(route)
	routeIndex = 1
end

local function currentWaypoint()
	return route[routeIndex]
end

------------------------------------------------------------
-- CAST
------------------------------------------------------------

local function castBetween(a, b)
	updateFilter()

	local direction = b - a

	if direction.Magnitude <= 0.001 then
		return nil
	end

	return Workspace:Spherecast(
		a,
		CAMERA_RADIUS,
		direction,
		castParams
	)
end

local function pathClear(a, b)
	return castBetween(a, b) == nil
end

------------------------------------------------------------
-- SUPERFÍCIE
------------------------------------------------------------

local function safePositionBeforeHit(a, b, hit)
	if not hit then
		return b
	end

	local direction =
		safeUnit(b - a)

	local distance =
		math.max(
			hit.Distance - WALL_PADDING,
			0
		)

	return a + direction * distance
end

------------------------------------------------------------
-- VELOCIDADE NA PAREDE
------------------------------------------------------------

local function removeIntoSurfaceVelocity(normal)
	if not positionSpring then
		return
	end

	local velocity = positionSpring.v

	local amount =
		velocity:Dot(normal)

	if amount < 0 then
		positionSpring.v =
			velocity
			- normal * amount
	end
end

------------------------------------------------------------
-- BASE DA SUPERFÍCIE
------------------------------------------------------------

local function getSurfaceBasis(normal)
	local side =
		normal:Cross(Vector3.yAxis)

	if side.Magnitude < 0.05 then
		side =
			normal:Cross(
				Vector3.xAxis
			)
	end

	side =
		safeUnit(
			side,
			Vector3.xAxis
		)

	local up =
		safeUnit(
			side:Cross(normal),
			Vector3.yAxis
		)

	return side, up
end

------------------------------------------------------------
-- CANDIDATOS DE ROTA
------------------------------------------------------------

local function generateCandidates(hit)
	local candidates = {}

	local normal = hit.Normal
	local side, surfaceUp =
		getSurfaceBasis(normal)

	local base =
		hit.Position
		+ normal
		* (CAMERA_RADIUS + WALL_PADDING)

	local directions = {
		side,
		-side,

		surfaceUp,
		-surfaceUp,

		safeUnit(side + surfaceUp),
		safeUnit(-side + surfaceUp),

		safeUnit(side - surfaceUp),
		safeUnit(-side - surfaceUp),
	}

	for _, distance in ipairs(
		ROUTE_SAMPLE_DISTANCES
	) do
		for _, direction in ipairs(
			directions
		) do
			table.insert(
				candidates,
				base + direction * distance
			)
		end
	end

	return candidates
end

------------------------------------------------------------
-- SCORE DA ROTA
------------------------------------------------------------

local function routeScore(
	startPosition,
	points,
	finalGoal
)

	local score = 0

	local previousPosition =
		startPosition

	local previousDirection

	for _, point in ipairs(points) do
		local delta =
			point - previousPosition

		local distance =
			delta.Magnitude

		score += distance

		score +=
			math.abs(delta.Y)
			* VERTICAL_ROUTE_PENALTY

		if distance > 0.001 then
			local direction =
				delta.Unit

			if previousDirection then
				local dot =
					math.clamp(
						previousDirection:Dot(
							direction
						),
						-1,
						1
					)

				score +=
					(1 - dot)
					* TURN_ROUTE_PENALTY
			end

			previousDirection =
				direction
		end

		previousPosition =
			point
	end

	local finalDelta =
		finalGoal - previousPosition

	score += finalDelta.Magnitude

	score +=
		math.abs(finalDelta.Y)
		* VERTICAL_ROUTE_PENALTY

	return score
end

------------------------------------------------------------
-- 1 WAYPOINT
------------------------------------------------------------

local function findSingleRoute(
	startPosition,
	finalGoal,
	firstHit
)

	local bestRoute
	local bestScore = math.huge

	for _, candidate in ipairs(
		generateCandidates(firstHit)
	) do

		if
			pathClear(
				startPosition,
				candidate
			)
			and
			pathClear(
				candidate,
				finalGoal
			)
		then

			local testRoute = {
				candidate
			}

			local score =
				routeScore(
					startPosition,
					testRoute,
					finalGoal
				)

			if score < bestScore then
				bestScore = score
				bestRoute = testRoute
			end
		end
	end

	return bestRoute
end

------------------------------------------------------------
-- 2 WAYPOINTS
------------------------------------------------------------

local function findDoubleRoute(
	startPosition,
	finalGoal,
	firstHit
)

	local bestRoute
	local bestScore = math.huge

	local firstCandidates =
		generateCandidates(firstHit)

	for _, firstPoint in ipairs(
		firstCandidates
	) do

		if pathClear(
			startPosition,
			firstPoint
		) then

			local secondHit =
				castBetween(
					firstPoint,
					finalGoal
				)

			if secondHit then
				for _, secondPoint in ipairs(
					generateCandidates(
						secondHit
					)
				) do

					if
						pathClear(
							firstPoint,
							secondPoint
						)
						and
						pathClear(
							secondPoint,
							finalGoal
						)
					then

						local testRoute = {
							firstPoint,
							secondPoint
						}

						local score =
							routeScore(
								startPosition,
								testRoute,
								finalGoal
							)

						if score < bestScore then
							bestScore = score
							bestRoute = testRoute
						end
					end
				end
			end
		end
	end

	return bestRoute
end

------------------------------------------------------------
-- PLAN ROUTE
------------------------------------------------------------

local function planRoute(
	startPosition,
	finalGoal
)

	local hit =
		castBetween(
			startPosition,
			finalGoal
		)

	if not hit then
		return {}
	end

	local single =
		findSingleRoute(
			startPosition,
			finalGoal,
			hit
		)

	if single then
		return single
	end

	local double =
		findDoubleRoute(
			startPosition,
			finalGoal,
			hit
		)

	if double then
		return double
	end

	return {
		safePositionBeforeHit(
			startPosition,
			finalGoal,
			hit
		)
	}
end

------------------------------------------------------------
-- ROUTE VALIDATION
------------------------------------------------------------

local function routeStillValid(
	currentPosition,
	finalGoal
)

	local waypoint =
		currentWaypoint()

	if not waypoint then
		return false
	end

	if not pathClear(
		currentPosition,
		waypoint
	) then
		return false
	end

	local previous = waypoint

	for i = routeIndex + 1, #route do
		local point = route[i]

		if not pathClear(
			previous,
			point
		) then
			return false
		end

		previous = point
	end

	return pathClear(
		previous,
		finalGoal
	)
end

------------------------------------------------------------
-- WAYPOINT PROGRESS
------------------------------------------------------------

local function updateRouteProgress(
	position
)

	while true do
		local waypoint =
			currentWaypoint()

		if not waypoint then
			break
		end

		if (
			position - waypoint
		).Magnitude
			<= WAYPOINT_REACHED_DISTANCE
		then

			routeIndex += 1
		else
			break
		end
	end

	if routeIndex > #route then
		clearRoute()
	end
end

------------------------------------------------------------
-- NAVIGATION GOAL
------------------------------------------------------------

local function getNavigationGoal(
	dt,
	currentPosition,
	finalGoal
)

	updateRouteProgress(
		currentPosition
	)

	local directClear =
		pathClear(
			currentPosition,
			finalGoal
		)

	if directClear then
		directClearTimer += dt

		if directClearTimer
			>= DIRECT_PATH_HOLD
		then

			clearRoute()

			return finalGoal
		end
	else
		directClearTimer = 0
	end

	local waypoint =
		currentWaypoint()

	if waypoint then
		if routeStillValid(
			currentPosition,
			finalGoal
		) then

			return waypoint
		end

		clearRoute()
	end

	local now = os.clock()

	if
		now - lastRoutePlan
		< ROUTE_REPLAN_INTERVAL
	then

		local hit =
			castBetween(
				currentPosition,
				finalGoal
			)

		if hit then
			return safePositionBeforeHit(
				currentPosition,
				finalGoal,
				hit
			)
		end

		return finalGoal
	end

	lastRoutePlan = now

	route =
		planRoute(
			currentPosition,
			finalGoal
		)

	routeIndex = 1

	return
		currentWaypoint()
		or finalGoal
end

------------------------------------------------------------
-- ANGLES
------------------------------------------------------------

local function directionToAngles(direction)
	direction =
		safeUnit(direction)

	local pitch =
		math.asin(
			math.clamp(
				direction.Y,
				-1,
				1
			)
		)

	local yaw =
		math.atan2(
			-direction.X,
			-direction.Z
		)

	return Vector2.new(
		pitch,
		yaw
	)
end

local function anglesToDirection(angles)
	return CFrame.fromOrientation(
		angles.X,
		angles.Y,
		0
	).LookVector
end

local function shortestAngle(
	current,
	target
)

	local delta =
		(
			target
			- current
			+ math.pi
		)
		% (math.pi * 2)
		- math.pi

	return current + delta
end

------------------------------------------------------------
-- SOFT ZONE / AIM ASSIST
------------------------------------------------------------

local function calculateAimFrequency(
	currentAngles,
	targetAngles
)

	local pitchError =
		math.abs(
			targetAngles.X
			- currentAngles.X
		)

	local yawTarget =
		shortestAngle(
			currentAngles.Y,
			targetAngles.Y
		)

	local yawError =
		math.abs(
			yawTarget
			- currentAngles.Y
		)

	--------------------------------------------------------
	-- Quanto o alvo saiu da região central.
	--------------------------------------------------------

	local normalizedPitch =
		pitchError / SOFT_ZONE_PITCH

	local normalizedYaw =
		yawError / SOFT_ZONE_YAW

	local error =
		math.sqrt(
			normalizedPitch * normalizedPitch
			+
			normalizedYaw * normalizedYaw
		)

	--------------------------------------------------------
	-- Dentro da soft zone:
	-- frequência baixa.
	--
	-- Conforme sai:
	-- frequência sobe progressivamente.
	--------------------------------------------------------

	local t =
		math.clamp(
			(error - 0.6)
			/
			(AIM_FULL_ASSIST - 0.6),
			0,
			1
		)

	-- SmoothStep
	t =
		t * t * (3 - 2 * t)

	return
		AIM_FREQUENCY_MIN
		+
		(
			AIM_FREQUENCY_MAX
			- AIM_FREQUENCY_MIN
		)
		* t
end

------------------------------------------------------------
-- EMERGENCY COLLISION
------------------------------------------------------------

local function emergencyCollision(
	oldPosition,
	newPosition
)

	local hit =
		castBetween(
			oldPosition,
			newPosition
		)

	if not hit then
		return newPosition
	end

	local safePosition =
		safePositionBeforeHit(
			oldPosition,
			newPosition,
			hit
		)

	positionSpring.p =
		safePosition

	removeIntoSurfaceVelocity(
		hit.Normal
	)

	return safePosition
end

------------------------------------------------------------
-- RESET
------------------------------------------------------------

local function resetCameraState()
	camera = Workspace.CurrentCamera

	if not camera then
		return
	end

	local target =
		getLookTarget()

	if not target then
		return
	end

	local position =
		camera.CFrame.Position

	positionSpring =
		Spring.new(
			POSITION_FREQUENCY,
			position
		)

	local direction =
		target - position

	if direction.Magnitude <= 0.001 then
		direction =
			camera.CFrame.LookVector
	end

	local angles =
		directionToAngles(direction)

	aimSpring =
		Spring.new(
			AIM_FREQUENCY_MIN,
			angles
		)

	clearRoute()

	directClearTimer = 0
	lastRoutePlan = 0
end

------------------------------------------------------------
-- UPDATE CAMERA
------------------------------------------------------------

local function updateCamera(dt)
	camera = Workspace.CurrentCamera

	if not camera then
		return
	end

	local targetPosition =
		getLookTarget()

	if not targetPosition then
		return
	end

	if not positionSpring
		or not aimSpring
	then

		resetCameraState()
		return
	end

	--------------------------------------------------------
	-- DESTINO GERADO PELA CÂMERA NORMAL DO ROBLOX
	--------------------------------------------------------

	local desiredPosition =
		camera.CFrame.Position

	local previousPosition =
		positionSpring.p

	--------------------------------------------------------
	-- ROTEAMENTO
	--------------------------------------------------------

	local navigationGoal =
		getNavigationGoal(
			dt,
			previousPosition,
			desiredPosition
		)

	--------------------------------------------------------
	-- SPRING DE MOVIMENTO
	--------------------------------------------------------

	positionSpring:SetFreq(
		POSITION_FREQUENCY
	)

	local springPosition =
		positionSpring:Update(
			dt,
			navigationGoal
		)

	--------------------------------------------------------
	-- SEGURANÇA DE COLISÃO
	--------------------------------------------------------

	local finalPosition =
		emergencyCollision(
			previousPosition,
			springPosition
		)

	positionSpring.p =
		finalPosition

	--------------------------------------------------------
	-- POSIÇÃO ATUAL DO JOGADOR
	--
	-- É recalculada depois da posição para que a mira
	-- sempre persiga o jogador atual, não um ponto velho.
	--------------------------------------------------------

	targetPosition =
		getLookTarget()

	if not targetPosition then
		return
	end

	local exactDirection =
		targetPosition - finalPosition

	if exactDirection.Magnitude <= 0.001 then
		return
	end

	local targetAngles =
		directionToAngles(
			exactDirection
		)

	--------------------------------------------------------
	-- YAW PELO CAMINHO MAIS CURTO
	--
	-- Isso NÃO limita 360 graus.
	--------------------------------------------------------

	targetAngles =
		Vector2.new(
			targetAngles.X,

			shortestAngle(
				aimSpring.p.Y,
				targetAngles.Y
			)
		)

	--------------------------------------------------------
	-- SOFT-ZONE DINÂMICA
	--
	-- Pequena diferença:
	-- câmera deixa acontecer.
	--
	-- Grande diferença:
	-- câmera aumenta a força da correção.
	--------------------------------------------------------

	local aimFrequency =
		calculateAimFrequency(
			aimSpring.p,
			targetAngles
		)

	aimSpring:SetFreq(
		aimFrequency
	)

	--------------------------------------------------------
	-- SPRING DE MIRA
	--------------------------------------------------------

	local smoothAngles =
		aimSpring:Update(
			dt,
			targetAngles
		)

	local smoothDirection =
		anglesToDirection(
			smoothAngles
		)

	--------------------------------------------------------
	-- CÂMERA FINAL
	--------------------------------------------------------

	camera.CFrame =
		CFrame.lookAt(
			finalPosition,
			finalPosition
				+ smoothDirection,
			Vector3.yAxis
		)
end

------------------------------------------------------------
-- ENABLE
------------------------------------------------------------

local function enableCamera()
	if enabled then
		return
	end

	enabled = true

	resetCameraState()

	RunService:BindToRenderStep(
		BIND_NAME,
		Enum.RenderPriority.Camera.Value + 1,
		updateCamera
	)

	print("🎥 Premium Dynamic Camera: ON")
end

------------------------------------------------------------
-- DISABLE
------------------------------------------------------------

local function disableCamera()
	if not enabled then
		return
	end

	enabled = false

	RunService:UnbindFromRenderStep(
		BIND_NAME
	)

	positionSpring = nil
	aimSpring = nil

	clearRoute()

	print("🎥 Premium Dynamic Camera: OFF")
end

------------------------------------------------------------
-- TOGGLE
------------------------------------------------------------

local function toggleCamera()
	if enabled then
		disableCamera()
	else
		enableCamera()
	end
end

UserInputService.InputBegan:Connect(
	function(input, processed)
		if processed then
			return
		end

		if input.KeyCode == TOGGLE_KEY then
			toggleCamera()
		end
	end
)

------------------------------------------------------------
-- RESPAWN
------------------------------------------------------------

player.CharacterAdded:Connect(
	function()
		positionSpring = nil
		aimSpring = nil

		clearRoute()
	end
)

------------------------------------------------------------
-- CURRENT CAMERA
------------------------------------------------------------

Workspace:GetPropertyChangedSignal(
	"CurrentCamera"
):Connect(
	function()
		camera =
			Workspace.CurrentCamera

		if enabled then
			positionSpring = nil
			aimSpring = nil

			clearRoute()
		end
	end
)

------------------------------------------------------------
-- START
------------------------------------------------------------

enableCamera()
