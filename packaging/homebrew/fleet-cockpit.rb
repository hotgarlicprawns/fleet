# Formula for the CLI (the `fleet` command). Lives in your tap: homebrew-tap/Formula/
class FleetCockpit < Formula
  desc "Tiled cockpit for Claude Code and Codex: cost HUD, worktrees, stay-awake control"
  homepage "https://github.com/hotgarlicprawns/fleet"
  url "https://registry.npmjs.org/fleet-cockpit/-/fleet-cockpit-0.3.0.tgz"
  sha256 "REPLACE_WITH_SHA256_OF_THE_NPM_TARBALL"   # shasum -a 256 fleet-cockpit-0.3.0.tgz
  license :cannot_represent

  depends_on :macos
  depends_on "node"
  depends_on "tmux"

  def install
    system "npm", "install", *std_npm_args
    bin.install_symlink Dir["#{libexec}/bin/*"]
  end

  test do
    assert_match "USAGE", shell_output("#{bin}/fleet help")
  end
end
