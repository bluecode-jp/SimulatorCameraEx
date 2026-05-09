cask "simulatorcamera" do
  version "1.0.0"
  sha256 "REPLACE_WITH_ACTUAL_DMG_SHA256_ON_RELEASE"

  url "https://github.com/dautovri/SimulatorCamera/releases/download/v#{version}/SimulatorCamera-#{version}.dmg",
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

  app "SimulatorCamera.app"

  binary "#{appdir}/SimulatorCamera.app/Contents/MacOS/simcamctl"

  uninstall delete: [
    "/Applications/SimulatorCamera.app",
  ]

  zap trash: [
    "~/Library/Preferences/com.dautov.SimulatorCamera.plist",
    "~/Library/Application Support/SimulatorCamera",
    "~/Library/Containers/com.dautov.SimulatorCamera",
    "~/Library/Containers/com.dautov.SimulatorCamera.Extension",
  ]
end
