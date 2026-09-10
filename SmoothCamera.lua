local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------

local PRE_BIND_NAME = "PremiumDynamicCamera_Pre"
local POST_BIND_NAME = "PremiumDynamicCamera_Post"

local TOGGLE_KEY = Enum.KeyCode.V

------------------------------------------------------------
-- MOVIMENTO
------------------------------------------------------------

local POSITION_FREQUENCY = 5.2

------------------------------------------------------------
-- ASSISTÊNCIA HORIZONTAL
--
-- IMPORTANTE:
--
-- Ela NÃO mira diretamente no personagem.
--
-- Ela compensa somente o deslocamento horizontal
-- causado pela posição suavizada da câmera.
------------------------------------------------------------

local AIM_FREQUENCY_MIN = 3.8
local AIM_FREQUENCY_MAX = 8.0

-- Pequenos erros ficam naturais.
local SOFT_ZONE_YAW = math.rad(3.5)

-- Intensidade para atingir frequência máxima.
local AIM_FULL_ASSIST = 3.0

-- Limite absoluto da compensação.
local MAX_YAW_CORRECTION = math.rad(14)

------------------------------------------------------------
-- COLISÃO
------------------------------------------------------------

local CAMERA_RADIUS = 0.35
local WALL_PADDING = 0.20

------------------------------------------------------------
-- ROTEAMENTO
------------------------------------------------------------

local WAYPOINT_REACHED_DISTANCE = 0.55

local ROUTE_REPLAN_INTERVAL = 0.055
local DIRECT_PATH_HOLD = 0.025

local MAX_ROUTE_AGE = 0.65

local ROUTE_STUCK_TIME = 0.18
local ROUTE_PROGRESS_EPSILON = 0.035

-- Menos amostras que antes.
-- Isso reduz MUITO o número de Spherecasts.
local ROUTE_SAMPLE_DISTANCES = {
	1.15,
	2.25,
	3.5,
}

-- Só os melhores primeiros candidatos
-- podem gerar uma rota de dois pontos.
local MAX_DOUBLE_ROUTE_STARTS = 6

local VERTICAL_ROUTE_PENALTY = 0.65
local TURN_ROUTE_PENALTY = 0.35

------------------------------------------------------------
-- ALVO
------------------------------------------------------------

local LOOK_OFFSET = Vector3.new(0, 1.45, 0)

------------------------------------------------------------
-- SPRING
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

local positionSpring = nil
local yawCorrectionSpring = nil

------------------------------------------------------------
-- CAMERA RAW
--
-- Guarda o CFrame produzido pelo Roblox SEM nosso efeito.
--
-- Antes do CameraModule rodar no próximo frame,
-- restauramos esse CFrame.
------------------------------------------------------------

local lastRawCameraCFrame = nil

------------------------------------------------------------
-- ÚLTIMA POSIÇÃO SEGURA
------------------------------------------------------------

local lastSafePosition = nil

------------------------------------------------------------
-- ROUTE STATE
------------------------------------------------------------

local route = {}
local routeIndex = 1

local lastRoutePlan = 0
local directClearTimer = 0

local routeCreatedAt = 0
local routeLastProgressTime = 0
local routeBestDistance = math.huge

------------------------------------------------------------
-- CAST PARAMS
------------------------------------------------------------

local castParams = RaycastParams.new()

castParams.FilterType =
	Enum.RaycastFilterType.Exclude

castParams.IgnoreWater = true
castParams.RespectCanCollide = true

------------------------------------------------------------
-- OVERLAP PARAMS
------------------------------------------------------------

local overlapParams = OverlapParams.new()

overlapParams.FilterType =
	Enum.RaycastFilterType.Exclude

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
	local character, root =
		getCharacter()

	if not character or not root then
		return nil
	end

	return root.Position + LOOK_OFFSET
end

local function updateFilters()
	local character = player.Character

	if character then

		castParams.FilterDescendantsInstances = {
			character
		}

		overlapParams.FilterDescendantsInstances = {
			character
		}

	else

		castParams.FilterDescendantsInstances = {}
		overlapParams.FilterDescendantsInstances = {}

	end
end

------------------------------------------------------------
-- UTILS
------------------------------------------------------------

local function safeUnit(vector, fallback)
	if vector.Magnitude > 0.0001 then
		return vector.Unit
	end

	return fallback
		or Vector3.new(0, 0, -1)
end

local function clearRoute()
	table.clear(route)

	routeIndex = 1

	routeCreatedAt = 0
	routeLastProgressTime = 0
	routeBestDistance = math.huge
end

local function beginRoute(newRoute)
	route = newRoute
	routeIndex = 1

	local now = os.clock()

	routeCreatedAt = now
	routeLastProgressTime = now
	routeBestDistance = math.huge
end

local function currentWaypoint()
	return route[routeIndex]
end

------------------------------------------------------------
-- SPHERECAST
------------------------------------------------------------

local function castBetween(a, b)
	updateFilters()

	local direction =
		b - a

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
-- OVERLAP SAFETY
--
-- Spherecast sozinho pode ter problemas se a esfera
-- já estiver começando dentro de alguma geometria.
--
-- Isso funciona como uma segunda proteção.
------------------------------------------------------------

local function isSolidOverlap(position)
	updateFilters()

	local parts =
		Workspace:GetPartBoundsInRadius(
			position,
			CAMERA_RADIUS * 0.92,
			overlapParams
		)

	for _, part in ipairs(parts) do
		if
			part:IsA("BasePart")
			and
			part.CanCollide
			and
			part.Transparency < 1
		then

			return true
		end
	end

	return false
end

------------------------------------------------------------
-- POSIÇÃO SEGURA
------------------------------------------------------------

local function safePositionBeforeHit(
	a,
	b,
	hit
)

	if not hit then
		return b
	end

	local direction =
		safeUnit(b - a)

	local distance =
		math.max(
			hit.Distance
				- WALL_PADDING,
			0
		)

	return
		a
		+ direction * distance
end

------------------------------------------------------------
-- REMOVE VELOCIDADE PRA DENTRO DA PAREDE
------------------------------------------------------------

local function removeIntoSurfaceVelocity(normal)
	if not positionSpring then
		return
	end

	local velocity =
		positionSpring.v

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
--
-- Antes tínhamos 8 direções.
--
-- Agora são 6 e priorizamos contorno lateral.
------------------------------------------------------------

local function generateCandidates(hit)
	local candidates = {}

	local normal =
		hit.Normal

	local side, surfaceUp =
		getSurfaceBasis(normal)

	local base =
		hit.Position
		+ normal
		* (
			CAMERA_RADIUS
			+ WALL_PADDING
		)

	local directions = {

		side,
		-side,

		safeUnit(
			side + surfaceUp * 0.65
		),

		safeUnit(
			-side + surfaceUp * 0.65
		),

		safeUnit(
			side - surfaceUp * 0.45
		),

		safeUnit(
			-side - surfaceUp * 0.45
		),
	}

	for _, distance in ipairs(
		ROUTE_SAMPLE_DISTANCES
	) do

		for _, direction in ipairs(
			directions
		) do

			table.insert(
				candidates,

				base
				+ direction
				* distance
			)

		end
	end

	return candidates
end

------------------------------------------------------------
-- ROUTE SCORE
------------------------------------------------------------

local function routeScore(
	startPosition,
	points,
	finalGoal
)

	local score = 0

	local previousPosition =
		startPosition

	local previousDirection = nil

	for _, point in ipairs(points) do

		local delta =
			point
			- previousPosition

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
		finalGoal
		- previousPosition

	score += finalDelta.Magnitude

	score +=
		math.abs(finalDelta.Y)
		* VERTICAL_ROUTE_PENALTY

	return score
end

------------------------------------------------------------
-- SINGLE ROUTE
------------------------------------------------------------

local function findSingleRoute(
	startPosition,
	finalGoal,
	firstHit
)

	local bestRoute = nil
	local bestScore = math.huge

	for _, candidate in ipairs(
		generateCandidates(firstHit)
	) do

		if pathClear(
			startPosition,
			candidate
		) then

			if pathClear(
				candidate,
				finalGoal
			) then

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
	end

	return bestRoute
end

------------------------------------------------------------
-- PEGAR MELHORES PRIMEIROS CANDIDATOS
------------------------------------------------------------

local function getBestFirstCandidates(
	startPosition,
	finalGoal,
	firstHit
)

	local results = {}

	for _, point in ipairs(
		generateCandidates(firstHit)
	) do

		if pathClear(
			startPosition,
			point
		) then

			local score =
				(startPosition - point).Magnitude
				+
				(point - finalGoal).Magnitude

			score +=
				math.abs(
					point.Y
					- startPosition.Y
				)
				* VERTICAL_ROUTE_PENALTY

			table.insert(
				results,
				{
					point = point,
					score = score,
				}
			)

		end
	end

	table.sort(
		results,

		function(a, b)
			return a.score < b.score
		end
	)

	return results
end

------------------------------------------------------------
-- DOUBLE ROUTE
--
-- Agora NÃO testa todos contra todos.
------------------------------------------------------------

local function findDoubleRoute(
	startPosition,
	finalGoal,
	firstHit
)

	local bestRoute = nil
	local bestScore = math.huge

	local firstCandidates =
		getBestFirstCandidates(
			startPosition,
			finalGoal,
			firstHit
		)

	local amount =
		math.min(
			#firstCandidates,
			MAX_DOUBLE_ROUTE_STARTS
		)

	for i = 1, amount do

		local firstPoint =
			firstCandidates[i].point

		local secondHit =
			castBetween(
				firstPoint,
				finalGoal
			)

		if secondHit then

			local secondCandidates =
				generateCandidates(
					secondHit
				)

			for _, secondPoint in ipairs(
				secondCandidates
			) do

				if pathClear(
					firstPoint,
					secondPoint
				) then

					if pathClear(
						secondPoint,
						finalGoal
					) then

						local testRoute = {
							firstPoint,
							secondPoint,
						}

						local score =
							routeScore(
								startPosition,
								testRoute,
								finalGoal
							)

						if score < bestScore then

							bestScore =
								score

							bestRoute =
								testRoute

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

	--------------------------------------------------------
	-- PRIMEIRO: tenta deslizar naturalmente.
	--------------------------------------------------------

	local desired =
		finalGoal
		- startPosition

	local tangent =
		desired
		- hit.Normal
		* desired:Dot(hit.Normal)

	if tangent.Magnitude > 0.05 then

		local slideGoal =
			hit.Position
			+ hit.Normal
			* (
				CAMERA_RADIUS
				+ WALL_PADDING
			)
			+ tangent.Unit
			* math.min(
				tangent.Magnitude,
				1.5
			)

		if
			pathClear(
				startPosition,
				slideGoal
			)
			and
			pathClear(
				slideGoal,
				finalGoal
			)
		then

			return {
				slideGoal
			}

		end
	end

	--------------------------------------------------------
	-- UM WAYPOINT
	--------------------------------------------------------

	local single =
		findSingleRoute(
			startPosition,
			finalGoal,
			hit
		)

	if single then
		return single
	end

	--------------------------------------------------------
	-- DOIS WAYPOINTS
	--------------------------------------------------------

	local double =
		findDoubleRoute(
			startPosition,
			finalGoal,
			hit
		)

	if double then
		return double
	end

	--------------------------------------------------------
	-- FALLBACK
	--------------------------------------------------------

	return {
		safePositionBeforeHit(
			startPosition,
			finalGoal,
			hit
		)
	}
end

------------------------------------------------------------
-- ROTA AINDA É VÁLIDA?
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

	local previous =
		waypoint

	for i = routeIndex + 1, #route do

		local point =
			route[i]

		if not pathClear(
			previous,
			point
		) then

			return false

		end

		previous =
			point
	end

	return pathClear(
		previous,
		finalGoal
	)
end

------------------------------------------------------------
-- ATUALIZA PROGRESSO
------------------------------------------------------------

local function updateRouteProgress(
	position,
	finalGoal
)

	--------------------------------------------------------
	-- CAMINHO DIRETO?
	--------------------------------------------------------

	if pathClear(
		position,
		finalGoal
	) then

		clearRoute()
		return

	end

	--------------------------------------------------------
	-- PULA WAYPOINTS DESNECESSÁRIOS
	--------------------------------------------------------

	if #route > 0 then

		for i = #route, routeIndex + 1, -1 do

			if pathClear(
				position,
				route[i]
			) then

				routeIndex = i

				routeBestDistance =
					math.huge

				routeLastProgressTime =
					os.clock()

				break
			end
		end
	end

	--------------------------------------------------------
	-- CHEGOU NO WAYPOINT?
	--------------------------------------------------------

	while true do

		local waypoint =
			currentWaypoint()

		if not waypoint then
			break
		end

		local distance =
			(position - waypoint).Magnitude

		if
			distance
			<= WAYPOINT_REACHED_DISTANCE
		then

			routeIndex += 1

			routeBestDistance =
				math.huge

			routeLastProgressTime =
				os.clock()

		else

			break

		end
	end

	if routeIndex > #route then
		clearRoute()
	end
end

------------------------------------------------------------
-- ANTI-STUCK
------------------------------------------------------------

local function routeIsStuck(
	currentPosition,
	finalGoal
)

	local waypoint =
		currentWaypoint()

	if not waypoint then
		return false
	end

	local now =
		os.clock()

	--------------------------------------------------------
	-- ROTA ANTIGA
	--------------------------------------------------------

	if
		routeCreatedAt > 0
		and
		now - routeCreatedAt
		> MAX_ROUTE_AGE
	then

		return true

	end

	--------------------------------------------------------
	-- CAMINHO DIRETO ABRIU
	--------------------------------------------------------

	if pathClear(
		currentPosition,
		finalGoal
	) then

		return true

	end

	--------------------------------------------------------
	-- PROGRESSO
	--------------------------------------------------------

	local distance =
		(currentPosition - waypoint).Magnitude

	if
		distance
		<
		routeBestDistance
			- ROUTE_PROGRESS_EPSILON
	then

		routeBestDistance =
			distance

		routeLastProgressTime =
			now

		return false

	end

	if routeLastProgressTime == 0 then

		routeLastProgressTime =
			now

	end

	if
		now - routeLastProgressTime
		> ROUTE_STUCK_TIME
	then

		return true

	end

	return false
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
		currentPosition,
		finalGoal
	)

	--------------------------------------------------------
	-- DIRETO
	--------------------------------------------------------

	local directClear =
		pathClear(
			currentPosition,
			finalGoal
		)

	if directClear then

		directClearTimer += dt

		if
			directClearTimer
			>= DIRECT_PATH_HOLD
		then

			clearRoute()

			return finalGoal

		end

	else

		directClearTimer = 0

	end

	--------------------------------------------------------
	-- ROTA EXISTENTE
	--------------------------------------------------------

	local waypoint =
		currentWaypoint()

	if waypoint then

		if routeIsStuck(
			currentPosition,
			finalGoal
		) then

			clearRoute()

		elseif routeStillValid(
			currentPosition,
			finalGoal
		) then

			return waypoint

		else

			clearRoute()

		end
	end

	--------------------------------------------------------
	-- REPLAN RATE LIMIT
	--------------------------------------------------------

	local now =
		os.clock()

	if
		now - lastRoutePlan
		< ROUTE_REPLAN_INTERVAL
	then

		----------------------------------------------------
		-- TENTA DIRETO PRIMEIRO
		----------------------------------------------------

		if pathClear(
			currentPosition,
			finalGoal
		) then

			return finalGoal

		end

		----------------------------------------------------
		-- SLIDE BARATO
		----------------------------------------------------

		local hit =
			castBetween(
				currentPosition,
				finalGoal
			)

		if hit then

			local desired =
				finalGoal
				- currentPosition

			local tangent =
				desired
				- hit.Normal
				* desired:Dot(
					hit.Normal
				)

			if tangent.Magnitude > 0.05 then

				local slideGoal =
					hit.Position
					+ hit.Normal
					* (
						CAMERA_RADIUS
						+ WALL_PADDING
					)
					+ tangent.Unit
					* math.min(
						tangent.Magnitude,
						1.25
					)

				if pathClear(
					currentPosition,
					slideGoal
				) then

					return slideGoal

				end
			end

			return safePositionBeforeHit(
				currentPosition,
				finalGoal,
				hit
			)
		end

		return finalGoal
	end

	--------------------------------------------------------
	-- NOVA ROTA
	--------------------------------------------------------

	lastRoutePlan =
		now

	local newRoute =
		planRoute(
			currentPosition,
			finalGoal
		)

	if #newRoute > 0 then

		beginRoute(newRoute)

		return
			currentWaypoint()
			or finalGoal

	end

	clearRoute()

	return finalGoal
end

------------------------------------------------------------
-- ÂNGULOS
------------------------------------------------------------

local function directionToYaw(direction)
	direction =
		safeUnit(direction)

	return math.atan2(
		-direction.X,
		-direction.Z
	)
end

local function shortestAngleDelta(
	fromAngle,
	toAngle
)

	return
		(
			toAngle
			- fromAngle
			+ math.pi
		)
		% (2 * math.pi)
		- math.pi
end

------------------------------------------------------------
-- CORREÇÃO DE YAW
--
-- AQUI ESTÁ A MUDANÇA GRANDE.
--
-- NÃO fazemos:
--
-- raw camera -> personagem
--
-- Fazemos:
--
-- ângulo necessário da posição RAW até personagem
-- versus
-- ângulo necessário da posição SUAVIZADA até personagem
--
-- Ou seja:
-- corrigimos SOMENTE o erro criado pela Spring.
------------------------------------------------------------

local function calculateYawCorrection(
	rawCameraCFrame,
	finalCameraPosition,
	targetPosition
)

	local rawPosition =
		rawCameraCFrame.Position

	--------------------------------------------------------
	-- DIREÇÃO DO ALVO A PARTIR DA CÂMERA ORIGINAL
	--------------------------------------------------------

	local rawTargetDirection =
		targetPosition
		- rawPosition

	if rawTargetDirection.Magnitude <= 0.001 then
		return 0
	end

	--------------------------------------------------------
	-- DIREÇÃO DO ALVO A PARTIR DA POSIÇÃO SUAVIZADA
	--------------------------------------------------------

	local smoothTargetDirection =
		targetPosition
		- finalCameraPosition

	if smoothTargetDirection.Magnitude <= 0.001 then
		return 0
	end

	local rawTargetYaw =
		directionToYaw(
			rawTargetDirection
		)

	local smoothTargetYaw =
		directionToYaw(
			smoothTargetDirection
		)

	--------------------------------------------------------
	-- DIFERENÇA CRIADA SOMENTE PELO ATRASO DA POSIÇÃO
	--------------------------------------------------------

	local yawDifference =
		shortestAngleDelta(
			rawTargetYaw,
			smoothTargetYaw
		)

	--------------------------------------------------------
	-- SOFT ZONE
	--------------------------------------------------------

	local outside =
		math.max(
			math.abs(yawDifference)
				- SOFT_ZONE_YAW,
			0
		)

	if outside <= 0 then
		return 0
	end

	local correction =
		math.sign(yawDifference)
		* outside

	return math.clamp(
		correction,
		-MAX_YAW_CORRECTION,
		MAX_YAW_CORRECTION
	)
end

------------------------------------------------------------
-- AIM FREQUENCY
------------------------------------------------------------

local function calculateAimFrequency(
	yawCorrection
)

	local normalized =
		math.abs(yawCorrection)
		/
		math.max(
			SOFT_ZONE_YAW,
			0.001
		)

	local t =
		math.clamp(
			normalized
				/ AIM_FULL_ASSIST,
			0,
			1
		)

	-- SmoothStep
	t =
		t * t
		* (3 - 2 * t)

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

	if hit then

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

		clearRoute()

		return safePosition
	end

	--------------------------------------------------------
	-- SEGUNDA PROTEÇÃO:
	-- detectar se terminamos dentro da geometria.
	--------------------------------------------------------

	if isSolidOverlap(newPosition) then

		----------------------------------------------------
		-- Volta para última posição realmente segura.
		----------------------------------------------------

		if
			lastSafePosition
			and
			not isSolidOverlap(
				lastSafePosition
			)
		then

			positionSpring.p =
				lastSafePosition

			positionSpring.v =
				Vector3.zero

			clearRoute()

			return lastSafePosition
		end

		----------------------------------------------------
		-- Se não existe uma posição anterior segura,
		-- simplesmente não avança nesse frame.
		----------------------------------------------------

		positionSpring.p =
			oldPosition

		positionSpring.v =
			Vector3.zero

		clearRoute()

		return oldPosition
	end

	--------------------------------------------------------
	-- POSIÇÃO BOA
	--------------------------------------------------------

	lastSafePosition =
		newPosition

	return newPosition
end

------------------------------------------------------------
-- RESET
------------------------------------------------------------

local function resetCameraState()
	camera =
		Workspace.CurrentCamera

	if not camera then
		return
	end

	local rawCFrame =
		camera.CFrame

	lastRawCameraCFrame =
		rawCFrame

	local position =
		rawCFrame.Position

	positionSpring =
		Spring.new(
			POSITION_FREQUENCY,
			position
		)

	yawCorrectionSpring =
		Spring.new(
			AIM_FREQUENCY_MIN,
			0
		)

	lastSafePosition =
		position

	clearRoute()

	directClearTimer = 0
	lastRoutePlan = 0
end

------------------------------------------------------------
-- PRE CAMERA
--
-- Roda ANTES do CameraModule.
--
-- Remove completamente o nosso efeito visual anterior,
-- então o Roblox não usa nossa câmera modificada
-- como ponto inicial do próximo frame.
------------------------------------------------------------

local function preCameraUpdate()
	if not enabled then
		return
	end

	camera =
		Workspace.CurrentCamera

	if not camera then
		return
	end

	if lastRawCameraCFrame then

		camera.CFrame =
			lastRawCameraCFrame

	end
end

------------------------------------------------------------
-- POST CAMERA
--
-- Roda DEPOIS do CameraModule.
------------------------------------------------------------

local function postCameraUpdate(dt)
	camera =
		Workspace.CurrentCamera

	if not camera then
		return
	end

	local targetPosition =
		getLookTarget()

	if not targetPosition then
		return
	end

	if
		not positionSpring
		or
		not yawCorrectionSpring
	then

		resetCameraState()
		return
	end

	--------------------------------------------------------
	-- CFRAME ORIGINAL DO ROBLOX DESTE FRAME
	--------------------------------------------------------

	local rawCameraCFrame =
		camera.CFrame

	--------------------------------------------------------
	-- GUARDA PARA RESTAURAR NO PRÓXIMO PRE-STEP
	--------------------------------------------------------

	lastRawCameraCFrame =
		rawCameraCFrame

	local desiredPosition =
		rawCameraCFrame.Position

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
	-- POSITION SPRING
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
	-- COLLISION
	--------------------------------------------------------

	local finalPosition =
		emergencyCollision(
			previousPosition,
			springPosition
		)

	positionSpring.p =
		finalPosition

	--------------------------------------------------------
	-- ALVO ATUALIZADO
	--------------------------------------------------------

	targetPosition =
		getLookTarget()

	if not targetPosition then
		return
	end

	--------------------------------------------------------
	-- YAW ASSIST
	--
	-- COMPENSA SÓ A DIFERENÇA CRIADA
	-- PELA POSIÇÃO SUAVIZADA.
	--------------------------------------------------------

	local desiredYawCorrection =
		calculateYawCorrection(
			rawCameraCFrame,
			finalPosition,
			targetPosition
		)

	local aimFrequency =
		calculateAimFrequency(
			desiredYawCorrection
		)

	yawCorrectionSpring:SetFreq(
		aimFrequency
	)

	local smoothYawCorrection =
		yawCorrectionSpring:Update(
			dt,
			desiredYawCorrection
		)

	--------------------------------------------------------
	-- MANTÉM TODA A ROTAÇÃO ORIGINAL DO ROBLOX
	--
	-- Inclusive pitch, mobile follow etc.
	--
	-- E apenas adiciona yaw local/global.
	--------------------------------------------------------

	local rawRotation =
		rawCameraCFrame.Rotation

	local yawRotation =
		CFrame.Angles(
			0,
			smoothYawCorrection,
			0
		)

	--------------------------------------------------------
	-- YAW É APLICADO EM WORLD SPACE.
	--
	-- Isso evita alterar pitch.
	--------------------------------------------------------

	local finalRotation =
		yawRotation
		* rawRotation

	--------------------------------------------------------
	-- CAMERA FINAL
	--------------------------------------------------------

	camera.CFrame =
		CFrame.new(
			finalPosition
		)
		* finalRotation
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

	--------------------------------------------------------
	-- ANTES DO CAMERA MODULE
	--------------------------------------------------------

	RunService:BindToRenderStep(
		PRE_BIND_NAME,
		Enum.RenderPriority.Camera.Value - 1,
		preCameraUpdate
	)

	--------------------------------------------------------
	-- DEPOIS DO CAMERA MODULE
	--------------------------------------------------------

	RunService:BindToRenderStep(
		POST_BIND_NAME,
		Enum.RenderPriority.Camera.Value + 1,
		postCameraUpdate
	)

	print(
		"🎥 Premium Dynamic Camera: ON"
	)
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
		PRE_BIND_NAME
	)

	RunService:UnbindFromRenderStep(
		POST_BIND_NAME
	)

	--------------------------------------------------------
	-- RESTAURA A ÚLTIMA CÂMERA LIMPA
	--------------------------------------------------------

	camera =
		Workspace.CurrentCamera

	if
		camera
		and
		lastRawCameraCFrame
	then

		camera.CFrame =
			lastRawCameraCFrame

	end

	positionSpring = nil
	yawCorrectionSpring = nil

	lastRawCameraCFrame = nil
	lastSafePosition = nil

	clearRoute()

	print(
		"🎥 Premium Dynamic Camera: OFF"
	)
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
		yawCorrectionSpring = nil

		lastRawCameraCFrame = nil
		lastSafePosition = nil

		clearRoute()

	end
)

------------------------------------------------------------
-- CURRENT CAMERA CHANGED
------------------------------------------------------------

Workspace:GetPropertyChangedSignal(
	"CurrentCamera"
):Connect(
	function()

		camera =
			Workspace.CurrentCamera

		if enabled then

			positionSpring = nil
			yawCorrectionSpring = nil

			lastRawCameraCFrame = nil
			lastSafePosition = nil

			clearRoute()

		end
	end
)

------------------------------------------------------------
-- START
------------------------------------------------------------

enableCamera()
