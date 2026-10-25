cask "claudo" do
  version "1.0"
  sha256 "456bdd3704f5d45743b786e9b51dbc07577c6ca3f25e212b63228a790b3494c7"

  url "https://github.com/aspasskiy/claudo/releases/download/v#{version}/Claudo-#{version}.zip"
  name "Claudo"
  desc "Menu bar task manager planned by Claude from your Claude Code sessions"
  homepage "https://github.com/aspasskiy/claudo"

  depends_on macos: :sonoma

  app "Claudo.app"

  uninstall launchctl: "site.spasskiy.claudo",
            quit:      "site.spasskiy.claudo",
            delete:    "~/Library/LaunchAgents/site.spasskiy.claudo.plist"

  zap trash: [
    "~/Library/Application Support/Claudo",
    "~/Library/Preferences/site.spasskiy.claudo.plist",
  ]
end
