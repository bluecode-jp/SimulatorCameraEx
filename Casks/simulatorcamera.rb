cask "simulatorcamera" do
  version "1.0.0"
  sha256 "REPLACE_WITH_ACTUAL_DMG_SHA256_ON_RELEASE"

  url "https://github.com/dautovri/SimulatorCamera/releases/download/v#{version}/SimulatorCameraEx-#{version}.dmg",
      verified: "github.com/dautovri/SimulatorCamera/"
  name "SimulatorCamera"
  desc "Open-source virtual camera for the iOS Simulator (Camera Extension)"
  homepage "https://github.com/dautovri/SimulatorCamera"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "SimulatorCameraEx.app"

  binary "#{appdir}/SimulatorCameraEx.app/Contents/MacOS/simcamctl"

  uninstall delete: [
    "/Applications/SimulatorCameraEx.app",
  ]

  zap trash: [
    "~/Library/Preferences/jp.co.bluecode.SimulatorCameraEx.plist",
    "~/Library/Application Support/SimulatorCamera",
    "~/Library/Containers/jp.co.bluecode.SimulatorCameraEx",
    "~/Library/Containers/jp.co.bluecode.SimulatorCameraEx.Extension",
  ]
end
