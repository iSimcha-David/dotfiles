# All arguments will be passed as positional arguments.
set positional-arguments
# Use Nushell for all shells
set shell := ['nu', '-c']
# The export setting causes all just variables to be exported as environment variables. Defaults to false.
set export


# default recipe to display help information
default:
	@just --list


# list the just recipes
list:
	@just --list


# Install the chezmoi config to the user's home directory.
chezmoi-install-config:
	#!/usr/bin/env nu

	# Read a global git config value. git exits 1 when the key is unset.
	def git-config [key: string]: nothing -> string {
		let result = (^git config --global --get $key | complete)
		if $result.exit_code == 1 {
			print --stderr $"warning: git config ($key) is not set; leaving it empty in chezmoi.jsonc"
			return ""
		}
		if $result.exit_code != 0 {
			error make {msg: $"git config --global --get ($key) failed: ($result.stderr)"}
		}
		$result.stdout | str trim
	}

	# Get the users name and email from their global git config
	let user_name = (git-config user.name)
	let user_email = (git-config user.email)
	let chezmoi_dir = ("~/.config/chezmoi" | path expand)
	if not ($chezmoi_dir | path exists) {
		mkdir $chezmoi_dir
	}
	open chezmoi-example.jsonc
		| from json
		| update sourceDir ($env.HOME | path join "projects/dotfiles")
		| update data.git.name $user_name
		| update data.git.email $user_email
		| update data.firefox.profile_name $env.USER
		| to json
		| save ($chezmoi_dir | path join "chezmoi.jsonc")
