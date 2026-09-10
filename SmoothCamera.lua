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

-- Posição continua relativamente responsiva.
local POSITION_FREQUENCY = 5.8

-- Rotação bem mais calma e suave.
-- Menor = mais macia / mais atrasada.
local ROTATION_FREQUENCY = 3.6

------------------------------------------------------------
-- COMPENSAÇÃO DO ATRASO DA POSIÇÃO
--
-- Bem leve para não puxar a câmera agressivamente.
------------------------------------------------------------

local POSITION_YAW_ASSIST = 0.45

local YAW_SOFT_ZONE = math.rad(3.5)

local MAX_YAW_ASSIST = math.rad(7)

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
local rotationSpring = nil

-- Último CFrame produzido pela câmera ORIGINAL do Roblox.
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
-- COMPENSAÇÃO DO ATRASO DA POSIÇÃO
--
-- Não tenta apontar a câmera diretamente para o jogador.
--
-- Apenas mede a diferença causada pela posição suavizada
-- estar um pouco atrasada em relação à câmera original.
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
	--
	-- Pequenos desvios ficam completamente naturais.
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
	-- POSITION SPRING
	--------------------------------------------------------

	positionSpring =
		Spring.new(
			POSITION_FREQUENCY,
			rawCFrame.Position
		)

	--------------------------------------------------------
	-- ROTATION SPRING
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
-- Antes do CameraModule do Roblox:
--
-- restaura a câmera RAW anterior.
--
-- Isso impede nossa suavização de entrar novamente
-- no cálculo da câmera padrão no frame seguinte.
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
-- Depois do CameraModule:
--
-- pega o resultado original do Roblox e aplica
-- nossa suavização somente visualmente.
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

	-- Salva antes de modificarmos.
	lastRawCameraCFrame =
		rawCFrame

	--------------------------------------------------------
	-- POSIÇÃO
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
	-- ROTAÇÃO ORIGINAL
	--------------------------------------------------------

	local rawPitch, rawYaw =
		rawCFrame:ToOrientation()

	--------------------------------------------------------
	-- CONTINUIDADE DO YAW
	--
	-- Evita pulo quando cruza +180 / -180 graus.
	--------------------------------------------------------

	local targetYaw =
		closestAngle(
			rotationSpring.p.Y,
			rawYaw
		)

	--------------------------------------------------------
	-- ASSISTÊNCIA HORIZONTAL LEVE
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
	--
	-- 3.6 deixa a câmera entrar e sair da rotação
	-- de maneira bem mais tranquila.
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
	-- CAMERA FINAL
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
	-- DEVOLVE A CÂMERA ORIGINAL
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
