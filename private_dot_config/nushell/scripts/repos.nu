#!/usr/bin/env nu

def highlight [value: int]: nothing -> string {
	if $value == 0 { $"($value)" } else { $"(ansi yellow_bold)($value)(ansi reset)" }
}

# Repository paths under the cwd, excluding submodules; the parent repo manages those.
# --show-superproject-working-tree prints the parent worktree in a submodule, nothing elsewhere.
def repo-paths []: nothing -> list<string> {
	glob **/.git --depth 10
	| each {|it| $it | path dirname}
	| where {|it|
		let superproject = (^git -C $it rev-parse --show-superproject-working-tree | complete)
		$superproject.exit_code != 0 or ($superproject.stdout | str trim | is-empty)
	}
}

export def "repos status" [--list, --remote] {
	repo-paths
	| each {|it|
		let relative = ($it | path relative-to (pwd))
		cd $it

		let branch = (git branch --show-current)
		let origin = (git remote get-url origin | complete)
		let remote_url = if ($origin.exit_code == 0) { $origin.stdout | str trim | str replace --regex '^\w+://' '' | str replace --regex '^[^@]+@' '' } else { "" }
		let ahead_behind = (git rev-list --left-right --count $"origin/($branch)...HEAD" | complete)
		let ahead = if ($ahead_behind.exit_code == 0) {
			$ahead_behind.stdout | split row "\t" | get 1 | str trim | into int
		} else { 0 }
		let behind = if ($ahead_behind.exit_code == 0) {
			$ahead_behind.stdout | split row "\t" | get 0 | str trim | into int
		} else { 0 }

		let porcelain = (git status --porcelain | parse --regex '(?P<index>.)(?P<worktree>.) (?P<file>.+)')
		let staged = ($porcelain | where {|row| $row.index != " " and $row.index != "?"} | get file)
		let unstaged = ($porcelain | where {|row| $row.worktree != " " and $row.worktree != "?"} | get file)
		let untracked = ($porcelain | where {|row| $row.index == "?" and $row.worktree == "?"} | get file)

		if $list {
			{
				repo: $relative
				branch: $branch
				staged: $staged
				unstaged: $unstaged
				untracked: $untracked
			}
		} else {
			let row = {
				repo: $relative
				branch: (if $branch == "main" { $branch } else { $"(ansi yellow_bold)($branch)(ansi reset)" })
				ahead: (highlight $ahead)
				behind: (highlight $behind)
				staged: (highlight ($staged | length))
				unstaged: (highlight ($unstaged | length))
				untracked: (highlight ($untracked | length))
			}
			if $remote {
				$row | insert remote $remote_url
			} else {
				$row
			}
		}
	}
}

# Reset the `common` submodule to the commit the parent records; no-op when the repo has none.
def reset-common-submodule []: nothing -> record<ok: bool, error: string> {
	let declared = (^git config --file .gitmodules --get submodule.common.path | complete)
	if $declared.exit_code != 0 { return { ok: true, error: "" } }

	let result = (^git submodule update --init common | complete)
	{ ok: ($result.exit_code == 0), error: ($result.stderr | str trim) }
}

# --untracked also pulls repos whose only changes are untracked files. That is safe: git pull aborts
# without touching the repo if an incoming file would overwrite an untracked one.
export def "repos pull" [
	--untracked # Pull repos that have untracked files but no staged or unstaged changes
] {
	repo-paths
	| each {|it|
		let relative = ($it | path relative-to (pwd))
		cd $it

		# Reset first: a drifted submodule makes the parent look dirty and would skip the pull.
		let before = (reset-common-submodule)
		if not $before.ok {
			return { repo: $relative, status: $"(ansi red_bold)error: submodule reset failed: ($before.error)(ansi reset)" }
		}

		let status = (^git status --porcelain | complete)
		if $status.exit_code != 0 {
			return { repo: $relative, status: $"(ansi red_bold)error: git status failed: ($status.stderr | str trim)(ansi reset)" }
		}
		let porcelain = ($status.stdout | lines)
		if ($porcelain | any {|line| not ($line | str starts-with "??")}) {
			return { repo: $relative, status: $"(ansi yellow_bold)skipped \(has changes\)(ansi reset)" }
		}
		if not ($porcelain | is-empty) and not $untracked {
			return { repo: $relative, status: $"(ansi yellow_bold)skipped \(has untracked files, use --untracked\)(ansi reset)" }
		}

		let result = (^git pull | complete)
		if $result.exit_code != 0 {
			return { repo: $relative, status: $"(ansi red_bold)error: ($result.stderr | str trim)(ansi reset)" }
		}
		# The pull may move the recorded submodule commit.
		let after = (reset-common-submodule)
		if $after.ok {
			{ repo: $relative, status: ($result.stdout | str trim) }
		} else {
			{ repo: $relative, status: $"(ansi red_bold)error: submodule reset failed: ($after.error)(ansi reset)" }
		}
	}
}

export def "repos branch-delete" [] {
	repo-paths
	| each {|it|
		let relative = ($it | path relative-to (pwd))
		cd $it

		# Safe delete only: git refuses unmerged branches, so record those as skipped instead of aborting.
		let results = (
			git branch --verbose
			| lines
			| parse --regex '^[* ] +(?<branch>\S+) +(?<commit>[0-9a-f]+) +(?<tag>\[gone\])? ?(?<message>.*)$'
			| where tag == '[gone]'
			| each {|it|
				let result = (^git branch --delete $it.branch | complete)
				if $result.exit_code == 0 {
					{ branch: $it.branch, deleted: true, error: "" }
				} else {
					{ branch: $it.branch, deleted: false, error: ($result.stderr | lines | first | str trim) }
				}
			}
		)
		for failure in ($results | where deleted == false) {
			print --stderr $"(ansi red_bold)($relative): kept ($failure.branch): ($failure.error)(ansi reset)"
		}
		{
			repo: $relative
			deleted: ($results | where deleted | get branch)
			skipped: ($results | where deleted == false | select branch error)
		}
	}
}

def main [command: string, --list, --remote, --untracked] {
	match $command {
		"status" => { repos status --list=$list --remote=$remote }
		"pull" => { repos pull --untracked=$untracked }
		"branch-delete" => { repos branch-delete }
		_ => { error make { msg: $"Unknown command: ($command)" } }
	}
}
