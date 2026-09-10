local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------

local PRE_BIND_NAME = "SmoothCamera_Pre"
local POST_BIND_NAME = "SmoothCamera_Post"

local TOGGLE_KEY = Enum.KeyCode.V

------------------------------------------------------------
-- SUAVIZAÇÃO
------------------------------------------------------------

-- Posição:
-- maior = acompanha mais rápido
local POSITION_FREQUENCY = 5.8

-- Rotação:
-- valor mediano para dar aquela sensação suave
-- sem deixar a câmera pesada.
local ROTATION_FREQUENCY = 6.5

------------------------------------------------------------
-- COMPENSAÇÃO DO ATRASO DA POSIÇÃO
--
-- Não força a câmera a ficar atrás do personagem.
-- Só corrige um pouco o erro criado pela Spring de posição.
------------------------------------------------------------

local POSITION_YAW_ASSIST = 0.65

local YAW_SOFT_ZONE = math.rad(3.5)

local MAX_YAW_ASSIST = math.rad(10)

------------------------------------------------------------
-- ALVO
------------------------------------------------------------

local LOOK_OFFSET = Vector3.new(0, 1.45, 0)

------------------------------------------------------------
-- SPRING
--
-- Criticamente amortecida, estilo Freecam.
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
local rotationSpring = nil

------------------------------------------------------------
-- CAMERA RAW
--
-- Guarda a câmera produzida originalmente pelo Roblox.
--
-- Antes do CameraModule calcular o próximo frame,
-- restauramos essa versão.
------------------------------------------------------------

local lastRawCameraCFrame = nil

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

------------------------------------------------------------
-- ANGLE UTILS
------------------------------------------------------------

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

local function closestAngle(
	current,
	target
)

	return
		current
		+ shortestAngleDelta(
			current,
			target
		)
end

local function directionToYaw(direction)
	if direction.Magnitude <= 0.0001 then
		return 0
	end

	direction = direction.Unit

	return math.atan2(
		-direction.X,
		-direction.Z
	)
end

------------------------------------------------------------
-- COMPENSAÇÃO DA POSIÇÃO
--
-- Compara:
--
-- câmera original -> jogador
--
-- com:
--
-- câmera suavizada -> jogador
--
-- Corrige só a diferença causada pelo atraso da posição.
------------------------------------------------------------

local function calculatePositionYawAssist(
	rawPosition,
	smoothPosition,
	targetPosition
)

	local rawDirection =
		targetPosition
		- rawPosition

	local smoothDirection =
		targetPosition
		- smoothPosition

	if
		rawDirection.Magnitude <= 0.001
		or
		smoothDirection.Magnitude <= 0.001
	then

		return 0

	end

	local rawYaw =
		directionToYaw(
			rawDirection
		)

	local smoothYaw =
		directionToYaw(
			smoothDirection
		)

	local difference =
		shortestAngleDelta(
			rawYaw,
			smoothYaw
		)

	--------------------------------------------------------
	-- SOFT ZONE
	--------------------------------------------------------

	local amount =
		math.max(
			math.abs(difference)
				- YAW_SOFT_ZONE,
			0
		)

	if amount <= 0 then
		return 0
	end

	local correction =
		math.sign(difference)
		* amount
		* POSITION_YAW_ASSIST

	return math.clamp(
		correction,
		-MAX_YAW_ASSIST,
		MAX_YAW_ASSIST
	)
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

	--------------------------------------------------------
	-- POSIÇÃO
	--------------------------------------------------------

	positionSpring =
		Spring.new(
			POSITION_FREQUENCY,
			rawCFrame.Position
		)

	--------------------------------------------------------
	-- ROTAÇÃO
	--------------------------------------------------------

	local pitch, yaw =
		rawCFrame:ToOrientation()

	rotationSpring =
		Spring.new(
			ROTATION_FREQUENCY,
			Vector2.new(
				pitch,
				yaw
			)
		)
end

------------------------------------------------------------
-- PRE CAMERA
--
-- Roda antes da câmera padrão do Roblox.
--
-- Remove nosso efeito do frame anterior para o
-- CameraModule não usar nossa câmera suavizada como base.
------------------------------------------------------------

local function preCameraUpdate()
	if not enabled then
		return
	end

	camera =
		Workspace.CurrentCamera

	if
		not camera
		or
		not lastRawCameraCFrame
	then

		return

	end

	camera.CFrame =
		lastRawCameraCFrame
end

------------------------------------------------------------
-- POST CAMERA
--
-- Roda depois da câmera padrão do Roblox.
------------------------------------------------------------

local function postCameraUpdate(dt)
	camera =
		Workspace.CurrentCamera

	if not camera then
		return
	end

	if
		not positionSpring
		or
		not rotationSpring
	then

		resetCameraState()
		return
	end

	--------------------------------------------------------
	-- CAMERA ORIGINAL DO ROBLOX
	--------------------------------------------------------

	local rawCFrame =
		camera.CFrame

	--------------------------------------------------------
	-- Guarda antes de aplicar qualquer efeito.
	--------------------------------------------------------

	lastRawCameraCFrame =
		rawCFrame

	--------------------------------------------------------
	-- POSIÇÃO SUAVE
	--------------------------------------------------------

	positionSpring:SetFreq(
		POSITION_FREQUENCY
	)

	local smoothPosition =
		positionSpring:Update(
			dt,
			rawCFrame.Position
		)

	--------------------------------------------------------
	-- ROTAÇÃO RAW
	--------------------------------------------------------

	local rawPitch, rawYaw =
		rawCFrame:ToOrientation()

	--------------------------------------------------------
	-- Evita problema quando YAW cruza:
	--
	-- +180° -> -180°
	--------------------------------------------------------

	local targetYaw =
		closestAngle(
			rotationSpring.p.Y,
			rawYaw
		)

	--------------------------------------------------------
	-- PEQUENA COMPENSAÇÃO DO ATRASO DA POSIÇÃO
	--------------------------------------------------------

	local targetPosition =
		getLookTarget()

	local yawAssist = 0

	if targetPosition then

		yawAssist =
			calculatePositionYawAssist(
				rawCFrame.Position,
				smoothPosition,
				targetPosition
			)

	end

	targetYaw += yawAssist

	--------------------------------------------------------
	-- SPRING DE ROTAÇÃO
	--------------------------------------------------------

	rotationSpring:SetFreq(
		ROTATION_FREQUENCY
	)

	local smoothRotation =
		rotationSpring:Update(
			dt,
			Vector2.new(
				rawPitch,
				targetYaw
			)
		)

	local smoothPitch =
		smoothRotation.X

	local smoothYaw =
		smoothRotation.Y

	--------------------------------------------------------
	-- CÂMERA FINAL
	--------------------------------------------------------

	camera.CFrame =
		CFrame.new(
			smoothPosition
		)
		*
		CFrame.fromOrientation(
			smoothPitch,
			smoothYaw,
			0
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
		"🎥 Smooth Camera: ON"
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
	-- DEVOLVE A CÂMERA ORIGINAL DO ROBLOX
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
	rotationSpring = nil

	lastRawCameraCFrame = nil

	print(
		"🎥 Smooth Camera: OFF"
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
		rotationSpring = nil

		lastRawCameraCFrame = nil

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
			rotationSpring = nil

			lastRawCameraCFrame = nil

		end
	end
)

------------------------------------------------------------
-- START
------------------------------------------------------------

enableCamera()
