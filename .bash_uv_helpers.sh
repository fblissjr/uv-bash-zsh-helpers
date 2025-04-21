#!/bin/bash
# ~/.bash_uv_helpers.sh
# Helper functions for managing UV environments using Bash.
# Dependencies: bash, uv, standard coreutils (realpath, find, dirname, basename, mkdir, etc.)

# --- Configuration ---
# Customize these paths for your system!

# Optional: Define a central place for named virtual environments
# Used by 'uvmk', 'uvls', and 'uvgo <name>'. Create this directory manually (e.g., mkdir -p ~/.virtualenvs).
# If commented out or empty, named environment features ('uvmk', 'uvgo <name>') will be disabled or may error.
_UV_VENV_BASE_DIR="${HOME}/.virtualenvs"

# Optional: Define where your main project directories are located.
# Used by 'uvls' to search for project-local environments (.venv folders).
# Add all parent directories containing projects you want 'uvls' to find.
_UV_PROJECT_SEARCH_PATHS=("${HOME}/projects" "${HOME}/dev")

# Reminder: Ensure UV cache dir is set if needed (e.g., in .bashrc):
# export UV_CACHE_DIR="/data/uv-cache"

# --- Helper Function (Do Not Call Directly) ---
# Finds the `.venv/bin/activate` script by searching upwards from a starting directory.
# Outputs the full path to the activate script if found, otherwise empty string.
_find_uv_venv_activate() {
  local current_dir="$1"
  local found_path=""

  # Attempt to get the absolute, canonical path, following symlinks (-L)
  if command -v realpath >/dev/null 2>&1; then
    current_dir=$(realpath -L "$current_dir" 2>/dev/null)
  else
    # Basic fallback if realpath isn't available
    if [[ ! -d "$current_dir" ]]; then
      echo "" # Output nothing on error
      return 1
    fi
    # Simple absolute path conversion if needed
    [[ "$current_dir" != /* ]] && current_dir="$PWD/$current_dir"
    # Basic ../ resolution (might not handle all edge cases)
    while [[ "$current_dir" =~ (^|/)\.\.(/|$) ]]; do
       current_dir=$(cd "$current_dir" && pwd) # Use cd/pwd for more robust path normalization
    done
  fi

  # Handle case where realpath failed or initial path was invalid
  if [[ -z "$current_dir" || ! -d "$current_dir" ]]; then
     echo "" # Output nothing on error
     return 1
  fi

  # Search loop
  while [[ -n "$current_dir" ]]; do
    local activate_script="${current_dir}/.venv/bin/activate"

    if [[ -f "$activate_script" ]]; then
      found_path="$activate_script"
      break # Exit loop once found
    fi

    # Stop if we've reached the root directory
    if [[ "$current_dir" == "/" ]]; then
      break
    fi

    # Move up one directory
    local parent_dir
    parent_dir=$(dirname "$current_dir")

    # Safety check to prevent infinite loop if dirname stops changing (e.g., at root)
    if [[ "$parent_dir" == "$current_dir" ]]; then
       break
    fi
    current_dir="$parent_dir"
  done

  # Output the found path (will be empty if not found)
  echo "$found_path"

  # Return success (0) if found, failure (1) otherwise
  if [[ -n "$found_path" ]]; then
    return 0
  else
    return 1
  fi
}

# --- Activation Function: uvgo ---

# Defensive un-definitions before defining the function
unset -f uvgo >/dev/null 2>&1 || true   # Remove existing function if any
unalias uvgo >/dev/null 2>&1 || true  # Remove existing alias if any

# Activates a uv virtual environment.
# Prioritizes exact match in current dir for no-arg case (like old alias).
# Usage:
#   uvgo        : Activates ./.venv if exists, else searches upwards from current dir.
#   uvgo <path> : Activates .venv found in <path> or its parent directories.
#   uvgo <name> : (If _UV_VENV_BASE_DIR is set) Activates named venv from base dir.
uvgo() {
  local target_path="$1"
  local activate_script=""
  local search_dir=""
  local source_location_msg=""
  local search_needed=1 # Flag to indicate if upward search is required

  # === START: Handle No Argument Case ===
  if [[ -z "$target_path" ]]; then
    # Prioritize exact match in current directory (like the old alias)
    if [[ -f "./.venv/bin/activate" ]]; then
      # Use realpath to get a canonical path for the message, but source directly
      local venv_parent_dir
      if command -v realpath >/dev/null 2>&1; then
         venv_parent_dir=$(realpath -L ".")
      else
         venv_parent_dir="$PWD"
      fi
      source "./.venv/bin/activate"
      echo "Activated UV environment: $(basename "$venv_parent_dir") (from current directory './.venv')"
      return 0 # Success, exit function early
    else
      # No exact match, set up for upward search from current directory
      search_dir=$(pwd)
      source_location_msg="current directory or parents"
      search_needed=1
    fi
  # === END: Handle No Argument Case ===

  # === START: Handle Argument Case ===
  else
    # If argument looks like a path (contains / or is . or ..) or is a valid directory
    if [[ "$target_path" == *"/"* || "$target_path" == "." || "$target_path" == ".." || -d "$target_path" ]]; then
      if [[ -d "$target_path" ]]; then
          search_dir="$target_path"
          source_location_msg="specified path ($target_path) or parents"
          search_needed=1
      else
          echo "Error: Path '$target_path' not found." >&2
          return 1
      fi
    # If argument is a name AND the base directory is configured
    elif [[ -n "$_UV_VENV_BASE_DIR" && -d "$_UV_VENV_BASE_DIR" ]]; then
      local named_venv_path="${_UV_VENV_BASE_DIR}/${target_path}/.venv/bin/activate"
      if [[ -f "$named_venv_path" ]]; then
          activate_script="$named_venv_path" # Found named env, no further search needed
          source_location_msg="named environment '$target_path' in $_UV_VENV_BASE_DIR"
          search_needed=0 # Found it directly
      else
          # If name not found in base dir, maybe it's a directory name in pwd? Check that.
          if [[ -d "$target_path" ]]; then
            search_dir="$target_path"
            source_location_msg="specified directory '$target_path' or parents"
            search_needed=1
          else
            echo "Error: Environment '$target_path' not found in $_UV_VENV_BASE_DIR" >&2
            echo "       and '$target_path' is not a valid directory in the current location." >&2
            return 1
          fi
      fi
    # Argument is a name, but base dir isn't configured, treat as potential directory in pwd
    elif [[ -d "$target_path" ]]; then
        search_dir="$target_path"
        source_location_msg="specified directory '$target_path' or parents"
        search_needed=1
    # Argument is not interpretable
    else
      echo "Error: Cannot interpret '$target_path'. Not a path and named environments are not configured or not found." >&2
      echo "Usage: uvgo [path | name]" >&2
      return 1
    fi
  fi
  # === END: Handle Argument Case ===

  # === START: Perform Search if Needed ===
  # If we need to search upwards (activate_script not already set by named env lookup)
  if [[ $search_needed -eq 1 && -n "$search_dir" ]]; then
    activate_script=$(_find_uv_venv_activate "$search_dir")
  fi
  # === END: Perform Search if Needed ===

  # === START: Activate or Report Error ===
  if [[ -n "$activate_script" && -f "$activate_script" ]]; then
    source "$activate_script"
    local venv_parent_dir
    # Use realpath on the directory containing .venv for a canonical name
    local venv_container_dir=$(dirname "$(dirname "$activate_script")")
    if command -v realpath >/dev/null 2>&1; then
       venv_parent_dir=$(realpath -L "$venv_container_dir")
    else
       venv_parent_dir="$venv_container_dir" # Fallback if realpath not available
    fi
    echo "Activated UV environment: $(basename "$venv_parent_dir") (found via search for ${source_location_msg})"
    # Optional: Display python version after activation
    # if command -v uv >/dev/null 2>&1; then echo -n "Python: "; uv python --version; fi
  elif [[ $search_needed -eq 1 ]]; then # Only show error if a search was expected to happen
    echo "Error: Could not find UV environment (.venv) for ${source_location_msg}." >&2
    return 1
  # If search wasn't needed, but activate_script is empty/invalid (shouldn't happen with current logic, but safe check)
  elif [[ -z "$activate_script" ]]; then
     echo "Error: No activation script identified." >&2
     return 1
  fi
  # === END: Activate or Report Error ===
}


# --- List Function: uvls ---

# Defensive un-definitions before defining the function
unset -f uvls >/dev/null 2>&1 || true
unalias uvls >/dev/null 2>&1 || true

# Lists available uv virtual environments found in common locations.
uvls() {
  echo "--- UV Environments ---"
  local found_any=0

  # 1. List from Central Base Directory (if configured)
  if [[ -n "$_UV_VENV_BASE_DIR" && -d "$_UV_VENV_BASE_DIR" ]]; then
    echo "[Named Environments in ${_UV_VENV_BASE_DIR}]:"
    local count=0
    # Use find for potentially better handling of many entries
    if command -v find >/dev/null 2>&1; then
      # Search for activate script inside .venv inside named dirs
      find "$_UV_VENV_BASE_DIR" -mindepth 2 -maxdepth 2 -path '*/.venv/bin/activate' -type f -print0 2>/dev/null | while IFS= read -r -d $'\0' activate_file; do
        local venv_parent_dir=$(dirname "$(dirname "$activate_file")") # Dir containing .venv
        echo "  - $(basename "$venv_parent_dir")" # Name of the env dir
        count=$((count + 1))
        found_any=1
      done
    else # Fallback to basic loop if find not available
       for item in "$_UV_VENV_BASE_DIR"/*; do
         if [[ -d "$item" && -f "$item/.venv/bin/activate" ]]; then
           echo "  - $(basename "$item")"
           count=$((count + 1))
           found_any=1
         fi
       done
    fi
    if [[ $count -eq 0 ]]; then
       echo "  (None found)"
    fi
    echo # Add a blank line for separation
  fi

  # 2. List from Project Search Paths
  if [[ ${#_UV_PROJECT_SEARCH_PATHS[@]} -gt 0 ]]; then
    echo "[Project Environments in ${_UV_PROJECT_SEARCH_PATHS[*]}]:"
    local found_in_projects=0
    # Use find to locate activate scripts efficiently within specified project roots
    local find_args=()
    # Ensure we don't list things from the base dir again if it's nested under a project path
    [[ -n "$_UV_VENV_BASE_DIR" ]] && find_args+=("!" "-path" "${_UV_VENV_BASE_DIR}/*")

    if command -v find >/dev/null 2>&1; then
        # Search for the activate script, then extract the project dir containing .venv
        # Adjust maxdepth if .venv might be nested deeper (e.g. -maxdepth 4)
        find "${_UV_PROJECT_SEARCH_PATHS[@]}" -mindepth 2 -maxdepth 3 -path '*/.venv/bin/activate' -type f \
             "${find_args[@]}" -print0 2>/dev/null | while IFS= read -r -d $'\0' activate_file; do
           local venv_container_dir=$(dirname "$(dirname "$activate_file")") # Dir containing .venv
           # Attempt to show path relative to the search root for clarity
           local display_path="$venv_container_dir"
           local relative_path_found=0
           for search_root in "${_UV_PROJECT_SEARCH_PATHS[@]}"; do
               # Use realpath for robust comparison, ignore errors if path doesn't exist
               local search_root_abs
               search_root_abs=$(realpath -L "$search_root" 2>/dev/null || echo "$search_root")
               local venv_container_abs
               venv_container_abs=$(realpath -L "$venv_container_dir" 2>/dev/null || echo "$venv_container_dir")
               # Check if venv_container_abs starts with search_root_abs/ (requires absolute paths)
               if [[ -n "$search_root_abs" && "$venv_container_abs" == "${search_root_abs}/"* ]]; then
                  display_path="${venv_container_abs#${search_root_abs}/}" # Remove prefix
                  # Add hint like (projects)/myproj or just myproj if search root is simple
                  local search_root_basename
                  search_root_basename=$(basename "$search_root_abs")
                  display_path="(${search_root_basename})/${display_path}"
                  relative_path_found=1
                  break
               fi
           done
           echo "  - ${display_path}" # Display path relative to search root or full path
           found_in_projects=1
           found_any=1
        done
    else
        echo "  (Warning: 'find' command not available, cannot search project paths automatically)"
    fi

    if [[ $found_in_projects -eq 0 ]]; then
        echo "  (None found)"
    fi
    echo # Add separator line
  fi

  if [[ $found_any -eq 0 ]]; then
    echo "(No environments found in configured locations: _UV_VENV_BASE_DIR or _UV_PROJECT_SEARCH_PATHS)"
  fi
  echo "---------------------"
}


# --- Creation Function: uvmk ---

# Defensive un-definitions before defining the function
unset -f uvmk >/dev/null 2>&1 || true
unalias uvmk >/dev/null 2>&1 || true

# Creates a new named uv virtual environment in the central base directory.
# Requires _UV_VENV_BASE_DIR to be set and the directory to exist.
# Usage:
#   uvmk <name> [options_for_uv_venv...]
uvmk() {
  if [[ -z "$_UV_VENV_BASE_DIR" ]]; then
    echo "Error: Central environment directory (_UV_VENV_BASE_DIR) is not configured." >&2
    echo "       Cannot create named environments. Set it in your shell config (~/.bash_uv_helpers.sh)." >&2
    return 1
  fi

  if [[ -z "$1" ]]; then
    echo "Usage: uvmk <environment_name> [options_for_uv_venv...]" >&2
    echo "Example: uvmk my_project -p 3.10" >&2
    return 1
  fi

  local venv_name="$1"
  shift # Remove the name from the arguments list
  local venv_parent_dir="${_UV_VENV_BASE_DIR}/${venv_name}"
  local venv_path="${venv_parent_dir}/.venv" # Standardize on .venv inside the named dir

  # Check for invalid characters in name (basic check)
  if [[ "$venv_name" =~ [/] ]]; then
      echo "Error: Environment name '$venv_name' cannot contain slashes." >&2
      return 1
  fi
  # Check if name is empty or just dots
  if [[ -z "$venv_name" || "$venv_name" == "." || "$venv_name" == ".." ]]; then
       echo "Error: Invalid environment name '$venv_name'." >&2
       return 1
  fi

  # Check if the target .venv directory already exists
  if [[ -e "$venv_path" ]]; then
    echo "Error: Environment path '$venv_path' already exists." >&2
    echo "       (Environment '$venv_name' likely already created)." >&2
    return 1
  fi
  # Check if the parent directory exists but is not a directory (unlikely but possible)
   if [[ -e "$venv_parent_dir" && ! -d "$venv_parent_dir" ]]; then
    echo "Error: Path '$venv_parent_dir' exists but is not a directory." >&2
    return 1
  fi

  echo "Creating UV environment '$venv_name' in '$venv_path'..."
  # Create the parent directory if it doesn't exist
  if ! mkdir -p "$venv_parent_dir"; then
     echo "Error: Failed to create directory '$venv_parent_dir'. Check permissions." >&2
     return 1
  fi

  # Run uv venv, passing any extra arguments (like -p python)
  if command -v uv >/dev/null 2>&1; then
      # Pass remaining arguments ($@) to uv venv, targeting the .venv subdir
      if uv venv "$venv_path" "$@"; then
          echo "Successfully created environment '$venv_name'."
          echo "Activate with: uvgo $venv_name"
      else
          echo "Error: 'uv venv' command failed." >&2
          # Consider cleanup policy here if desired - maybe remove parent if empty?
          # rmdir "$venv_parent_dir" 2>/dev/null || true # Attempt to remove parent only if empty
          return 1
      fi
  else
      echo "Error: 'uv' command not found. Please ensure uv is installed and in your PATH." >&2
      return 1
  fi
}

# --- Help Function: uvhelp ---

# Defensive un-definitions before defining the function
unset -f uvhelp >/dev/null 2>&1 || true
unalias uvhelp >/dev/null 2>&1 || true

# Displays help information for the UV helper commands.
uvhelp() {
  # Use cat with a heredoc for easy formatting
  # Use command substitution for dynamic config values if they are set
  local base_dir_display=${_UV_VENV_BASE_DIR:-"(Not Set)"}
  local project_paths_display=${_UV_PROJECT_SEARCH_PATHS[*]:-"(Not Set)"}

  cat << EOF
-------------------------------------
UV Environment Helper Commands Help
-------------------------------------

This script provides convenient shortcuts for managing UV virtual environments.

Available Commands:
-------------------
uvgo [path | name]
  Activates a UV virtual environment (.venv).
  - If no argument is given:
    1. Checks for './.venv/bin/activate' (for speed if in project root).
    2. If not found, searches upwards from the current directory for '.venv'.
  - If <path> (e.g., 'src/', '../project_b') is given:
    Searches upwards from the specified path for '.venv'.
  - If <name> is given (and _UV_VENV_BASE_DIR is configured):
    Activates the named environment in the base directory
    (e.g., activates '${base_dir_display}/<name>/.venv').

uvls
  Lists available UV virtual environments.
  - Shows named environments found in _UV_VENV_BASE_DIR ('${base_dir_display}').
  - Shows project environments (containing '.venv') found within the directories
    listed in _UV_PROJECT_SEARCH_PATHS ('${project_paths_display}').

uvmk <name> [options_for_uv_venv...]
  Creates a new named UV virtual environment in the central base directory
  (_UV_VENV_BASE_DIR: '${base_dir_display}'). This directory must be configured.
  - The environment is created at '${base_dir_display}/<name>/.venv'.
  - Example: uvmk my_env
  - Example: uvmk scientific_py311 -p 3.11
  - Any arguments after <name> are passed directly to 'uv venv'.

uvhelp
  Displays this help message.

Configuration (editable in ~/.bash_uv_helpers.sh):
--------------------------------------------------
_UV_VENV_BASE_DIR: '${base_dir_display}'
  Path to a central directory for named environments. Create it manually if set.

_UV_PROJECT_SEARCH_PATHS: ('${project_paths_display}')
  Array of paths where 'uvls' searches for project-local '.venv' directories.

UV_CACHE_DIR (set separately, e.g., in .bashrc):
  Tells 'uv' where to store its cache data. Recommended if home dir space is limited.
  Example: export UV_CACHE_DIR="/data/uv-cache"

To modify configuration, edit the top section of the script file:
  ~/.bash_uv_helpers.sh
and reload your shell (new terminal or 'source ~/.bashrc').

-------------------------------------
EOF
}
# --- End of UV Helper Functions ---
