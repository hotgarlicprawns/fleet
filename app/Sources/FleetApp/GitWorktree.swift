import Foundation

/// Shells out to `git worktree` so each Screen can get its own isolated
/// checkout — separate branch, separate files, safe to run a different
/// agent in each without them touching the same working tree.
enum GitWorktree {
    struct Result2 { var ok: Bool; var output: String }

    private static func run(_ args: [String], cwd: String) -> Result2 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = UserEnv.path
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            return Result2(ok: p.terminationStatus == 0, output: out.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return Result2(ok: false, output: error.localizedDescription)
        }
    }

    static func isRepo(_ path: String) -> Bool {
        run(["rev-parse", "--is-inside-work-tree"], cwd: path).ok
    }

    static func repoRoot(_ path: String) -> String? {
        let r = run(["rev-parse", "--show-toplevel"], cwd: path)
        return r.ok ? r.output : nil
    }

    static func currentBranch(_ path: String) -> String? {
        let r = run(["branch", "--show-current"], cwd: path)
        return r.ok && !r.output.isEmpty ? r.output : nil
    }

    static func branchExists(_ repo: String, _ branch: String) -> Bool {
        run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], cwd: repo).ok
    }

    /// Creates (or reuses) `<repo>/../<repoName>-worktrees/<branch>` on `branch`,
    /// branching from the repo's current HEAD if the branch doesn't exist yet.
    @discardableResult
    static func createOrAttach(repo: String, branch: String) -> Result2 {
        guard let root = repoRoot(repo) else { return Result2(ok: false, output: "not a git repository") }
        let repoName = (root as NSString).lastPathComponent
        let base = (root as NSString).deletingLastPathComponent
        let dest = "\(base)/\(repoName)-worktrees/\(branch)"
        if FileManager.default.fileExists(atPath: dest) { return Result2(ok: true, output: dest) }
        try? FileManager.default.createDirectory(atPath: "\(base)/\(repoName)-worktrees", withIntermediateDirectories: true)
        let args = branchExists(root, branch)
            ? ["worktree", "add", dest, branch]
            : ["worktree", "add", "-b", branch, dest]
        let r = run(args, cwd: root)
        return Result2(ok: r.ok, output: r.ok ? dest : r.output)
    }

    /// Removes a screen's worktree WITHOUT --force: git refuses if there are
    /// uncommitted or untracked changes, so this can never destroy work. The
    /// branch is deleted with `-d` (merged branches only) for the same reason.
    static func remove(repo: String, worktree: String, deleteBranch branch: String? = nil) -> Result2 {
        guard let root = repoRoot(repo) else { return Result2(ok: false, output: "not a git repository") }
        let r = run(["worktree", "remove", worktree], cwd: root)
        guard r.ok else {
            let why = r.output.contains("contains modified or untracked files") ? "it has uncommitted changes" : r.output
            return Result2(ok: false, output: "worktree kept — \(why)")
        }
        var msg = "worktree removed"
        if let b = branch {
            let d = run(["branch", "-d", b], cwd: root)
            msg += d.ok ? ", branch \(b) deleted" : ", branch \(b) kept (not merged)"
        }
        return Result2(ok: true, output: msg)
    }

    /// Bring a screen's branch up to date with the base branch (default main).
    static func sync(worktree: String, base: String) -> Result2 {
        let fetch = run(["fetch", "origin", base], cwd: worktree)
        guard fetch.ok else { return fetch }
        return run(["rebase", "origin/\(base)"], cwd: worktree)
    }

    static func push(worktree: String, branch: String) -> Result2 {
        run(["push", "-u", "origin", branch], cwd: worktree)
    }

    static func status(worktree: String) -> String {
        run(["status", "--short", "--branch"], cwd: worktree).output
    }
}
