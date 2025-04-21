#!/bin/bash
# ~/.bash_uv_helpers.sh
#
# Purpose:
#   Provides enhanced Bash functions (uvgo, uvls, uvmk, uvhelp) to manage
#   Python virtual environments created by 'uv', offering more flexible
#   activation and centralized management options compared to basic aliases.
#
# Dependencies:
#   - Bash (v4+)
#   - uv (https://github.com/astral-sh/uv) installed and in PATH
#   - Standard coreutils: realpath, find, dirname, basename, mkdir, cat, grep, etc.
#
# Installation:
#   1. Save this script (e.g., as ~/.bash_uv_helpers.sh).
#   2. Source it from your main shell configuration file (e.g., ~/.bashrc):
#      if [ -f "${HOME}/.bash_uv_helpers.sh" ]; then
#          . "${HOME}/.bash_uv_helpers.sh"
#      fi
#   3. Customize the Configuration section below as needed.
#   4. Reload your shell (new terminal or `source ~/.bashrc`).

# --- Configuration ---
# Customize these paths and settings for your system!

# Set the UV Cache Directory.
# WHY:  `uv` uses this environment variable to determine where to store downloaded
#       packages and other cache data. By exporting it here, we ensure that
#       when this script is sourced, `uv` commands run *within this shell session*
#       will use this location. This setting *also* determines the base location
#       for the *named* virtual environments created by this script's `uvmk` function
#       (they go into a 'venvs' subdirectory within this cache path).
# NOTE: Setting it here means `uv` will only use this path in shells where this
#       script has been sourced. Setting it directly in .bashrc/.profile/.zshenv
#       might be preferred for system-wide consistency if needed outside this script.
export UV_CACHE_DIR="/data/.cache/uv" # <<< EXAMPLE: Set your desired cache path

# Define Project Search Paths for `uvls`.
# WHY:  The `uvls` command searches for project-local environments (folders
#       containing a .venv). This array tells `uvls` where your common project
#       parent directories are located.
# NOTE: This *only* affects the `uvls` command's discovery feature. It does *not*
#       affect where `uvgo` searches (which is based on the current directory or
#       a provided path argument). Add all relevant paths for your setup.
_UV_PROJECT_SEARCH_PATHS=("${HOME}/projects" "${HOME}/dev") # <<< EXAMPLE: Add your project roots


# --- Internal Helper Function: Get Base Venv Dir ---
# Determines the base directory for named venvs based on UV_CACHE_DIR.
# WHY:  To centralize the logic for where named environments managed by `uvmk`
#       and activated by `uvgo <name>` should reside. It respects the primary
#       `UV_CACHE_DIR` configuration for consistency.
# WHAT: Checks if UV_CACHE_DIR is set. If yes, it uses "${UV_CACHE_DIR}/venvs".
#       If not set (which shouldn't happen if sourced correctly due to the export above,
#       but provides a fallback), it defaults to "$HOME/.cache/uv/venvs".
#       It echoes the calculated path for use by other functions.
_get_uv_venv_base_dir() {
  # Default uv cache location on Linux/macOS (used as fallback)
  local default_cache_base="${HOME}/.cache/uv"
  # Use UV_CACHE_DIR if set and non-empty, otherwise use the default base
  local cache_dir="${UV_CACHE_DIR:-${default_cache_base}}"
  # Append '/venvs' to keep named environments organized within the cache structure
  echo "${cache_dir}/venvs"
}


# --- Internal Helper Function: Find Activate Script ---
# Searches *upwards* from a starting directory for a `.venv/bin/activate` script.
# WHY:  Mimics the behavior of tools like `uv` or `git` that find configuration/project
#       roots by looking in the current directory and its parents. Allows activating
#       a project's venv from any subdirectory within that project.
# WHAT: 1. Takes a starting directory path as input.
#       2. Normalizes the path to an absolute, canonical path (using `realpath` if
#          available for robustness against symlinks, with a basic fallback).
#       3. Enters a loop:
#          a. Checks if `.venv/bin/activate` exists in the `current_dir`.
#          b. If found, stores the path and breaks the loop.
#          c. If not found, checks if it's at the root (`/`). If so, breaks.
#          d. Moves `current_dir` up one level using `dirname`.
#          e. Includes safety checks against infinite loops.
#       4. Outputs the full path to the activate script if found, otherwise empty string.
#       5. Returns exit code 0 if found, 1 otherwise.
_find_uv_venv_activate() {
  local current_dir="$1"
  local found_path=""

  # Attempt to get the absolute, canonical path, following symlinks (-L) for accuracy
  if command -v realpath >/dev/null 2>&1; then
    current_dir=$(realpath -L "$current_dir" 2>/dev/null)
  else
    # Basic fallback if realpath isn't available (less robust with complex symlinks/../)
    if [[ ! -d "$current_dir" ]]; then echo ""; return 1; fi # Exit if starting dir invalid
    [[ "$current_dir" != /* ]] && current_dir="$PWD/$current_dir" # Make absolute if relative
    # Attempt to resolve '..' components using subshell/cd for better normalization
    while [[ "$current_dir" =~ (^|/)\.\.(/|$) ]]; do current_dir=$(cd "$current_dir" && pwd); done
  fi

  # Exit if path resolution failed or resulted in a non-directory
  if [[ -z "$current_dir" || ! -d "$current_dir" ]]; then echo ""; return 1; fi

  # Loop upwards through parent directories
  while [[ -n "$current_dir" ]]; do
    local activate_script="${current_dir}/.venv/bin/activate"
    if [[ -f "$activate_script" ]]; then
      found_path="$activate_script"
      break # Found it!
    fi
    # Stop searching at the filesystem root
    if [[ "$current_dir" == "/" ]]; then break; fi
    # Go up one directory
    local parent_dir; parent_dir=$(dirname "$current_dir")
    # Safety check: prevent infinite loop if dirname doesn't change (e.g., at root)
    if [[ "$parent_dir" == "$current_dir" ]]; then break; fi
    current_dir="$parent_dir"
  done

  # Output result
  echo "$found_path"
  # Return appropriate exit status
  if [[ -n "$found_path" ]]; then return 0; else return 1; fi
}


# --- Main Activation Function: uvgo ---

# Defensive un-definitions
# WHY:  Prevents errors if an alias or function named `uvgo` already exists
#       in the environment before this script is sourced. Makes sourcing more robust.
unset -f uvgo >/dev/null 2>&1 || true   # Remove existing function if any
unalias uvgo >/dev/null 2>&1 || true  # Remove existing alias if any

# Activates a uv virtual environment based on context or arguments.
# WHAT: This is the primary user command for activation. It handles several cases:
#       1. No arguments (`uvgo`):
#          - First, checks for `./.venv/bin/activate` (fast path, like a simple alias).
#          - If not found, calls `_find_uv_venv_activate` starting from `pwd`.
#       2. Path argument (`uvgo path/to/project`):
#          - Calls `_find_uv_venv_activate` starting from the provided path.
#       3. Name argument (`uvgo my_named_env`):
#          - Calculates the expected path in the named venv base directory
#            (using `_get_uv_venv_base_dir`).
#          - Checks if that specific named environment's activate script exists.
#          - Includes a fallback check: if the name matches a directory in the current
#            location, it treats it like a path argument (useful for `cd project; uvgo project`).
#       4. Activation: If an `activate_script` path is successfully identified, it's
#          executed using `source` to modify the current shell's environment.
#       5. Error Handling: Provides informative messages if activation fails.
uvgo() {
  local target_path="$1"; local activate_script=""; local search_dir=""
  local source_location_msg=""; local search_needed=1; local venv_base_dir

  # Case 1: No arguments provided
  if [[ -z "$target_path" ]]; then
    # Optimize: Check current dir first, like the old alias behavior
    if [[ -f "./.venv/bin/activate" ]]; then
      local venv_parent_dir; if command -v realpath >/dev/null 2>&1; then venv_parent_dir=$(realpath -L "."); else venv_parent_dir="$PWD"; fi
      source "./.venv/bin/activate"; echo "Activated UV environment: $(basename "$venv_parent_dir") (from current directory './.venv')"; return 0
    else
      # Not in current dir, prepare for upward search from here
      search_dir=$(pwd); source_location_msg="current directory or parents"; search_needed=1
    fi
  # Case 2: Argument provided
  else
    # Subcase 2a: Argument looks like a path or is an existing directory
    if [[ "$target_path" == *"/"* || "$target_path" == "." || "$target_path" == ".." || -d "$target_path" ]]; then
      if [[ -d "$target_path" ]]; then
        # Prepare for upward search starting from the specified path
        search_dir="$target_path"; source_location_msg="specified path ($target_path) or parents"; search_needed=1
      else
        echo "Error: Path '$target_path' not found." >&2; return 1
      fi
    # Subcase 2b: Argument is treated as a potential *named* environment
    else
      venv_base_dir=$(_get_uv_venv_base_dir) # Find where named venvs should be
      local named_venv_path="${venv_base_dir}/${target_path}/.venv/bin/activate"
      # Check if the specific named environment exists
      if [[ -f "$named_venv_path" ]]; then
        activate_script="$named_venv_path"; source_location_msg="named environment '$target_path' in ${venv_base_dir}"; search_needed=0 # Found it directly
      else
        # Fallback: Maybe the name is a directory in the *current* location?
        if [[ -d "$target_path" ]]; then
           search_dir="$target_path"; source_location_msg="specified directory '$target_path' or parents"; search_needed=1
        else
           # Name not found in base dir and not a local directory -> Error
           echo "Error: Named environment '$target_path' not found in ${venv_base_dir}" >&2
           echo "       and '$target_path' is not a valid directory in the current location." >&2; return 1
        fi
      fi
    fi
  fi

  # Perform the upward search if determined necessary
  if [[ $search_needed -eq 1 && -n "$search_dir" ]]; then
    activate_script=$(_find_uv_venv_activate "$search_dir")
  fi

  # Final step: Activate or report failure
  if [[ -n "$activate_script" && -f "$activate_script" ]]; then
    # Use 'source' to run activate script in the *current* shell context
    source "$activate_script"
    # Get canonical path for display message
    local venv_parent_dir; local venv_container_dir=$(dirname "$(dirname "$activate_script")")
    if command -v realpath >/dev/null 2>&1; then venv_parent_dir=$(realpath -L "$venv_container_dir"); else venv_parent_dir="$venv_container_dir"; fi
    echo "Activated UV environment: $(basename "$venv_parent_dir") (found via ${source_location_msg})"
  elif [[ $search_needed -eq 1 ]]; then # Only error if we actually searched and failed
    echo "Error: Could not find UV environment (.venv) for ${source_location_msg}." >&2; return 1
  elif [[ -z "$activate_script" ]]; then # Should not happen if search_needed was 0, but belt-and-suspenders
     echo "Error: No activation script identified (Internal Error)." >&2; return 1
  fi
  # If activation was successful, return 0 (implied)
}


# --- Main List Function: uvls ---

# Defensive un-definitions (See 'uvgo' for explanation)
unset -f uvls >/dev/null 2>&1 || true
unalias uvls >/dev/null 2>&1 || true

# Lists available uv virtual environments based on configuration.
# WHAT: Provides an overview of environments this script can find.
#       1. Gets the base directory for named venvs using `_get_uv_venv_base_dir`.
#       2. Lists directories inside the named venv base path that contain `.venv/bin/activate`.
#          Uses `find` for efficiency if available, otherwise a simple loop.
#       3. Lists project-local environments by searching for `.venv/bin/activate` within
#          the paths defined in `_UV_PROJECT_SEARCH_PATHS`. Uses `find` preferably.
#       4. Attempts to display project paths relative to their search root for clarity.
#       5. Provides messages if no environments are found in either location.
uvls() {
  echo "--- UV Environments ---"; local found_any=0; local venv_base_dir=$(_get_uv_venv_base_dir)

  # Section 1: List Named Environments
  echo "[Named Environments in ${venv_base_dir}]:"
  if [[ -d "$venv_base_dir" ]]; then # Only proceed if the base directory actually exists
    local count=0
    # Use find for efficiency, especially with many environments
    if command -v find >/dev/null 2>&1; then
      # Search for activate scripts exactly two levels deep (base/name/.venv/bin/activate)
      find "$venv_base_dir" -mindepth 2 -maxdepth 2 -path '*/.venv/bin/activate' -type f -print0 2>/dev/null | while IFS= read -r -d $'\0' activate_file; do
        # Extract the environment name (parent directory of .venv)
        local venv_parent_dir=$(dirname "$(dirname "$activate_file")")
        echo "  - $(basename "$venv_parent_dir")"
        count=$((count + 1)); found_any=1
      done
    else # Fallback if 'find' command is not available
       echo "  (Warning: 'find' command not available, using basic loop)" >&2
       for item in "$venv_base_dir"/*; do
         if [[ -d "$item" && -f "$item/.venv/bin/activate" ]]; then
           echo "  - $(basename "$item")"; count=$((count + 1)); found_any=1
         fi
       done
    fi
    if [[ $count -eq 0 ]]; then echo "  (None found)"; fi
  else
      echo "  (Directory does not exist or is not accessible)"
  fi
  echo # Blank line separator

  # Section 2: List Project Environments
  if [[ ${#_UV_PROJECT_SEARCH_PATHS[@]} -gt 0 ]]; then
    echo "[Project Environments in ${_UV_PROJECT_SEARCH_PATHS[*]}]:"
    local found_in_projects=0
    local find_args=()
    # Avoid listing named venvs again if base dir is inside a project search path
    [[ -d "$venv_base_dir" ]] && find_args+=("!" "-path" "${venv_base_dir}/*")

    if command -v find >/dev/null 2>&1; then
        # Search for activate script within configured project paths
        # Adjust maxdepth if .venv might be nested deeper (e.g., -maxdepth 4 for proj/src/.venv)
        find "${_UV_PROJECT_SEARCH_PATHS[@]}" -mindepth 2 -maxdepth 3 -path '*/.venv/bin/activate' -type f \
             "${find_args[@]}" -print0 2>/dev/null | while IFS= read -r -d $'\0' activate_file; do
           # Get the directory containing the .venv folder
           local venv_container_dir=$(dirname "$(dirname "$activate_file")")
           # Attempt to show path relative to the search root for better context
           local display_path="$venv_container_dir"; local relative_path_found=0
           for search_root in "${_UV_PROJECT_SEARCH_PATHS[@]}"; do
               local search_root_abs; search_root_abs=$(realpath -L "$search_root" 2>/dev/null || echo "$search_root")
               local venv_container_abs; venv_container_abs=$(realpath -L "$venv_container_dir" 2>/dev/null || echo "$venv_container_dir")
               # Check if the venv path starts with the absolute search root path
               if [[ -n "$search_root_abs" && "$venv_container_abs" == "${search_root_abs}/"* ]]; then
                  # Construct relative path display: (search_root_name)/relative/path
                  display_path="${venv_container_abs#${search_root_abs}/}"
                  local search_root_basename; search_root_basename=$(basename "$search_root_abs")
                  display_path="(${search_root_basename})/${display_path}"
                  relative_path_found=1; break
               fi
           done
           echo "  - ${display_path}" # Display relative or absolute path
           found_in_projects=1; found_any=1
        done
    else
        echo "  (Warning: 'find' command not available, cannot search project paths automatically)" >&2
    fi
    if [[ $found_in_projects -eq 0 ]]; then echo "  (None found in configured search paths)"; fi
    echo # Blank line separator
  fi

  # Overall summary if nothing was found anywhere
  if [[ $found_any -eq 0 ]]; then
    echo "(No environments found in project search paths or the named location)"
  fi
  echo "---------------------"
}


# --- Main Creation Function: uvmk ---

# Defensive un-definitions (See 'uvgo' for explanation)
unset -f uvmk >/dev/null 2>&1 || true
unalias uvmk >/dev/null 2>&1 || true

# Creates a new *named* uv virtual environment in the central base directory.
# WHAT: Provides a command to create reusable, named environments separate from projects.
#       1. Determines the base directory using `_get_uv_venv_base_dir`.
#       2. Requires an environment name as the first argument.
#       3. Performs validation checks (name validity, path doesn't already exist).
#       4. Creates the parent directory structure (`base_dir/env_name/`) using `mkdir -p`.
#       5. Executes `uv venv` targeting the standard `.venv` subdirectory within the
#          newly created parent directory (`base_dir/env_name/.venv`).
#       6. Passes any additional arguments (`$@`) directly to `uv venv` (e.g., for `-p python`).
#       7. Reports success (including activation hint) or failure.
uvmk() {
  local venv_base_dir=$(_get_uv_venv_base_dir) # Determine where to create it

  # Check for required name argument
  if [[ -z "$1" ]]; then
    echo "Usage: uvmk <environment_name> [options_for_uv_venv...]" >&2
    echo "       Named environments will be created in: ${venv_base_dir}" >&2
    echo "Example: uvmk my_project -p 3.10" >&2
    return 1
  fi

  local venv_name="$1"
  shift # Consume the name, remaining args ($@) are for 'uv venv'
  local venv_parent_dir="${venv_base_dir}/${venv_name}"
  # Standardize: create the actual venv in a '.venv' subdir for consistency
  local venv_path="${venv_parent_dir}/.venv"

  # Basic name validation
  if [[ "$venv_name" =~ [/] ]]; then echo "Error: Environment name '$venv_name' cannot contain slashes." >&2; return 1; fi
  if [[ -z "$venv_name" || "$venv_name" == "." || "$venv_name" == ".." ]]; then echo "Error: Invalid environment name '$venv_name'." >&2; return 1; fi

  # Check if target environment already exists
  if [[ -e "$venv_path" ]]; then echo "Error: Environment path '$venv_path' already exists." >&2; return 1; fi
  # Check if parent path exists but isn't a directory
  if [[ -e "$venv_parent_dir" && ! -d "$venv_parent_dir" ]]; then echo "Error: Path '$venv_parent_dir' exists but is not a directory." >&2; return 1; fi

  echo "Creating UV environment '$venv_name' within '$venv_parent_dir'..."
  # Ensure the parent directory exists (and the base dir, implicitly)
  if ! mkdir -p "$venv_parent_dir"; then
     echo "Error: Failed to create directory '$venv_parent_dir'. Check permissions for '${venv_base_dir}'." >&2
     return 1
  fi

  # Execute the 'uv venv' command
  if command -v uv >/dev/null 2>&1; then
      # Target the '.venv' subdirectory, pass through extra args like -p
      if uv venv "$venv_path" "$@"; then
          echo "Successfully created environment '$venv_name'."
          echo "Activate with: uvgo $venv_name"
      else
          echo "Error: 'uv venv' command failed." >&2
          # Optional: Consider attempting cleanup if creation failed
          # rmdir "$venv_parent_dir" 2>/dev/null || true # Removes parent only if empty
          return 1
      fi
  else
      echo "Error: 'uv' command not found. Please ensure uv is installed and in your PATH." >&2
      return 1
  fi
}

# --- Help Function: uvhelp ---

# Defensive un-definitions (See 'uvgo' for explanation)
unset -f uvhelp >/dev/null 2>&1 || true
unalias uvhelp >/dev/null 2>&1 || true

# Displays help information focusing on usage patterns.
uvhelp() {
  # Get dynamic values for display
  local venv_base_display=$(_get_uv_venv_base_dir)
  local project_paths_display=${_UV_PROJECT_SEARCH_PATHS[*]:-"(Not Set)"}
  local uv_cache_display=${UV_CACHE_DIR:-"$HOME/.cache/uv (Default - UV_CACHE_DIR not set)"}

  # Use cat with a heredoc for easy formatting
  cat << EOF
-------------------------------------
UV Environment Helper Commands - Usage Patterns
-------------------------------------

This script provides shortcuts for activating, listing, and creating UV environments.

Core Commands:
  uvgo    Activate an environment (project-local or named).
  uvls    List detected environments.
  uvmk    Make (create) a new *named* environment.
  uvhelp  Show this help message.

--- Common Usage Patterns / Examples ---

1. Activate Environment for Current Project:
   ----------------------------------------
   # Navigate into your project directory (or any subdirectory)
   cd /path/to/my_project/src

   # Activate the .venv found in ./ or parent directories
   uvgo

2. Activate Environment for Another Project (by Path):
   --------------------------------------------------
   # From anywhere, activate the venv associated with another project path
   uvgo /path/to/another_project

   # Or using a relative path
   uvgo ../sibling_project

3. Activate a Shared/Named Environment:
   -----------------------------------
   # Activate a named environment you created previously with uvmk
   uvgo shared_data_tools
   # (This looks for '${venv_base_display}/shared_data_tools/.venv')

4. List All Detected Environments:
   ------------------------------
   # See named environments and project environments found in search paths
   uvls

5. Create a New Shared/Named Environment (Default Python):
   -------------------------------------------------------
   # Create a reusable environment named 'general_utils'
   uvmk general_utils
   # (Created in '${venv_base_display}/general_utils/.venv')
   # Activate it later with: uvgo general_utils

6. Create a New Named Environment (Specific Python):
   --------------------------------------------------
   # Create an environment named 'web_py311' using Python 3.11
   uvmk web_py311 -p 3.11
   # (Pass any 'uv venv' options like -p after the name)

7. Get Help:
   ----------
   uvhelp

--- Configuration & Locations ---

Named Environment Base Directory: '${venv_base_display}'
  - Location for environments created by 'uvmk'.
  - Derived from the UV_CACHE_DIR environment variable (uses '\${UV_CACHE_DIR}/venvs').
  - If UV_CACHE_DIR is NOT set, defaults to '$HOME/.cache/uv/venvs'.

Project Search Paths (for 'uvls'): ('${project_paths_display}')
  - Configured via _UV_PROJECT_SEARCH_PATHS variable in this script.
  - Tells 'uvls' where to look for project-local '.venv' folders.

UV Cache Directory (affects 'uv' & named env location): '${uv_cache_display}'
  - Controls where 'uv' stores downloads *and* determines the named env base dir.
  - Set via 'export UV_CACHE_DIR=...' at the top of this script or elsewhere.

To modify configuration, edit the top section of this script file:
  ~/.bash_uv_helpers.sh
Remember to reload your shell after making changes (new terminal or 'source ~/.bashrc').

-------------------------------------
EOF
}
# --- End of UV Helper Functions ---
