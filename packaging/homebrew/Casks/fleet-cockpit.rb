# Cask for the native app. Lives in your tap: github.com/<you>/homebrew-tap/Casks/
# (named fleet-cockpit because `brew install --cask fleet` is already JetBrains Fleet).
cask "fleet-cockpit" do
  version "0.3.0"
  sha256 "REPLACE_WITH_SHA256_OF_Fleet-0.3.0.dmg"   # printed by app/make-dmg.sh

  url "https://github.com/REPLACE-ME/fleet/releases/download/v#{version}/Fleet-#{version}.dmg"
  name "Fleet"
  desc "Tiled cockpit for Claude Code and Codex: cost HUD, git-worktree screens, power control"
  homepage "https://REPLACE-ME.example"

  depends_on macos: ">= :ventura"

  app "Fleet.app"

  zap trash: "~/.config/fleet"
end
