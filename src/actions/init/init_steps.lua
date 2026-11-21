--
-- actions/init/init_steps.lua
-- Renders the staged TOML skeleton files (Step 1 mandatory + Steps 2..4 optional)
-- and validates user-submitted TOML answers before emitting cmake-bns.lua.
--

	local p = premake
	p.init = p.init or {}
	p.init.steps = {}
	local steps = p.init.steps
	local toml = p.toml


	steps.TARGET_TYPES = {
		["exe"]         = "ConsoleApp",
		["console"]     = "ConsoleApp",
		["gui"]         = "WindowedApp",
		["windowed"]    = "WindowedApp",
		["static_lib"]  = "StaticLib",
		["static"]      = "StaticLib",
		["shared_lib"]  = "SharedLib",
		["shared"]      = "SharedLib",
		["dll"]         = "SharedLib",
		["header_only"] = "None",
		["interface"]   = "None",
		["custom"]      = "Utility",
		["utility"]     = "Utility",
	}

	steps.LANGUAGES = {
		["c"]       = { language = "C",   cdialect = nil },
		["c89"]     = { language = "C",   cdialect = "C89" },
		["c90"]     = { language = "C",   cdialect = "C90" },
		["c99"]     = { language = "C",   cdialect = "C99" },
		["c11"]     = { language = "C",   cdialect = "C11" },
		["c17"]     = { language = "C",   cdialect = "C17" },
		["c23"]     = { language = "C",   cdialect = "C23" },
		["gnu89"]   = { language = "C",   cdialect = "gnu89" },
		["gnu99"]   = { language = "C",   cdialect = "gnu99" },
		["gnu11"]   = { language = "C",   cdialect = "gnu11" },
		["gnu17"]   = { language = "C",   cdialect = "gnu17" },
		["gnu23"]   = { language = "C",   cdialect = "gnu23" },
		["c++"]     = { language = "C++", cppdialect = nil },
		["cpp"]     = { language = "C++", cppdialect = nil },
		["c++98"]   = { language = "C++", cppdialect = "C++98" },
		["c++11"]   = { language = "C++", cppdialect = "C++11" },
		["c++14"]   = { language = "C++", cppdialect = "C++14" },
		["c++17"]   = { language = "C++", cppdialect = "C++17" },
		["c++20"]   = { language = "C++", cppdialect = "C++20" },
		["c++23"]   = { language = "C++", cppdialect = "C++23" },
		["c++26"]   = { language = "C++", cppdialect = "C++26" },
		["c++latest"] = { language = "C++", cppdialect = "C++latest" },
		["gnu++11"] = { language = "C++", cppdialect = "gnu++11" },
		["gnu++14"] = { language = "C++", cppdialect = "gnu++14" },
		["gnu++17"] = { language = "C++", cppdialect = "gnu++17" },
		["gnu++20"] = { language = "C++", cppdialect = "gnu++20" },
		["gnu++23"] = { language = "C++", cppdialect = "gnu++23" },
		["c#"]      = { language = "C#" },
		["csharp"]  = { language = "C#" },
	}

	steps.MODES = {
		["debug"]          = "Debug",
		["release"]        = "Release",
		["relwithdebinfo"] = "RelWithDebInfo",
		["minsizerel"]     = "MinSizeRel",
	}

	steps.ARCHS = {
		["x86_64"]    = "x86_64",
		["x64"]       = "x86_64",
		["amd64"]     = "x86_64",
		["x86"]       = "x86",
		["win32"]     = "x86",
		["arm64"]     = "AARCH64",
		["aarch64"]   = "AARCH64",
		["arm"]       = "ARM",
		["riscv64"]   = "riscv64",
		["universal"] = "universal",
		["wasm32"]    = "wasm32",
		["wasm64"]    = "wasm64",
	}

	steps.WARNINGS = {
		["off"]        = "Off",
		["default"]    = "Default",
		["high"]       = "High",
		["extra"]      = "Extra",
		["everything"] = "Everything",
	}

	steps.SANITIZERS = {
		["address"]           = "Address",
		["asan"]              = "Address",
		["ub"]                = "UndefinedBehavior",
		["undefined"]         = "UndefinedBehavior",
		["undefinedbehavior"] = "UndefinedBehavior",
		["thread"]            = "Thread",
		["tsan"]              = "Thread",
		["fuzzer"]            = "Fuzzer",
	}


	local function checkAllowedKeys(tbl, allowedSet, contextName, errors)
		if type(tbl) ~= "table" then
			return
		end
		for k, _ in pairs(tbl) do
			if type(k) == "string" and not allowedSet[k] then
				table.insert(errors, string.format("%s: unknown field '%s'", contextName, k))
			end
		end
	end


	local function checkStringList(val, fieldPath, errors)
		if val == nil then
			return {}
		end
		if type(val) ~= "table" then
			table.insert(errors, string.format("%s must be a list of strings (e.g. [\"a\", \"b\"])", fieldPath))
			return {}
		end
		local out = {}
		for i = 1, #val do
			if type(val[i]) ~= "string" then
				table.insert(errors, string.format("%s[%d] must be a string", fieldPath, i))
			elseif val[i] ~= "" then
				table.insert(out, val[i])
			end
		end
		return out
	end


	local function parseToggle(val, fieldPath, errors)
		if val == nil or val == "" then
			return nil
		end
		if type(val) == "boolean" then
			return val and "On" or "Off"
		end
		if type(val) == "string" then
			local low = val:lower()
			if low == "on" or low == "true" or low == "yes" then
				return "On"
			elseif low == "off" or low == "false" or low == "no" then
				return "Off"
			elseif low == "default" then
				return "Default"
			end
		end
		table.insert(errors, string.format("%s must be \"on\", \"off\", true, false, or \"\" (default)", fieldPath))
		return nil
	end


-- =============================================================================
-- STEP 1: Mandatory Workspace & Targets
-- =============================================================================

	function steps.renderStep1(scan, imported)
		scan = scan or { found = false }

		local wksName, buildDir, modes, archs, targetEntries, scanBanner

		if imported and imported.step1 then
			local iwks = imported.step1.workspace
			wksName  = iwks.name or ""
			buildDir = iwks.buildDir or "build"
			modes    = {}
			for _, m in ipairs(iwks.modes or { "Debug", "Release" }) do
				table.insert(modes, m:lower())
			end
			archs = iwks.archs or { "x86_64" }
			targetEntries = {}
			for _, it in ipairs(imported.step1.targets or {}) do
				table.insert(targetEntries, {
					name     = it.name or "",
					type     = it.rawType or "exe",
					lang     = it.langKey or "c17",
					sources  = it.sources or {},
					includes = it.includes or {},
				})
			end
			scanBanner = string.format(
				"# Imported from %s: %d target(s) detected (optional links/defines/flags also pre-loaded).",
				imported.sourceLabel or "existing build file",
				#targetEntries
			)
		else
			wksName  = scan.found and scan.workspaceName or ""
			buildDir = scan.found and scan.buildDir or ""
			modes    = scan.found and scan.modes or {}
			archs    = scan.found and scan.archs or {}
			targetEntries = {
				{
					name     = scan.found and scan.targetName or "",
					type     = scan.found and scan.targetType or "",
					lang     = scan.found and scan.lang or "",
					sources  = scan.found and scan.sources or {},
					includes = scan.found and scan.includes or {},
				}
			}
			if scan.found then
				scanBanner = string.format(
					"# Directory scan: detected %d source file(s) and %d header file(s) in %s",
					scan.sourceCount or 0, scan.headerCount or 0, scan.rootDir or "."
				)
			else
				scanBanner = "# Directory scan: no C/C++ files detected; fill in the blank fields below."
			end
		end

		local lines = {
			"# =============================================================================",
			"# CMAKE-BNS INIT - STEP 1 OF 4: WORKSPACE & TARGETS (MANDATORY)",
			"#",
			"# Fill in or review the fields below, then save and close your editor.",
			"# Lines starting with '#' are ignored. Delete all content to abort.",
			"#",
			scanBanner,
			"# =============================================================================",
			"",
			"[workspace]",
			"# Required: workspace/solution name",
			"name      = " .. toml.formatString(wksName),
			"# Optional: defaults to \"build\", [\"debug\", \"release\"], and [\"x86_64\"] if left blank",
			"build_dir = " .. toml.formatString(buildDir),
			"modes     = " .. toml.formatStringArray(modes) .. "   # Options: \"debug\", \"release\", \"relwithdebinfo\", \"minsizerel\"",
			"archs     = " .. toml.formatStringArray(archs) .. "   # Options: \"x86_64\", \"x86\", \"arm64\", \"universal\"",
			"",
			"# -----------------------------------------------------------------------------",
			"# Targets to build (duplicate [[targets]] below to define multiple targets)",
			"#",
			"#   name     (required) : Target binary/project name",
			"#   type     (required) : \"exe\" | \"gui\" | \"static_lib\" | \"shared_lib\" | \"header_only\" | \"custom\"",
			"#   lang     (required) : \"c99\" | \"c11\" | \"c17\" | \"c23\" | \"gnu99\" | \"gnu11\" | \"c++17\" | \"c++20\" | \"c++23\" | \"c#\"",
			"#   sources  (required*): File paths or globs (*optional for header_only/custom)",
			"#   includes (optional) : Header search directories, e.g. [\"include\", \"src\"]",
			"# -----------------------------------------------------------------------------",
		}

		for _, te in ipairs(targetEntries) do
			table.insert(lines, "")
			table.insert(lines, "[[targets]]")
			table.insert(lines, "name     = " .. toml.formatString(te.name))
			table.insert(lines, "type     = " .. toml.formatString(te.type))
			table.insert(lines, "lang     = " .. toml.formatString(te.lang))
			table.insert(lines, "sources  = " .. toml.formatStringArray(te.sources))
			table.insert(lines, "includes = " .. toml.formatStringArray(te.includes))
		end

		table.insert(lines, "")
		return table.concat(lines, "\n")
	end


	function steps.validateStep1(data)
		local errors = {}
		checkAllowedKeys(data, { workspace = true, targets = true }, "step1", errors)

		local wks = data.workspace
		if type(wks) ~= "table" then
			table.insert(errors, "missing [workspace] section")
			wks = {}
		else
			checkAllowedKeys(wks, {
				name = true, build_dir = true, modes = true, archs = true
			}, "[workspace]", errors)
		end

		if type(wks.name) ~= "string" or wks.name:match("^%s*$") then
			table.insert(errors, "[workspace].name is required and cannot be blank")
		end

		local buildDir = (type(wks.build_dir) == "string" and wks.build_dir ~= "") and wks.build_dir or "build"

		local rawModes = checkStringList(wks.modes, "[workspace].modes", errors)
		if #rawModes == 0 then
			rawModes = { "debug", "release" }
		end
		local modes = {}
		for _, m in ipairs(rawModes) do
			local canonical = steps.MODES[m:lower()] or m
			if not table.contains(modes, canonical) then
				table.insert(modes, canonical)
			end
		end

		local rawArchs = checkStringList(wks.archs, "[workspace].archs", errors)
		if #rawArchs == 0 then
			rawArchs = { "x86_64" }
		end
		local archs = {}
		for _, a in ipairs(rawArchs) do
			local canonical = steps.ARCHS[a:lower()]
			if not canonical then
				table.insert(errors, string.format(
					"[workspace].archs: invalid architecture '%s' (allowed: x86_64, x86, arm64, arm, riscv64, universal, wasm32, wasm64)",
					a
				))
			elseif not table.contains(archs, canonical) then
				table.insert(archs, canonical)
			end
		end

		if type(data.targets) ~= "table" or #data.targets == 0 then
			table.insert(errors, "at least one [[targets]] entry is required")
		end

		local targets = {}
		local seenNames = {}
		for i, t in ipairs(data.targets or {}) do
			local ctx = string.format("targets[%d]", i)
			checkAllowedKeys(t, {
				name = true, type = true, lang = true, sources = true, includes = true
			}, ctx, errors)

			local tname = type(t.name) == "string" and t.name:match("^%s*(.-)%s*$") or ""
			if tname == "" then
				table.insert(errors, ctx .. ".name is required and cannot be blank")
			elseif seenNames[tname:lower()] then
				table.insert(errors, string.format("%s.name: duplicate target name '%s'", ctx, tname))
			else
				seenNames[tname:lower()] = true
			end

			local rawType = type(t.type) == "string" and t.type:lower():match("^%s*(.-)%s*$") or ""
			local kind = steps.TARGET_TYPES[rawType]
			if not kind then
				table.insert(errors, string.format(
					"%s.type: required field is '%s' (allowed: \"exe\", \"gui\", \"static_lib\", \"shared_lib\", \"header_only\", \"custom\")",
					ctx, tostring(t.type or "")
				))
			end

			local rawLang = type(t.lang) == "string" and t.lang:lower():match("^%s*(.-)%s*$") or ""
			local langInfo = steps.LANGUAGES[rawLang]
			if not langInfo then
				table.insert(errors, string.format(
					"%s.lang: required field is '%s' (allowed: c, c99, c11, c17, c23, c++, c++14, c++17, c++20, c++23, c#)",
					ctx, tostring(t.lang or "")
				))
			end

			local sources = checkStringList(t.sources, ctx .. ".sources", errors)
			if kind and kind ~= "None" and kind ~= "Utility" and #sources == 0 then
				table.insert(errors, string.format(
					"%s.sources: at least one source file or glob is required for target type '%s'",
					ctx, rawType
				))
			end

			local includes = checkStringList(t.includes, ctx .. ".includes", errors)

			table.insert(targets, {
				name       = tname,
				rawType    = rawType,
				kind       = kind,
				language   = langInfo and langInfo.language or nil,
				cdialect   = langInfo and langInfo.cdialect or nil,
				cppdialect = langInfo and langInfo.cppdialect or nil,
				sources    = sources,
				includes   = includes,
			})
		end

		if #errors > 0 then
			return nil, errors
		end

		return {
			workspace = {
				name     = wks.name:match("^%s*(.-)%s*$"),
				buildDir = buildDir,
				modes    = modes,
				archs    = archs,
			},
			targets = targets,
		}
	end


-- =============================================================================
-- STEP 2: Optional Dependencies, Linking & Library Exports (Blank Defaults)
-- =============================================================================

	function steps.renderStep2(step1, initialStep2)
		local initExports = initialStep2 and initialStep2.exports or {}
		local initDeps    = initialStep2 and initialStep2.deps or {}
		local initSubs    = initialStep2 and initialStep2.subprojects or {}

		local targetNames = {}
		local libTargets = {}
		for _, t in ipairs(step1.targets) do
			table.insert(targetNames, '"' .. t.name .. '"')
			if t.kind == "StaticLib" or t.kind == "SharedLib" or t.kind == "None" then
				table.insert(libTargets, t)
			end
		end

		local lines = {
			"# =============================================================================",
			"# CMAKE-BNS INIT - STEP 2 OF 4: DEPENDENCIES & LINKING (OPTIONAL)",
			"#",
			"# Enter any external libraries, include/lib directories, or sibling target links.",
			"# Leave fields blank ([] / \"\") if unused. Save and close when finished.",
			"# Targets from Step 1: " .. table.concat(targetNames, ", "),
			"# =============================================================================",
			"",
		}

		if #libTargets > 0 then
			table.insert(lines, "# -----------------------------------------------------------------------------")
			table.insert(lines, "# Public Library Exports")
			table.insert(lines, "# Any sibling target that links a library below automatically inherits these.")
			table.insert(lines, "# -----------------------------------------------------------------------------")
			for _, lib in ipairs(libTargets) do
				local k = toml.formatKey(lib.name)
				local exp = initExports[lib.name] or {}
				table.insert(lines, "[exports." .. k .. "]")
				table.insert(lines, "public_includes = " .. toml.formatStringArray(exp.publicIncludes))
				table.insert(lines, "public_defines  = " .. toml.formatStringArray(exp.publicDefines))
				table.insert(lines, "")
			end
		end

		table.insert(lines, "# -----------------------------------------------------------------------------")
		table.insert(lines, "# Per-Target Dependencies")
		table.insert(lines, "#   links           : Sibling target names or cross-platform libraries")
		table.insert(lines, "#   system_includes : 3rd-party include directories (warnings suppressed)")
		table.insert(lines, "#   lib_dirs        : Directories containing prebuilt .a / .so / .lib files")
		table.insert(lines, "#   *_links         : OS-specific libraries (e.g. \"pthread\", \"opengl32\", \"Cocoa.framework\")")
		table.insert(lines, "# -----------------------------------------------------------------------------")

		for _, t in ipairs(step1.targets) do
			local k = toml.formatKey(t.name)
			local dep = initDeps[t.name] or {}
			table.insert(lines, "[deps." .. k .. "]")
			table.insert(lines, "links           = " .. toml.formatStringArray(dep.links))
			table.insert(lines, "system_includes = " .. toml.formatStringArray(dep.systemIncludes))
			table.insert(lines, "lib_dirs        = " .. toml.formatStringArray(dep.libDirs))
			table.insert(lines, "windows_links   = " .. toml.formatStringArray(dep.windowsLinks))
			table.insert(lines, "linux_links     = " .. toml.formatStringArray(dep.linuxLinks))
			table.insert(lines, "macos_links     = " .. toml.formatStringArray(dep.macosLinks))
			table.insert(lines, "")
		end

		table.insert(lines, "# -----------------------------------------------------------------------------")
		table.insert(lines, "# External Premake Subproject Directories (calls `include \"path\"`)")
		table.insert(lines, "# -----------------------------------------------------------------------------")
		table.insert(lines, "[external]")
		table.insert(lines, "subprojects = " .. toml.formatStringArray(initSubs))
		table.insert(lines, "")

		return table.concat(lines, "\n")
	end


	function steps.validateStep2(data, step1)
		local errors = {}
		checkAllowedKeys(data, { exports = true, deps = true, external = true }, "step2", errors)

		local targetByName = {}
		for _, t in ipairs(step1.targets) do
			targetByName[t.name] = t
		end

		local exports = {}
		if data.exports ~= nil then
			if type(data.exports) ~= "table" then
				table.insert(errors, "[exports] must be a table")
			else
				for tname, blk in pairs(data.exports) do
					if not targetByName[tname] then
						table.insert(errors, string.format("[exports.%s]: unknown target '%s'", tname, tname))
					elseif type(blk) ~= "table" then
						table.insert(errors, string.format("[exports.%s] must be a table", tname))
					else
						checkAllowedKeys(blk, { public_includes = true, public_defines = true }, "[exports." .. tname .. "]", errors)
						exports[tname] = {
							publicIncludes = checkStringList(blk.public_includes, "[exports." .. tname .. "].public_includes", errors),
							publicDefines  = checkStringList(blk.public_defines, "[exports." .. tname .. "].public_defines", errors),
						}
					end
				end
			end
		end

		local deps = {}
		if data.deps ~= nil then
			if type(data.deps) ~= "table" then
				table.insert(errors, "[deps] must be a table")
			else
				for tname, blk in pairs(data.deps) do
					if not targetByName[tname] then
						table.insert(errors, string.format("[deps.%s]: unknown target '%s'", tname, tname))
					elseif type(blk) ~= "table" then
						table.insert(errors, string.format("[deps.%s] must be a table", tname))
					else
						local ctx = "[deps." .. tname .. "]"
						checkAllowedKeys(blk, {
							links = true, system_includes = true, lib_dirs = true,
							windows_links = true, linux_links = true, macos_links = true,
						}, ctx, errors)
						deps[tname] = {
							links          = checkStringList(blk.links, ctx .. ".links", errors),
							systemIncludes = checkStringList(blk.system_includes, ctx .. ".system_includes", errors),
							libDirs        = checkStringList(blk.lib_dirs, ctx .. ".lib_dirs", errors),
							windowsLinks   = checkStringList(blk.windows_links, ctx .. ".windows_links", errors),
							linuxLinks     = checkStringList(blk.linux_links, ctx .. ".linux_links", errors),
							macosLinks     = checkStringList(blk.macos_links, ctx .. ".macos_links", errors),
						}
					end
				end
			end
		end

		local subprojects = {}
		if data.external ~= nil then
			if type(data.external) ~= "table" then
				table.insert(errors, "[external] must be a table")
			else
				checkAllowedKeys(data.external, { subprojects = true }, "[external]", errors)
				subprojects = checkStringList(data.external.subprojects, "[external].subprojects", errors)
			end
		end

		if #errors > 0 then
			return nil, errors
		end

		return {
			exports     = exports,
			deps        = deps,
			subprojects = subprojects,
		}
	end


-- =============================================================================
-- STEP 3: Optional Compiler Policy & OS Overrides (Blank Defaults)
-- =============================================================================

	function steps.renderStep3(step1, initialStep3)
		local icomp = initialStep3 and initialStep3.compiler or {}
		local iplat = initialStep3 and initialStep3.platforms or {}
		local iovr  = initialStep3 and initialStep3.targetOverrides or {}

		local warnStr = icomp.warningsKey or (icomp.warnings and icomp.warnings:lower()) or ""
		local rttiStr = icomp.rtti and icomp.rtti:lower() or ""
		local excStr  = icomp.exceptions and icomp.exceptions:lower() or ""
		local srunStr = icomp.staticRuntime and icomp.staticRuntime:lower() or ""
		local sans    = {}
		for _, s in ipairs(icomp.debugSanitizers or {}) do
			table.insert(sans, s:lower() == "undefinedbehavior" and "ub" or s:lower())
		end

		local function platBlock(osKey)
			local b = iplat[osKey] or {}
			return {
				"[platform." .. osKey .. "]",
				"defines         = " .. toml.formatStringArray(b.defines),
				"exclude_sources = " .. toml.formatStringArray(b.excludeSources),
				"compiler_flags  = " .. toml.formatStringArray(b.compilerFlags),
				"linker_flags    = " .. toml.formatStringArray(b.linkerFlags),
				"",
			}
		end

		local lines = {
			"# =============================================================================",
			"# CMAKE-BNS INIT - STEP 3 OF 4: COMPILER SETTINGS & OS OVERRIDES (OPTIONAL)",
			"#",
			"# Leave fields at their blank defaults (\"\", [], false) to keep toolchain defaults.",
			"# =============================================================================",
			"",
			"[compiler]",
			"warnings           = " .. toml.formatString(warnStr) .. "      # \"off\" | \"default\" | \"high\" | \"extra\" | \"everything\"",
			"warnings_as_errors = " .. tostring(icomp.warningsAsErrors == true) .. "   # true = treat compiler warnings as errors (-Werror / /WX)",
			"rtti               = " .. toml.formatString(rttiStr) .. "      # \"on\" | \"off\" (\"\" = toolchain default)",
			"exceptions         = " .. toml.formatString(excStr) .. "      # \"on\" | \"off\" (\"\" = toolchain default)",
			"static_runtime     = " .. toml.formatString(srunStr) .. "      # \"on\" | \"off\" (\"\" = toolchain default)",
			"lto_in_release     = " .. tostring(icomp.ltoInRelease == true) .. "   # true = enable Link-Time Optimization in Release mode",
			"debug_sanitizers   = " .. toml.formatStringArray(sans) .. "      # Options: \"address\", \"ub\", \"thread\", \"fuzzer\"",
			"",
			"# -----------------------------------------------------------------------------",
			"# OS-Specific Workspace Overrides",
			"# -----------------------------------------------------------------------------",
		}

		for _, osKey in ipairs({ "windows", "linux", "macos" }) do
			for _, l in ipairs(platBlock(osKey)) do
				table.insert(lines, l)
			end
		end

		table.insert(lines, "# -----------------------------------------------------------------------------")
		table.insert(lines, "# Per-Target Compiler Tweaks & Precompiled Headers")
		table.insert(lines, "# -----------------------------------------------------------------------------")

		for _, t in ipairs(step1.targets) do
			local k = toml.formatKey(t.name)
			local ov = iovr[t.name] or {}
			table.insert(lines, "[target_overrides." .. k .. "]")
			table.insert(lines, "pch_header      = " .. toml.formatString(ov.pchHeader or ""))
			table.insert(lines, "pch_source      = " .. toml.formatString(ov.pchSource or ""))
			table.insert(lines, "defines         = " .. toml.formatStringArray(ov.defines))
			table.insert(lines, "exclude_sources = " .. toml.formatStringArray(ov.excludeSources))
			table.insert(lines, "compiler_flags  = " .. toml.formatStringArray(ov.compilerFlags))
			table.insert(lines, "linker_flags    = " .. toml.formatStringArray(ov.linkerFlags))
			table.insert(lines, "")
		end

		return table.concat(lines, "\n")
	end


	function steps.validateStep3(data, step1)
		local errors = {}
		checkAllowedKeys(data, { compiler = true, platform = true, target_overrides = true }, "step3", errors)

		local targetByName = {}
		for _, t in ipairs(step1.targets) do
			targetByName[t.name] = t
		end

		local comp = data.compiler or {}
		if type(comp) ~= "table" then
			table.insert(errors, "[compiler] must be a table")
			comp = {}
		else
			checkAllowedKeys(comp, {
				warnings = true, warnings_as_errors = true, rtti = true,
				exceptions = true, static_runtime = true, lto_in_release = true,
				debug_sanitizers = true,
			}, "[compiler]", errors)
		end

		local warnings = nil
		if comp.warnings ~= nil and comp.warnings ~= "" then
			if type(comp.warnings) ~= "string" or not steps.WARNINGS[comp.warnings:lower()] then
				table.insert(errors, "[compiler].warnings must be \"off\", \"default\", \"high\", \"extra\", \"everything\", or \"\"")
			else
				warnings = steps.WARNINGS[comp.warnings:lower()]
			end
		end

		if comp.warnings_as_errors ~= nil and type(comp.warnings_as_errors) ~= "boolean" then
			table.insert(errors, "[compiler].warnings_as_errors must be true or false")
		end
		if comp.lto_in_release ~= nil and type(comp.lto_in_release) ~= "boolean" then
			table.insert(errors, "[compiler].lto_in_release must be true or false")
		end

		local rtti = parseToggle(comp.rtti, "[compiler].rtti", errors)
		local exceptions = parseToggle(comp.exceptions, "[compiler].exceptions", errors)
		local staticRuntime = parseToggle(comp.static_runtime, "[compiler].static_runtime", errors)

		local rawSans = checkStringList(comp.debug_sanitizers, "[compiler].debug_sanitizers", errors)
		local sanitizers = {}
		for _, s in ipairs(rawSans) do
			local mapped = steps.SANITIZERS[s:lower()]
			if not mapped then
				table.insert(errors, string.format(
					"[compiler].debug_sanitizers: invalid sanitizer '%s' (allowed: address, ub, thread, fuzzer)",
					s
				))
			elseif not table.contains(sanitizers, mapped) then
				table.insert(sanitizers, mapped)
			end
		end

		local platforms = {}
		if data.platform ~= nil then
			if type(data.platform) ~= "table" then
				table.insert(errors, "[platform] must be a table")
			else
				checkAllowedKeys(data.platform, { windows = true, linux = true, macos = true }, "[platform]", errors)
				for osName, blk in pairs(data.platform) do
					if type(blk) == "table" then
						local ctx = "[platform." .. osName .. "]"
						checkAllowedKeys(blk, {
							defines = true, exclude_sources = true, compiler_flags = true, linker_flags = true,
						}, ctx, errors)
						platforms[osName] = {
							defines        = checkStringList(blk.defines, ctx .. ".defines", errors),
							excludeSources = checkStringList(blk.exclude_sources, ctx .. ".exclude_sources", errors),
							compilerFlags  = checkStringList(blk.compiler_flags, ctx .. ".compiler_flags", errors),
							linkerFlags    = checkStringList(blk.linker_flags, ctx .. ".linker_flags", errors),
						}
					end
				end
			end
		end

		local targetOverrides = {}
		if data.target_overrides ~= nil then
			if type(data.target_overrides) ~= "table" then
				table.insert(errors, "[target_overrides] must be a table")
			else
				for tname, blk in pairs(data.target_overrides) do
					if not targetByName[tname] then
						table.insert(errors, string.format("[target_overrides.%s]: unknown target '%s'", tname, tname))
					elseif type(blk) ~= "table" then
						table.insert(errors, string.format("[target_overrides.%s] must be a table", tname))
					else
						local ctx = "[target_overrides." .. tname .. "]"
						checkAllowedKeys(blk, {
							pch_header = true, pch_source = true, defines = true,
							exclude_sources = true, compiler_flags = true, linker_flags = true,
						}, ctx, errors)
						if blk.pch_header ~= nil and type(blk.pch_header) ~= "string" then
							table.insert(errors, ctx .. ".pch_header must be a string")
						end
						if blk.pch_source ~= nil and type(blk.pch_source) ~= "string" then
							table.insert(errors, ctx .. ".pch_source must be a string")
						end
						targetOverrides[tname] = {
							pchHeader      = (type(blk.pch_header) == "string" and blk.pch_header ~= "") and blk.pch_header or nil,
							pchSource      = (type(blk.pch_source) == "string" and blk.pch_source ~= "") and blk.pch_source or nil,
							defines        = checkStringList(blk.defines, ctx .. ".defines", errors),
							excludeSources = checkStringList(blk.exclude_sources, ctx .. ".exclude_sources", errors),
							compilerFlags  = checkStringList(blk.compiler_flags, ctx .. ".compiler_flags", errors),
							linkerFlags    = checkStringList(blk.linker_flags, ctx .. ".linker_flags", errors),
						}
					end
				end
			end
		end

		if #errors > 0 then
			return nil, errors
		end

		return {
			compiler = {
				warnings         = warnings,
				warningsAsErrors = comp.warnings_as_errors == true,
				rtti             = rtti,
				exceptions       = exceptions,
				staticRuntime    = staticRuntime,
				ltoInRelease     = comp.lto_in_release == true,
				debugSanitizers  = sanitizers,
			},
			platforms       = platforms,
			targetOverrides = targetOverrides,
		}
	end


-- =============================================================================
-- STEP 4: Optional Build Hooks & Debugger Settings (Blank Defaults)
-- =============================================================================

	function steps.renderStep4(step1, initialStep4)
		local idbg   = initialStep4 and initialStep4.debug or {}
		local ihooks = initialStep4 and initialStep4.hooks or {}

		local runnableTargets = {}
		for _, t in ipairs(step1.targets) do
			if t.kind == "ConsoleApp" or t.kind == "WindowedApp" then
				table.insert(runnableTargets, t)
			end
		end

		local lines = {
			"# =============================================================================",
			"# CMAKE-BNS INIT - STEP 4 OF 4: BUILD HOOKS & DEBUGGER SETTINGS (OPTIONAL)",
			"#",
			"# Leave fields blank (\"\" / []) if unused. Portable command tokens:",
			"#   {COPYFILE} path/to/src %{cfg.targetdir}/dst",
			"#   {COPYDIR}  assets      %{cfg.targetdir}/assets",
			"#   {MKDIR}    %{cfg.targetdir}/logs",
			"# =============================================================================",
			"",
		}

		if #runnableTargets > 0 then
			table.insert(lines, "# -----------------------------------------------------------------------------")
			table.insert(lines, "# IDE Debugger Launch Settings (for executable targets)")
			table.insert(lines, "# -----------------------------------------------------------------------------")
			for _, t in ipairs(runnableTargets) do
				local k = toml.formatKey(t.name)
				local d = idbg[t.name] or {}
				table.insert(lines, "[debug." .. k .. "]")
				table.insert(lines, "working_dir = " .. toml.formatString(d.workingDir or ""))
				table.insert(lines, "command     = " .. toml.formatString(d.command or ""))
				table.insert(lines, "args        = " .. toml.formatStringArray(d.args))
				table.insert(lines, "env         = " .. toml.formatStringArray(d.env))
				table.insert(lines, "")
			end
		end

		table.insert(lines, "# -----------------------------------------------------------------------------")
		table.insert(lines, "# Custom Build Lifecycle Commands")
		table.insert(lines, "# -----------------------------------------------------------------------------")
		for _, t in ipairs(step1.targets) do
			local k = toml.formatKey(t.name)
			local h = ihooks[t.name] or {}
			table.insert(lines, "[hooks." .. k .. "]")
			table.insert(lines, "pre_build  = " .. toml.formatStringArray(h.preBuild))
			table.insert(lines, "pre_link   = " .. toml.formatStringArray(h.preLink))
			table.insert(lines, "post_build = " .. toml.formatStringArray(h.postBuild))
			table.insert(lines, "")
		end

		return table.concat(lines, "\n")
	end


	function steps.validateStep4(data, step1)
		local errors = {}
		checkAllowedKeys(data, { debug = true, hooks = true }, "step4", errors)

		local targetByName = {}
		for _, t in ipairs(step1.targets) do
			targetByName[t.name] = t
		end

		local debugCfg = {}
		if data.debug ~= nil then
			if type(data.debug) ~= "table" then
				table.insert(errors, "[debug] must be a table")
			else
				for tname, blk in pairs(data.debug) do
					if not targetByName[tname] then
						table.insert(errors, string.format("[debug.%s]: unknown target '%s'", tname, tname))
					elseif type(blk) ~= "table" then
						table.insert(errors, string.format("[debug.%s] must be a table", tname))
					else
						local ctx = "[debug." .. tname .. "]"
						checkAllowedKeys(blk, {
							working_dir = true, command = true, args = true, env = true,
						}, ctx, errors)
						if blk.working_dir ~= nil and type(blk.working_dir) ~= "string" then
							table.insert(errors, ctx .. ".working_dir must be a string")
						end
						if blk.command ~= nil and type(blk.command) ~= "string" then
							table.insert(errors, ctx .. ".command must be a string")
						end
						debugCfg[tname] = {
							workingDir = (type(blk.working_dir) == "string" and blk.working_dir ~= "") and blk.working_dir or nil,
							command    = (type(blk.command) == "string" and blk.command ~= "") and blk.command or nil,
							args       = checkStringList(blk.args, ctx .. ".args", errors),
							env        = checkStringList(blk.env, ctx .. ".env", errors),
						}
					end
				end
			end
		end

		local hooksCfg = {}
		if data.hooks ~= nil then
			if type(data.hooks) ~= "table" then
				table.insert(errors, "[hooks] must be a table")
			else
				for tname, blk in pairs(data.hooks) do
					if not targetByName[tname] then
						table.insert(errors, string.format("[hooks.%s]: unknown target '%s'", tname, tname))
					elseif type(blk) ~= "table" then
						table.insert(errors, string.format("[hooks.%s] must be a table", tname))
					else
						local ctx = "[hooks." .. tname .. "]"
						checkAllowedKeys(blk, {
							pre_build = true, pre_link = true, post_build = true,
						}, ctx, errors)
						hooksCfg[tname] = {
							preBuild  = checkStringList(blk.pre_build, ctx .. ".pre_build", errors),
							preLink   = checkStringList(blk.pre_link, ctx .. ".pre_link", errors),
							postBuild = checkStringList(blk.post_build, ctx .. ".post_build", errors),
						}
					end
				end
			end
		end

		if #errors > 0 then
			return nil, errors
		end

		return {
			debug = debugCfg,
			hooks = hooksCfg,
		}
	end


-- =============================================================================
-- UNIFIED BLANK CONFIG TEMPLATE (`cmake-bns init --blank`)
-- =============================================================================

	function steps.renderBlankConfig()
		local lines = {
			"# =============================================================================",
			"# CMAKE-BNS PROJECT CONFIGURATION (BLANK TEMPLATE)",
			"#",
			"# 1. Fill in the fields marked REQUIRED below.",
			"# 2. Everything past each OPTIONAL marker can stay blank (\"\", [], false).",
			"# 3. Generate cmake-bns.lua : cmake-bns init --from=cmake-bns.toml",
			"#    Or build directly      : cmake-bns gmake   (or ninja, vs2022, xcode4)",
			"# =============================================================================",
			"",
			"[workspace]",
			"# --- REQUIRED ---",
			"name = \"\"",
			"",
			"# --- OPTIONAL (defaults: build_dir = \"build\", modes = [\"debug\", \"release\"], archs = [\"x86_64\"]) ---",
			"build_dir   = \"\"",
			"modes       = []   # \"debug\" | \"release\" | \"relwithdebinfo\" | \"minsizerel\"",
			"archs       = []   # \"x86_64\" | \"x86\" | \"arm64\" | \"universal\"",
			"subprojects = []   # External Premake directories, e.g. [\"vendor/glfw\"]",
			"",
			"# =============================================================================",
			"# TARGETS (duplicate [[targets]] to define multiple binaries or libraries)",
			"# =============================================================================",
			"",
			"[[targets]]",
			"# --- REQUIRED ---",
			"name    = \"\"       # Target binary / project name",
			"type    = \"\"       # \"exe\" | \"gui\" | \"static_lib\" | \"shared_lib\" | \"header_only\" | \"custom\"",
			"lang    = \"\"       # \"c99\" | \"c11\" | \"c17\" | \"c23\" | \"c++14\" | \"c++17\" | \"c++20\" | \"c++23\" | \"c#\"",
			"sources = []       # File globs, e.g. [\"src/**.cpp\", \"include/**.h\"] (optional for header_only/custom)",
			"",
			"# --- OPTIONAL TARGET SETTINGS (everything below for this target is optional) ---",
			"includes          = []   # Header search directories, e.g. [\"include\", \"src\"]",
			"public_includes   = []   # (Libraries) Exported include dirs inherited by linking targets",
			"public_defines    = []   # (Libraries) Exported preprocessor defines",
			"",
			"links             = []   # Sibling target names or cross-platform libraries",
			"system_includes   = []   # 3rd-party header directories (warnings suppressed)",
			"lib_dirs          = []   # Library search directories (.a / .so / .lib)",
			"windows_links     = []   # Windows-only libraries, e.g. [\"user32\", \"gdi32\"]",
			"linux_links       = []   # Linux-only libraries, e.g. [\"pthread\", \"dl\", \"m\"]",
			"macos_links       = []   # macOS-only libraries/frameworks, e.g. [\"Cocoa.framework\"]",
			"",
			"defines           = []   # Target preprocessor defines",
			"exclude_sources   = []   # Glob patterns to exclude from `sources`",
			"compiler_flags    = []   # Extra raw compiler flags",
			"linker_flags      = []   # Extra raw linker flags",
			"pch_header        = \"\"   # Precompiled header file, e.g. \"pch.h\"",
			"pch_source        = \"\"   # Precompiled header source (Visual Studio only, e.g. \"src/pch.cpp\")",
			"",
			"debug_working_dir = \"\"   # IDE debugger working directory",
			"debug_command     = \"\"   # Custom executable path when debugging",
			"debug_args        = []   # Arguments passed when debugging",
			"debug_env         = []   # Debugger environment variables, e.g. [\"FOO=1\"]",
			"",
			"pre_build         = []   # Commands before compile ({MKDIR}, {COPYFILE}, {COPYDIR})",
			"pre_link          = []   # Commands before link",
			"post_build        = []   # Commands after link",
			"",
			"# =============================================================================",
			"# OPTIONAL WORKSPACE-WIDE COMPILER & PLATFORM OVERRIDES",
			"# Everything below this line is optional (leave \"\", [], false if unused).",
			"# =============================================================================",
			"",
			"[compiler]",
			"warnings           = \"\"      # \"off\" | \"default\" | \"high\" | \"extra\" | \"everything\"",
			"warnings_as_errors = false   # true = treat compiler warnings as errors (-Werror / /WX)",
			"rtti               = \"\"      # \"on\" | \"off\" (\"\" = toolchain default)",
			"exceptions         = \"\"      # \"on\" | \"off\" (\"\" = toolchain default)",
			"static_runtime     = \"\"      # \"on\" | \"off\" (\"\" = toolchain default)",
			"lto_in_release     = false   # true = enable Link-Time Optimization in Release mode",
			"debug_sanitizers   = []      # \"address\" | \"ub\" | \"thread\" | \"fuzzer\"",
			"",
			"[platform.windows]",
			"defines         = []",
			"exclude_sources = []",
			"compiler_flags  = []",
			"linker_flags    = []",
			"",
			"[platform.linux]",
			"defines         = []",
			"exclude_sources = []",
			"compiler_flags  = []",
			"linker_flags    = []",
			"",
			"[platform.macos]",
			"defines         = []",
			"exclude_sources = []",
			"compiler_flags  = []",
			"linker_flags    = []",
			"",
		}

		return table.concat(lines, "\n")
	end


	function steps.validateUnifiedToml(data)
		local errors = {}
		checkAllowedKeys(data, {
			workspace = true, targets = true, compiler = true, platform = true,
			exports = true, deps = true, external = true,
			target_overrides = true, debug = true, hooks = true,
		}, "config", errors)

		local wks = data.workspace
		if type(wks) ~= "table" then
			table.insert(errors, "missing [workspace] section")
			wks = {}
		else
			checkAllowedKeys(wks, {
				name = true, build_dir = true, modes = true, archs = true, subprojects = true,
			}, "[workspace]", errors)
		end

		-- Extract step1-shaped data while stripping inline optional target keys
		local step1Input = {
			workspace = {
				name      = wks.name,
				build_dir = wks.build_dir,
				modes     = wks.modes,
				archs     = wks.archs,
			},
			targets = {},
		}

		local allowedTargetKeys = {
			-- Required
			name = true, type = true, lang = true, sources = true,
			-- Optional inline target fields
			includes = true, public_includes = true, public_defines = true,
			links = true, system_includes = true, lib_dirs = true,
			windows_links = true, linux_links = true, macos_links = true,
			defines = true, exclude_sources = true, compiler_flags = true, linker_flags = true,
			pch_header = true, pch_source = true,
			debug_working_dir = true, debug_command = true, debug_args = true, debug_env = true,
			pre_build = true, pre_link = true, post_build = true,
		}

		for i, t in ipairs(data.targets or {}) do
			local ctx = string.format("targets[%d]", i)
			if type(t) ~= "table" then
				table.insert(errors, ctx .. " must be a table")
			else
				checkAllowedKeys(t, allowedTargetKeys, ctx, errors)
				table.insert(step1Input.targets, {
					name     = t.name,
					type     = t.type,
					lang     = t.lang,
					sources  = t.sources,
					includes = t.includes,
				})
			end
		end

		local step1, errs1 = steps.validateStep1(step1Input)
		if errs1 then
			for _, e in ipairs(errs1) do
				table.insert(errors, e)
			end
		end

		-- Build merged Step 2, Step 3, and Step 4 input tables from inline target fields + optional sections
		local exportsInput = (type(data.exports) == "table") and table.deepcopy(data.exports) or {}
		local depsInput    = (type(data.deps) == "table") and table.deepcopy(data.deps) or {}
		local ovrInput     = (type(data.target_overrides) == "table") and table.deepcopy(data.target_overrides) or {}
		local dbgInput     = (type(data.debug) == "table") and table.deepcopy(data.debug) or {}
		local hooksInput   = (type(data.hooks) == "table") and table.deepcopy(data.hooks) or {}

		for _, t in ipairs(data.targets or {}) do
			if type(t) == "table" and type(t.name) == "string" and t.name ~= "" then
				local tname = t.name:match("^%s*(.-)%s*$")

				if t.public_includes ~= nil or t.public_defines ~= nil then
					exportsInput[tname] = exportsInput[tname] or {}
					exportsInput[tname].public_includes = exportsInput[tname].public_includes or t.public_includes
					exportsInput[tname].public_defines  = exportsInput[tname].public_defines  or t.public_defines
				end

				if t.links ~= nil or t.system_includes ~= nil or t.lib_dirs ~= nil
					or t.windows_links ~= nil or t.linux_links ~= nil or t.macos_links ~= nil then
					depsInput[tname] = depsInput[tname] or {}
					depsInput[tname].links           = depsInput[tname].links           or t.links
					depsInput[tname].system_includes = depsInput[tname].system_includes or t.system_includes
					depsInput[tname].lib_dirs        = depsInput[tname].lib_dirs        or t.lib_dirs
					depsInput[tname].windows_links   = depsInput[tname].windows_links   or t.windows_links
					depsInput[tname].linux_links     = depsInput[tname].linux_links     or t.linux_links
					depsInput[tname].macos_links     = depsInput[tname].macos_links     or t.macos_links
				end

				if t.pch_header ~= nil or t.pch_source ~= nil or t.defines ~= nil
					or t.exclude_sources ~= nil or t.compiler_flags ~= nil or t.linker_flags ~= nil then
					ovrInput[tname] = ovrInput[tname] or {}
					ovrInput[tname].pch_header      = ovrInput[tname].pch_header      or t.pch_header
					ovrInput[tname].pch_source      = ovrInput[tname].pch_source      or t.pch_source
					ovrInput[tname].defines         = ovrInput[tname].defines         or t.defines
					ovrInput[tname].exclude_sources = ovrInput[tname].exclude_sources or t.exclude_sources
					ovrInput[tname].compiler_flags  = ovrInput[tname].compiler_flags  or t.compiler_flags
					ovrInput[tname].linker_flags    = ovrInput[tname].linker_flags    or t.linker_flags
				end

				if t.debug_working_dir ~= nil or t.debug_command ~= nil or t.debug_args ~= nil or t.debug_env ~= nil then
					dbgInput[tname] = dbgInput[tname] or {}
					dbgInput[tname].working_dir = dbgInput[tname].working_dir or t.debug_working_dir
					dbgInput[tname].command     = dbgInput[tname].command     or t.debug_command
					dbgInput[tname].args        = dbgInput[tname].args        or t.debug_args
					dbgInput[tname].env         = dbgInput[tname].env         or t.debug_env
				end

				if t.pre_build ~= nil or t.pre_link ~= nil or t.post_build ~= nil then
					hooksInput[tname] = hooksInput[tname] or {}
					hooksInput[tname].pre_build  = hooksInput[tname].pre_build  or t.pre_build
					hooksInput[tname].pre_link   = hooksInput[tname].pre_link   or t.pre_link
					hooksInput[tname].post_build = hooksInput[tname].post_build or t.post_build
				end
			end
		end

		local wksSubs = checkStringList(wks.subprojects, "[workspace].subprojects", errors)
		local extSubs = {}
		if data.external ~= nil then
			if type(data.external) ~= "table" then
				table.insert(errors, "[external] must be a table")
			else
				checkAllowedKeys(data.external, { subprojects = true }, "[external]", errors)
				extSubs = checkStringList(data.external.subprojects, "[external].subprojects", errors)
			end
		end
		local mergedSubs = table.join(wksSubs, extSubs)

		local dummyStep1 = step1 or { targets = {} }
		local step2, errs2 = steps.validateStep2({
			exports  = exportsInput,
			deps     = depsInput,
			external = { subprojects = mergedSubs },
		}, dummyStep1)
		if errs2 and step1 then
			for _, e in ipairs(errs2) do table.insert(errors, e) end
		end

		local step3, errs3 = steps.validateStep3({
			compiler         = data.compiler,
			platform         = data.platform,
			target_overrides = ovrInput,
		}, dummyStep1)
		if errs3 and step1 then
			for _, e in ipairs(errs3) do table.insert(errors, e) end
		end

		local step4, errs4 = steps.validateStep4({
			debug = dbgInput,
			hooks = hooksInput,
		}, dummyStep1)
		if errs4 and step1 then
			for _, e in ipairs(errs4) do table.insert(errors, e) end
		end

		if #errors > 0 then
			return nil, errors
		end

		return {
			step1 = step1,
			step2 = step2,
			step3 = step3,
			step4 = step4,
		}
	end


---
-- Filter an imported state's Step 2/3/4 maps so they stay aligned with the
-- target names actually kept after Step 1 editing.
---
	function steps.reconcileImportedState(step1, imported)
		if not imported then
			return nil, nil, nil
		end
		local validTargets = {}
		for _, t in ipairs(step1.targets or {}) do
			validTargets[t.name] = true
		end

		local function filterByTarget(map)
			local out = {}
			for k, v in pairs(map or {}) do
				if validTargets[k] then
					out[k] = v
				end
			end
			return out
		end

		local s2 = imported.step2 and {
			exports     = filterByTarget(imported.step2.exports),
			deps        = filterByTarget(imported.step2.deps),
			subprojects = imported.step2.subprojects or {},
		} or nil

		local s3 = imported.step3 and {
			compiler        = imported.step3.compiler or {},
			platforms       = imported.step3.platforms or {},
			targetOverrides = filterByTarget(imported.step3.targetOverrides),
		} or nil

		local s4 = imported.step4 and {
			debug = filterByTarget(imported.step4.debug),
			hooks = filterByTarget(imported.step4.hooks),
		} or nil

		return s2, s3, s4
	end


	local function tableHasNonEmpty(tbl)
		if type(tbl) ~= "table" then return false end
		for _, v in pairs(tbl) do
			if type(v) == "table" then
				if tableHasNonEmpty(v) then return true end
			elseif v ~= nil and v ~= "" and v ~= false then
				return true
			end
		end
		return false
	end

	function steps.hasStep2Data(s2) return tableHasNonEmpty(s2) end
	function steps.hasStep3Data(s3) return tableHasNonEmpty(s3) end
	function steps.hasStep4Data(s4) return tableHasNonEmpty(s4) end


---
-- Render a single-file `cmake-bns.toml` pre-populated with all required and
-- optional fields extracted from an existing CMake/Makefile build structure.
---
	function steps.renderImportedConfig(state, sourceLabel)
		local s1 = state.step1
		local s2 = state.step2 or { exports = {}, deps = {}, subprojects = {} }
		local s3 = state.step3 or { compiler = {}, platforms = {}, targetOverrides = {} }
		local s4 = state.step4 or { debug = {}, hooks = {} }

		local modes = {}
		for _, m in ipairs(s1.workspace.modes or { "Debug", "Release" }) do
			table.insert(modes, m:lower())
		end

		local lines = {
			"# =============================================================================",
			"# CMAKE-BNS PROJECT CONFIGURATION (IMPORTED FROM " .. (sourceLabel or "EXISTING BUILD"):upper() .. ")",
			"#",
			"# Generate cmake-bns.lua : cmake-bns init --from=cmake-bns.toml",
			"# Or build directly      : cmake-bns gmake   (or ninja, vs2022, xcode4)",
			"# =============================================================================",
			"",
			"[workspace]",
			"# --- REQUIRED ---",
			"name = " .. toml.formatString(s1.workspace.name),
			"",
			"# --- OPTIONAL ---",
			"build_dir   = " .. toml.formatString(s1.workspace.buildDir or "build"),
			"modes       = " .. toml.formatStringArray(modes),
			"archs       = " .. toml.formatStringArray(s1.workspace.archs or { "x86_64" }),
			"subprojects = " .. toml.formatStringArray(s2.subprojects or {}),
			"",
			"# =============================================================================",
			"# TARGETS",
			"# =============================================================================",
		}

		for _, t in ipairs(s1.targets) do
			local exp = (s2.exports and s2.exports[t.name]) or {}
			local dep = (s2.deps and s2.deps[t.name]) or {}
			local ovr = (s3.targetOverrides and s3.targetOverrides[t.name]) or {}
			local dbg = (s4.debug and s4.debug[t.name]) or {}
			local hks = (s4.hooks and s4.hooks[t.name]) or {}

			local langKey = t.langKey
			if not langKey then
				langKey = (t.cppdialect or t.cdialect or t.language or "c17"):lower()
			end

			table.insert(lines, "")
			table.insert(lines, "[[targets]]")
			table.insert(lines, "# --- REQUIRED ---")
			table.insert(lines, "name    = " .. toml.formatString(t.name))
			table.insert(lines, "type    = " .. toml.formatString(t.rawType or "exe"))
			table.insert(lines, "lang    = " .. toml.formatString(langKey))
			table.insert(lines, "sources = " .. toml.formatStringArray(t.sources))
			table.insert(lines, "")
			table.insert(lines, "# --- OPTIONAL TARGET SETTINGS ---")
			table.insert(lines, "includes          = " .. toml.formatStringArray(t.includes))
			table.insert(lines, "public_includes   = " .. toml.formatStringArray(exp.publicIncludes))
			table.insert(lines, "public_defines    = " .. toml.formatStringArray(exp.publicDefines))
			table.insert(lines, "links             = " .. toml.formatStringArray(dep.links))
			table.insert(lines, "system_includes   = " .. toml.formatStringArray(dep.systemIncludes))
			table.insert(lines, "lib_dirs          = " .. toml.formatStringArray(dep.libDirs))
			table.insert(lines, "windows_links     = " .. toml.formatStringArray(dep.windowsLinks))
			table.insert(lines, "linux_links       = " .. toml.formatStringArray(dep.linuxLinks))
			table.insert(lines, "macos_links       = " .. toml.formatStringArray(dep.macosLinks))
			table.insert(lines, "defines           = " .. toml.formatStringArray(ovr.defines))
			table.insert(lines, "exclude_sources   = " .. toml.formatStringArray(ovr.excludeSources))
			table.insert(lines, "compiler_flags    = " .. toml.formatStringArray(ovr.compilerFlags))
			table.insert(lines, "linker_flags      = " .. toml.formatStringArray(ovr.linkerFlags))
			table.insert(lines, "pch_header        = " .. toml.formatString(ovr.pchHeader or ""))
			table.insert(lines, "pch_source        = " .. toml.formatString(ovr.pchSource or ""))
			table.insert(lines, "debug_working_dir = " .. toml.formatString(dbg.workingDir or ""))
			table.insert(lines, "debug_command     = " .. toml.formatString(dbg.command or ""))
			table.insert(lines, "debug_args        = " .. toml.formatStringArray(dbg.args))
			table.insert(lines, "debug_env         = " .. toml.formatStringArray(dbg.env))
			table.insert(lines, "pre_build         = " .. toml.formatStringArray(hks.preBuild))
			table.insert(lines, "pre_link          = " .. toml.formatStringArray(hks.preLink))
			table.insert(lines, "post_build        = " .. toml.formatStringArray(hks.postBuild))
		end

		local icomp = s3.compiler or {}
		local warnStr = icomp.warningsKey or (icomp.warnings and icomp.warnings:lower()) or ""
		local rttiStr = icomp.rtti and icomp.rtti:lower() or ""
		local excStr  = icomp.exceptions and icomp.exceptions:lower() or ""
		local srunStr = icomp.staticRuntime and icomp.staticRuntime:lower() or ""
		local sans    = {}
		for _, s in ipairs(icomp.debugSanitizers or {}) do
			table.insert(sans, s:lower() == "undefinedbehavior" and "ub" or s:lower())
		end

		table.insert(lines, "")
		table.insert(lines, "# =============================================================================")
		table.insert(lines, "# OPTIONAL WORKSPACE-WIDE COMPILER & PLATFORM OVERRIDES")
		table.insert(lines, "# =============================================================================")
		table.insert(lines, "")
		table.insert(lines, "[compiler]")
		table.insert(lines, "warnings           = " .. toml.formatString(warnStr))
		table.insert(lines, "warnings_as_errors = " .. tostring(icomp.warningsAsErrors == true))
		table.insert(lines, "rtti               = " .. toml.formatString(rttiStr))
		table.insert(lines, "exceptions         = " .. toml.formatString(excStr))
		table.insert(lines, "static_runtime     = " .. toml.formatString(srunStr))
		table.insert(lines, "lto_in_release     = " .. tostring(icomp.ltoInRelease == true))
		table.insert(lines, "debug_sanitizers   = " .. toml.formatStringArray(sans))

		for _, osKey in ipairs({ "windows", "linux", "macos" }) do
			local b = (s3.platforms and s3.platforms[osKey]) or {}
			table.insert(lines, "")
			table.insert(lines, "[platform." .. osKey .. "]")
			table.insert(lines, "defines         = " .. toml.formatStringArray(b.defines))
			table.insert(lines, "exclude_sources = " .. toml.formatStringArray(b.excludeSources))
			table.insert(lines, "compiler_flags  = " .. toml.formatStringArray(b.compilerFlags))
			table.insert(lines, "linker_flags    = " .. toml.formatStringArray(b.linkerFlags))
		end

		table.insert(lines, "")
		return table.concat(lines, "\n")
	end
