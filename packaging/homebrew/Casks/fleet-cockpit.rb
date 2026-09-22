# Cask for the native app. Lives in your tap: github.com/<you>/homebrew-tap/Casks/
# (named fleet-cockpit because `brew install --cask fleet` is already JetBrains Fleet).
cask "fleet-cockpit" do
  version "0.3.0"
  sha256 "b77330653f61de7245a3cf4648105838cfed28399709693f92f04f07f9add52f"   # printed by app/make-dmg.sh

  url "https://github.com/hotgarlicprawns/fleet/releases/download/v#{version}/Fleet-#{version}.dmg"
  name "Fleet"
  desc "Tiled cockpit for Claude Code and Codex: cost HUD, git-worktree screens, power control"
  homepage "https://github.com/hotgarlicprawns/fleet"

  depends_on macos: ">= :ventura"

  app "Fleet.app"

  zap trash: "~/.config/fleet"
end
