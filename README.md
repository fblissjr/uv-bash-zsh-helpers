# uv-bash-zsh-helpers

bash and uv helpers for bash and zsh. makes managing uv venvs less annoying.

## what it does

*   `uvgo`: activate venvs without `cd`-ing to the exact spot or typing long paths. knows project `.venv`s and named venvs.
*   `uvls`: list the venvs it can find (named ones and project ones in common places).
*   `uvmk`: make new named venvs easily in a central spot.
*   `uvhelp`: show examples in your terminal.

## setup

1.  save the script somewhere, like `~/.bash_uv_helpers.sh`.
2.  edit the config at the top of the script:
    *   set `uv_cache_dir` to where you want uv's cache and the named venvs to live (important if `/home` is small).
    *   set `_uv_project_search_paths` to where you keep your code, so `uvls` can find project venvs.
3.  source it from your `~/.bashrc` (for bash) or `~/.zshrc` (for zsh):
    ```bash
    # load uv helpers
    if [ -f "${home}/.bash_uv_helpers.sh" ]; then
        . "${home}/.bash_uv_helpers.sh"
    fi
    ```
4.  reload your shell: `source ~/.bashrc` or `source ~/.zshrc` (or just open a new terminal).

## how to use (examples)

**activate current project's venv:**

```bash
cd /path/to/my_project/src
uvgo # finds ../.venv
```

**activate another project's venv (by path):**

```bash
# from anywhere
uvgo /path/to/another_project
# or relative path
uvgo ../sibling_project
```

**activate a shared/named venv:**

```bash
# assuming you made one called 'data_tools' with uvmk
uvgo data_tools
```

**list detected venvs:**

```bash
uvls # shows named ones and project ones it found
```

**make a new named venv (default python):**

```bash
uvmk general_stuff
# now activate with: uvgo general_stuff
```

**make a named venv (specific python):**

```bash
uvmk web_py311 -p 3.11
# activate with: uvgo web_py311
```

**get help / see these examples again:**

```bash
uvhelp
```

that's pretty much it. tinker with the config at the top of the script file if needed.
```
