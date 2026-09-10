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
-- MOVIMENTO
--
-- A posição NÃO usa Spring.
-- Usa suavização exponencial equivalente a ~0.1s.
------------------------------------------------------------

local POSITION_LERP_TIME = 0.10

------------------------------------------------------------
-- ROTAÇÃO
--
-- Spring criticamente amortecida estilo Freecam.
--
-- 5.2 = suave, mas sem ficar com sensação pesada
-- de atraso como 3.6.
------------------------------------------------------------

local ROTATION_FREQUENCY = 5.2

------------------------------------------------------------
-- COMPENSAÇÃO HORIZONTAL LEVE
--
-- Serve apenas para compensar um pouco o atraso criado
-- pelo Lerp da posição quando o personagem se move rápido.
--
-- Não tenta colocar a câmera atrás do personagem.
------------------------------------------------------------

local POSITION_YAW_ASSIST = 0.35

local YAW_SOFT_ZONE = math.rad(4)

local MAX_YAW_ASSIST = math.rad(6)

------------------------------------------------------------
-- ALVO
------------------------------------------------------------

local LOOK_OFFSET = Vector3.new(0, 1.45, 0)

------------------------------------------------------------
-- SPRING
--
-- Usada APENAS na rotação.
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
	local f =
		self.f
		* 2
		* math.pi

	local p0 = self.p
	local v0 = self.v

	local offset =
		goal - p0

	local decay =
		math.exp(
			-f * dt
		)

	local p1 =
		goal
		+ (
			v0 * dt
			- offset
			* (
				f * dt + 1
			)
		)
		* decay

	local v1 =
		(
			f * dt
			* (
				offset * f
				- v0
			)
			+ v0
		)
		* decay

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

------------------------------------------------------------
-- POSIÇÃO SUAVIZADA
------------------------------------------------------------

local smoothPosition = nil

------------------------------------------------------------
-- ROTAÇÃO SUAVIZADA
------------------------------------------------------------

local rotationSpring = nil

------------------------------------------------------------
-- CÂMERA ORIGINAL
--
-- Guarda o resultado do CameraModule do Roblox.
--
-- Antes do CameraModule rodar no próximo frame,
-- restauramos esse CFrame para nossa suavização não
-- entrar novamente no cálculo interno do Roblox.
------------------------------------------------------------

local lastRawCameraCFrame = nil

------------------------------------------------------------
-- CHARACTER
------------------------------------------------------------

local function getCharacter()
	local character =
		player.Character

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

	if
		not character
		or
		not root
	then
		return nil
	end

	return
		root.Position
		+ LOOK_OFFSET
end

------------------------------------------------------------
-- LERP INDEPENDENTE DE FPS
--
-- Em vez de usar um alpha fixo por frame:
--
-- alpha = 1 - exp(-dt / tempo)
--
-- Assim 30 FPS, 60 FPS, 120 FPS etc.
-- mantêm praticamente a mesma sensação.
------------------------------------------------------------

local function lerpAlphaFromTime(
	dt,
	lerpTime
)

	if lerpTime <= 0 then
		return 1
	end

	return
		1
		- math.exp(
			-dt / lerpTime
		)
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
		% (
			2 * math.pi
		)
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
	if
		direction.Magnitude
		<= 0.0001
	then
		return 0
	end

	direction =
		direction.Unit

	return
		math.atan2(
			-direction.X,
			-direction.Z
		)
end

------------------------------------------------------------
-- COMPENSAÇÃO DO LERP DA POSIÇÃO
--
-- Exemplo:
--
-- Roblox queria câmera aqui:
--
--       A
--
-- mas o Lerp ainda está aqui:
--
--   B
--
-- Como B está atrasado, o personagem pode sair um pouco
-- lateralmente do campo de visão.
--
-- Essa função corrige SÓ essa diferença.
------------------------------------------------------------

local function calculatePositionYawAssist(
	rawPosition,
	currentSmoothPosition,
	targetPosition
)

	local rawDirection =
		targetPosition
		- rawPosition

	local smoothDirection =
		targetPosition
		- currentSmoothPosition

	if
		rawDirection.Magnitude
		<= 0.001
		or
		smoothDirection.Magnitude
		<= 0.001
	then
		return 0
	end

	local rawTargetYaw =
		directionToYaw(
			rawDirection
		)

	local smoothTargetYaw =
		directionToYaw(
			smoothDirection
		)

	local difference =
		shortestAngleDelta(
			rawTargetYaw,
			smoothTargetYaw
		)

	--------------------------------------------------------
	-- SOFT ZONE
	--
	-- Pequenos desvios continuam naturais.
	--------------------------------------------------------

	local outside =
		math.max(
			math.abs(
				difference
			)
			- YAW_SOFT_ZONE,
			0
		)

	if outside <= 0 then
		return 0
	end

	local correction =
		math.sign(
			difference
		)
		* outside
		* POSITION_YAW_ASSIST

	return
		math.clamp(
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

	smoothPosition =
		rawCFrame.Position

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
-- ANTES do CameraModule.
--
-- Remove nosso efeito do frame passado.
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
-- DEPOIS do CameraModule.
------------------------------------------------------------

local function postCameraUpdate(dt)
	camera =
		Workspace.CurrentCamera

	if not camera then
		return
	end

	if
		not smoothPosition
		or
		not rotationSpring
	then
		resetCameraState()
		return
	end

	--------------------------------------------------------
	-- RESULTADO ORIGINAL DO ROBLOX
	--------------------------------------------------------

	local rawCFrame =
		camera.CFrame

	--------------------------------------------------------
	-- Guarda ANTES de aplicar nossa suavização.
	--------------------------------------------------------

	lastRawCameraCFrame =
		rawCFrame

	--------------------------------------------------------
	-- POSIÇÃO
	--
	-- Lerp de aproximadamente 0.1 segundo.
	--------------------------------------------------------

	local positionAlpha =
		lerpAlphaFromTime(
			dt,
			POSITION_LERP_TIME
		)

	smoothPosition =
		smoothPosition:Lerp(
			rawCFrame.Position,
			positionAlpha
		)

	--------------------------------------------------------
	-- ROTAÇÃO ORIGINAL DO ROBLOX
	--------------------------------------------------------

	local rawPitch, rawYaw =
		rawCFrame:ToOrientation()

	--------------------------------------------------------
	-- YAW CONTÍNUO
	--
	-- Resolve passagem:
	--
	-- +179°
	--   ↓
	-- -179°
	--
	-- sem fazer a Spring tentar percorrer quase 360°.
	--------------------------------------------------------

	local targetYaw =
		closestAngle(
			rotationSpring.p.Y,
			rawYaw
		)

	--------------------------------------------------------
	-- ASSISTÊNCIA LEVE DE POSIÇÃO
	--------------------------------------------------------

	local targetPosition =
		getLookTarget()

	if targetPosition then

		local yawAssist =
			calculatePositionYawAssist(
				rawCFrame.Position,
				smoothPosition,
				targetPosition
			)

		targetYaw +=
			yawAssist
	end

	--------------------------------------------------------
	-- ROTATION SPRING
	--
	-- SOMENTE a rotação passa pela Spring.
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

	--------------------------------------------------------
	-- CÂMERA FINAL
	--------------------------------------------------------

	camera.CFrame =
		CFrame.new(
			smoothPosition
		)
		*
		CFrame.fromOrientation(
			smoothRotation.X,
			smoothRotation.Y,
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

	smoothPosition = nil
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

		if
			input.KeyCode
			== TOGGLE_KEY
		then

			toggleCamera()

		end
	end
)

------------------------------------------------------------
-- RESPAWN
------------------------------------------------------------

player.CharacterAdded:Connect(
	function()

		smoothPosition = nil
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

			smoothPosition = nil
			rotationSpring = nil

			lastRawCameraCFrame = nil

		end
	end
)

------------------------------------------------------------
-- START
------------------------------------------------------------

enableCamera()
