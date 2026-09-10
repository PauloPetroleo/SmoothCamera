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
-- ROTAÇÃO
--
-- SOMENTE a rotação é suavizada.
--
-- A posição fica 100% original do Roblox.
------------------------------------------------------------

local ROTATION_FREQUENCY = 5.6

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

local rotationSpring = nil

------------------------------------------------------------
-- CÂMERA ORIGINAL
--
-- Guarda o CFrame original produzido pelo CameraModule.
------------------------------------------------------------

local lastRawCameraCFrame = nil

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
-- Antes do CameraModule:
--
-- restaura a câmera RAW anterior.
--
-- Assim nossa suavização não entra novamente
-- no cálculo interno da câmera do Roblox.
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
-- mantém a POSIÇÃO exatamente como o Roblox produziu
-- e suaviza somente PITCH/YAW.
------------------------------------------------------------

local function postCameraUpdate(dt)
	camera =
		Workspace.CurrentCamera

	if not camera then
		return
	end

	if not rotationSpring then
		resetCameraState()
		return
	end

	--------------------------------------------------------
	-- CAMERA ORIGINAL DO ROBLOX
	--------------------------------------------------------

	local rawCFrame =
		camera.CFrame

	--------------------------------------------------------
	-- Guarda ANTES de aplicar nossa rotação.
	--------------------------------------------------------

	lastRawCameraCFrame =
		rawCFrame

	--------------------------------------------------------
	-- POSIÇÃO ORIGINAL
	--
	-- SEM LERP.
	-- SEM SPRING.
	-- SEM ATRASO.
	--------------------------------------------------------

	local rawPosition =
		rawCFrame.Position

	--------------------------------------------------------
	-- ROTAÇÃO ORIGINAL
	--------------------------------------------------------

	local rawPitch, rawYaw =
		rawCFrame:ToOrientation()

	--------------------------------------------------------
	-- YAW CONTÍNUO
	--
	-- Evita o salto:
	--
	-- +179°
	--   ↓
	-- -179°
	--------------------------------------------------------

	local targetYaw =
		closestAngle(
			rotationSpring.p.Y,
			rawYaw
		)

	--------------------------------------------------------
	-- ROTATION SPRING
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
	--
	-- POSIÇÃO = ORIGINAL ROBLOX
	-- ROTAÇÃO = SUAVIZADA
	--------------------------------------------------------

	camera.CFrame =
		CFrame.new(
			rawPosition
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

	RunService:BindToRenderStep(
		PRE_BIND_NAME,
		Enum.RenderPriority.Camera.Value - 1,
		preCameraUpdate
	)

	RunService:BindToRenderStep(
		POST_BIND_NAME,
		Enum.RenderPriority.Camera.Value + 1,
		postCameraUpdate
	)

	print(
		"🎥 Smooth Rotation Camera: ON"
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

	rotationSpring = nil
	lastRawCameraCFrame = nil

	print(
		"🎥 Smooth Rotation Camera: OFF"
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

			rotationSpring = nil
			lastRawCameraCFrame = nil

		end
	end
)

------------------------------------------------------------
-- START
------------------------------------------------------------

enableCamera()
