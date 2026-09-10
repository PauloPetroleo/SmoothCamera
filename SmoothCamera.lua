local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local BIND_NAME = "SmoothCamera"
local TOGGLE_KEY = Enum.KeyCode.V
local SMOOTHNESS = 5

local enabled = false
local smoothRotation

local function enableSmoothCamera()
	if enabled then return end
	enabled = true

	camera = workspace.CurrentCamera
	smoothRotation = camera.CFrame.Rotation

	RunService:BindToRenderStep(
		BIND_NAME,
		Enum.RenderPriority.Camera.Value + 1,
		function(dt)
			camera = workspace.CurrentCamera

			local position = camera.CFrame.Position
			local desiredRotation = camera.CFrame.Rotation
			local alpha = 1 - math.exp(-SMOOTHNESS * dt)

			smoothRotation = smoothRotation:Lerp(
				desiredRotation,
				alpha
			)

			camera.CFrame =
				CFrame.new(position) * smoothRotation
		end
	)

	print("🎥 Câmera suave: ON")
end

local function disableSmoothCamera()
	if not enabled then return end
	enabled = false

	RunService:UnbindFromRenderStep(BIND_NAME)

	camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom

	print("🎥 Câmera suave: OFF")
end

local function toggle()
	if enabled then
		disableSmoothCamera()
	else
		enableSmoothCamera()
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end

	if input.KeyCode == TOGGLE_KEY then
		toggle()
	end
end)

enableSmoothCamera()
