# Premake5 (TOML Front-End Fork)

> **Fork Notice:** This repository is a custom fork of [**Premake 5 (`premake/premake-core`)**](https://github.com/premake/premake-core). It retains 100% of Premake's build-file generation backends (`gmake`, `ninja`, `vs2022`, `xcode4`, `codelite`, `compilecommands`, etc.) and Lua scripting engine while adding a **self-documenting TOML configuration front-end**, an **interactive `$EDITOR` setup wizard**, and an **existing CMake / Makefile importer**.

---

## Overview

Upstream Premake uses imperative Lua scripts (`premake5.lua`) to configure workspaces and targets. While flexible, writing a configuration from scratch typically requires looking up Premake's API documentation to know which fields are required, what valid values they accept, and how filters and usage requirements are structured.

This fork introduces a translation layer in front of Premake's existing backends (`premake5 init` / `premake.toml`) so you never have to hunt through documentation to configure a C or C++ project:

- **Guided `$EDITOR` Wizard (`git commit`-style):** Opens concise, staged TOML skeletons in your text editor (`$VISUAL` / `$EDITOR`) with inline comments showing valid choices, only prompting for optional stages (dependencies, compiler/platform overrides, build hooks) if you need them.
- **Blank Self-Documenting Config (`--blank`):** Skip interactive prompts altogether and emit a single `premake.toml` clearly divided into `# --- REQUIRED ---` and `# --- OPTIONAL ---` sections with blank default placeholders.
- **Existing Build System Import (`CMakeLists.txt` & `Makefile`):** Automatically parses existing Autotools/GNU `Makefile`s, `Makefile.am`, and `CMakeLists.txt` trees (or falls back to recursive C/C++ source/header scanning) to pre-populate targets, active sources, include paths, preprocessor defines, libraries, OS-specific link flags, and dialect/warning settings—even for optional fields whose interactive steps you skip.
- **Direct Backend Execution:** Run any Premake backend directly against `premake.toml` (e.g., `premake5 gmake` or `premake5 vs2022`), or compile `premake.toml` into a clean, idiomatic `premake5.lua`.

---

## Building from Source

Build the standalone `premake5` binary (with all Lua modules embedded) using the bootstrap scripts:

```bash
# Linux / macOS / BSD
./Bootstrap.sh

# Windows (Developer Command Prompt)
Bootstrap.bat
```

The resulting executable is written to `bin/release/premake5` (or `bin\release\premake5.exe` on Windows).

If you modify any `.lua` files under `src/`, re-embed them and rebuild:

```bash
./bin/release/premake5 embed
make -C build/bootstrap config=release
```

Run the test suite (including the TOML parser, wizard, and importer tests):

```bash
./bin/release/premake5 test
```

---

## Usage & Workflows

### 1. Interactive `$EDITOR` Wizard

Run `premake5 init` (alias `premake5 wizard`) in your project root:

```bash
premake5 init
# Or generate build files immediately after finishing setup:
premake5 init --backend=gmake
```

1. **Project Discovery:** Scans the directory for an existing `CMakeLists.txt` or `Makefile` (extracting targets, sources, includes, defines, links, and compiler flags), falling back to a recursive C/C++ source/header scan (or blank placeholders in an empty directory).
2. **Step 1 (Required):** Opens a minimal TOML skeleton in `$EDITOR` for `[workspace]` and `[[targets]]`. Validation errors re-open the file with an inline error banner at the top (similar to `visudo`) so no edits are lost.
3. **Steps 2–4 (Optional `[y/N]` Prompts):**
   - **Step 2:** External libraries, link directories, OS-specific libraries, & `PUBLIC` exports (`public_includes`, `public_defines`).
   - **Step 3:** Compiler warnings, sanitizers, LTO, RTTI/exceptions, custom flags, & per-OS defines.
   - **Step 4:** Precompiled headers, pre/post-build commands, & working directory / debugger arguments.
   - *(Any optional settings discovered from an existing CMake/Makefile are automatically preserved even if you answer `N` to skip these steps.)*
4. **Output:** Emits a clean `premake5.lua` and optionally runs your chosen backend (`gmake`, `ninja`, `vs2022`, `xcode4`, etc.).

### 2. Single-File Blank Template (`premake.toml`)

To skip interactive prompts and fill out a single declarative file by hand:

```bash
premake5 init --blank
```

This creates `premake.toml` with `# --- REQUIRED ---` fields at the top and `# --- OPTIONAL ---` fields below. Once filled in, either run any Premake backend directly (which auto-detects `premake.toml` and generates `premake5.lua` + build files):

```bash
premake5 gmake
```

Or explicitly generate `premake5.lua` from a TOML file:

```bash
premake5 init --from=premake.toml --backend=ninja
```

### 3. Importing an Existing CMake or Makefile Project

To convert an existing `CMakeLists.txt` or `Makefile` / `Makefile.am` project without interactive prompts:

```bash
# Write a pre-populated premake.toml for inspection/tweaking:
premake5 init --import

# Or generate premake5.lua and native build files directly in one step:
premake5 init --auto --backend=gmake --force
```

---

## Front-End CLI Options

| Flag / Action | Description |
| :--- | :--- |
| `premake5 init` (or `wizard`) | Launch the interactive `$EDITOR` TOML wizard in the current directory. |
| `--blank` | Skip interactive prompts and write a blank `premake.toml` with `# --- REQUIRED ---` and `# --- OPTIONAL ---` sections. |
| `--import` | Parse existing `CMakeLists.txt` / `Makefile` structure and write a pre-populated `premake.toml` without prompts. |
| `--auto` | Non-interactively scan `CMakeLists.txt` / `Makefile` (or directory sources) and emit `premake5.lua` directly. |
| `--from=FILE` | Non-interactively validate `FILE` (e.g. `premake.toml`) and emit `premake5.lua`. |
| `--backend=ACTION` | Immediately invoke backend `ACTION` (e.g. `gmake`, `ninja`, `vs2022`, `xcode4`, `compilecommands`) after generating `premake5.lua`. |
| `--editor=CMD` | Override `$PREMAKE_EDITOR` / `$VISUAL` / `$EDITOR` for interactive TOML editing. |
| `--force` | Overwrite an existing `premake5.lua` or `premake.toml` without confirmation. |
| `--file=FILE.toml` | Pass a `.toml` configuration directly to any Premake action (e.g. `premake5 --file=custom.toml gmake`). |
| `--init` | Run the interactive wizard first if `premake5.lua` is missing before executing a backend action. |

---

## Upstream Premake

Full compatibility with standard `premake5.lua` scripts and Premake modules is preserved:

```lua
workspace "MyWorkspace"
    configurations { "Debug", "Release" }

project "MyProject"
    kind "ConsoleApp"
    language "C++"
    files { "**.h", "**.cpp" }

    filter { "configurations:Debug" }
        defines { "DEBUG" }
        symbols "On"

    filter { "configurations:Release" }
        defines { "NDEBUG" }
        optimize "On"
```

* **Upstream Repository:** [github.com/premake/premake-core](https://github.com/premake/premake-core)
* **Upstream Documentation:** [premake.github.io/docs](https://premake.github.io/docs/)
* **Upstream Issue Tracker:** [github.com/premake/premake-core/issues](https://github.com/premake/premake-core/issues)

---

## License

[BSD 3-Clause](https://opensource.org/licenses/BSD-3-Clause) (same license as upstream Premake).

The Lua language and runtime library is &copy; TeCGraf, PUC-Rio.
See their website at http://www.lua.org/
