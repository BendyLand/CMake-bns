# cmake-bns

> **Fork Notice:** `cmake-bns` is a custom fork of [**Premake 5 (`premake/premake-core`)**](https://github.com/premake/premake-core). It retains 100% of Premake's build-file generation backends (`gmake`, `ninja`, `vs2022`, `xcode4`, `codelite`, `compilecommands`, etc.) and Lua scripting engine while adding a **self-documenting TOML configuration front-end**, an **interactive `$EDITOR` setup wizard**, and an **existing CMake / Makefile importer**.

---

## Overview

Upstream Premake uses imperative Lua scripts to configure workspaces and targets. While flexible, writing a configuration from scratch typically requires looking up Premake's API documentation to know which fields are required, what valid values they accept, and how filters and usage requirements are structured.

`cmake-bns` introduces a translation layer in front of Premake's existing backends (`cmake-bns init` / `cmake-bns.toml` -> `cmake-bns.lua`) so you never have to hunt through documentation to configure a C or C++ project:

- **Guided `$EDITOR` Wizard (`git commit`-style):** Opens concise, staged TOML skeletons in your text editor (`$VISUAL` / `$EDITOR`) with inline comments showing valid choices, only prompting for optional stages (dependencies, compiler/platform overrides, build hooks) if you need them.
- **Blank Self-Documenting Config (`--blank`):** Skip interactive prompts altogether and emit a single `cmake-bns.toml` clearly divided into `# --- REQUIRED ---` and `# --- OPTIONAL ---` sections with blank default placeholders.
- **Existing Build System Import (`CMakeLists.txt` & `Makefile`):** Automatically parses existing Autotools/GNU `Makefile`s, `Makefile.am`, and `CMakeLists.txt` trees (or falls back to recursive C/C++ source/header scanning) to pre-populate targets, active sources, include paths, preprocessor defines, libraries, OS-specific link flags, and dialect/warning settings—even for optional fields whose interactive steps you skip.
- **Direct Backend Execution:** Run any backend directly against `cmake-bns.toml` (e.g., `cmake-bns gmake` or `cmake-bns vs2022`), or compile `cmake-bns.toml` into a clean, idiomatic `cmake-bns.lua`.

---

## Building from Source

Build the standalone `cmake-bns` binary (with all Lua modules embedded) using the bootstrap scripts:

```bash
# Linux / macOS / BSD
./Bootstrap.sh

# Windows (Developer Command Prompt)
Bootstrap.bat
```

The resulting executable is written to `bin/release/cmake-bns` (or `bin\release\cmake-bns.exe` on Windows).

If you modify any `.lua` files under `src/`, re-embed them and rebuild:

```bash
./bin/release/cmake-bns embed
make -C build/bootstrap config=release
```

Run the test suite (including the TOML parser, wizard, and importer tests):

```bash
./bin/release/cmake-bns test
```

---

## Usage & Workflows

### 1. Interactive `$EDITOR` Wizard

Run `cmake-bns init` (alias `cmake-bns wizard`) in your project root:

```bash
cmake-bns init
# Or generate build files immediately after finishing setup:
cmake-bns init --backend=gmake
```

1. **Project Discovery:** Scans the directory for an existing `CMakeLists.txt` or `Makefile` (extracting targets, sources, includes, defines, links, and compiler flags), falling back to a recursive C/C++ source/header scan (or blank placeholders in an empty directory).
2. **Step 1 (Required):** Opens a minimal TOML skeleton in `$EDITOR` for `[workspace]` and `[[targets]]`. Validation errors re-open the file with an inline error banner at the top (similar to `visudo`) so no edits are lost.
3. **Steps 2–4 (Optional `[y/N]` Prompts):**
   - **Step 2:** External libraries, link directories, OS-specific libraries, & `PUBLIC` exports (`public_includes`, `public_defines`).
   - **Step 3:** Compiler warnings, sanitizers, LTO, RTTI/exceptions, custom flags, & per-OS defines.
   - **Step 4:** Precompiled headers, pre/post-build commands, & working directory / debugger arguments.
   - *(Any optional settings discovered from an existing CMake/Makefile are automatically preserved even if you answer `N` to skip these steps.)*
4. **Output:** Emits a clean `cmake-bns.lua` and optionally runs your chosen backend (`gmake`, `ninja`, `vs2022`, `xcode4`, etc.).

### 2. Single-File Blank Template (`cmake-bns.toml`)

To skip interactive prompts and fill out a single declarative file by hand:

```bash
cmake-bns init --blank
```

This creates `cmake-bns.toml` with `# --- REQUIRED ---` fields at the top and `# --- OPTIONAL ---` fields below. Once filled in, either run any backend directly (which auto-detects `cmake-bns.toml` and generates `cmake-bns.lua` + build files):

```bash
cmake-bns gmake
```

Or explicitly generate `cmake-bns.lua` from a TOML file:

```bash
cmake-bns init --from=cmake-bns.toml --backend=ninja
```

### 3. Importing an Existing CMake or Makefile Project

To convert an existing `CMakeLists.txt` or `Makefile` / `Makefile.am` project without interactive prompts:

```bash
# Write a pre-populated cmake-bns.toml for inspection/tweaking:
cmake-bns init --import

# Or generate cmake-bns.lua and native build files directly in one step:
cmake-bns init --auto --backend=gmake --force
```

---

## Front-End CLI Options

| Flag / Action | Description |
| :--- | :--- |
| `cmake-bns init` (or `wizard`) | Launch the interactive `$EDITOR` TOML wizard in the current directory. |
| `--blank` | Skip interactive prompts and write a blank `cmake-bns.toml` with `# --- REQUIRED ---` and `# --- OPTIONAL ---` sections. |
| `--import` | Parse existing `CMakeLists.txt` / `Makefile` structure and write a pre-populated `cmake-bns.toml` without prompts. |
| `--auto` | Non-interactively scan `CMakeLists.txt` / `Makefile` (or directory sources) and emit `cmake-bns.lua` directly. |
| `--from=FILE` | Non-interactively validate `FILE` (e.g. `cmake-bns.toml`) and emit `cmake-bns.lua`. |
| `--backend=ACTION` | Immediately invoke backend `ACTION` (e.g. `gmake`, `ninja`, `vs2022`, `xcode4`, `compilecommands`) after generating `cmake-bns.lua`. |
| `--editor=CMD` | Override `$CMAKE_BNS_EDITOR` / `$VISUAL` / `$EDITOR` for interactive TOML editing. |
| `--force` | Overwrite an existing `cmake-bns.lua` or `cmake-bns.toml` without confirmation. |
| `--file=FILE.toml` | Pass a `.toml` configuration directly to any action (e.g. `cmake-bns --file=custom.toml gmake`). |
| `--init` | Run the interactive wizard first if `cmake-bns.lua` is missing before executing a backend action. |

---

## Upstream Premake Compatibility

Full compatibility with Lua project scripts (`cmake-bns.lua`, with automatic fallback to `premake5.lua` / `premake4.lua` for subprojects) and Premake modules is preserved:

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
