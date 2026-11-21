--
-- actions/init/_init.lua
-- Interactive `git commit`-style TOML configuration wizard that scans the
-- working directory, opens TOML skeletons in the user's text editor, emits a
-- valid premake5.lua, and optionally runs Premake's build-file backend.
--

	local p = premake
	p.init = p.init or {}
	local init = p.init


	newoption {
		trigger     = "editor",
		value       = "CMD",
		description = "Text editor command for `premake5 init` (defaults to $VISUAL / $EDITOR)"
	}

	newoption {
		trigger     = "backend",
		value       = "ACTION",
		description = "Immediately generate build files with ACTION after `premake5 init` (e.g. gmake, ninja, vs2022)"
	}

	newoption {
		trigger     = "force",
		description = "Overwrite existing premake5.lua without prompting during `premake5 init`"
	}

	newoption {
		trigger     = "init",
		description = "Launch interactive configuration wizard before running action if premake5.lua is missing"
	}

	newoption {
		trigger     = "blank",
		description = "Skip interactive setup and generate a blank premake.toml with all placeholder fields"
	}

	newoption {
		trigger     = "from",
		value       = "FILE",
		description = "Non-interactively generate premake5.lua from a TOML config file (e.g. premake.toml)"
	}

	newoption {
		trigger     = "import",
		description = "Scan existing CMake/Makefile structure and write a pre-populated premake.toml without prompts"
	}

	newoption {
		trigger     = "auto",
		description = "Scan existing CMake/Makefile (or directory) and generate premake5.lua non-interactively"
	}


---
-- Check whether stdin and stdout are attached to an interactive terminal.
---
	function init.isInteractiveTerminal()
		if os.getenv("PREMAKE_FORCE_INTERACTIVE") == "1" then
			return true
		end
		if os.ishost("windows") then
			return true
		end
		local ok = os.execute("test -t 0 -a -t 1 >/dev/null 2>&1")
		return (ok == true or ok == 0)
	end


---
-- Resolve the editor command to launch for `.toml` skeletons.
---
	function init.resolveEditor(override)
		local cmd = override
			or _OPTIONS["editor"]
			or os.getenv("PREMAKE_EDITOR")
			or os.getenv("VISUAL")
			or os.getenv("EDITOR")

		if cmd and cmd ~= "" then
			return cmd
		end

		if os.ishost("windows") then
			return "notepad"
		end

		local candidates = { "nano", "vim", "nvim", "vi" }
		for _, bin in ipairs(candidates) do
			if os.pathsearch(bin, os.getenv("PATH") or "") then
				return bin
			end
		end

		return "vi"
	end


	local function promptLine(question, reader)
		io.write(question)
		io.flush()
		if reader then
			return reader()
		end
		return io.read("*l")
	end


	local function promptYesNo(question, defaultYes, reader)
		local suffix = defaultYes and " [Y/n]: " or " [y/N]: "
		local answer = promptLine(question .. suffix, reader)
		if answer == nil then
			return false
		end
		answer = answer:match("^%s*(.-)%s*$"):lower()
		if answer == "" then
			return defaultYes and true or false
		end
		return (answer == "y" or answer == "yes")
	end


	local function prependErrorBanner(content, errors)
		-- Strip any previous error banner block before prepending the latest one
		content = content:gsub("^# !%+%-+%+\n(.-)# !%+%-+%+\n\n?", "")
		local header = {
			"# !+-------------------------------------------------------------------------+",
			"# | PLEASE FIX THE FOLLOWING ISSUE(S) AND SAVE AGAIN (OR EMPTY FILE TO ABORT):",
		}
		for _, err in ipairs(errors) do
			table.insert(header, "# |   - " .. err)
		end
		table.insert(header, "# !+-------------------------------------------------------------------------+")
		table.insert(header, "")
		return table.concat(header, "\n") .. content
	end


	local function launchEditor(editorCmd, filePath, runner)
		local quotedPath = '"' .. filePath:gsub('"', '\\"') .. '"'
		local fullCmd = editorCmd .. " " .. quotedPath
		if runner then
			return runner(fullCmd, filePath)
		end
		local ok = os.execute(fullCmd)
		return (ok == true or ok == 0)
	end


---
-- Open a single TOML skeleton step in the user's editor, parse, and validate.
-- If validation fails, offers to re-open the buffer with inline `#` error
-- comments so the user never loses their edits.
---
	function init.editAndValidateStep(stepLabel, filenameHint, initialContent, validatorFn, opts)
		opts = opts or {}
		local editorCmd = init.resolveEditor(opts.editor)
		local workDir = opts.workDir or os.getcwd()
		local tmpPath = path.join(workDir, filenameHint)
		local buffer = initialContent

		local function cleanup()
			if os.isfile(tmpPath) then
				os.remove(tmpPath)
			end
		end

		while true do
			local okWrite, writeErr = io.writefile(tmpPath, buffer)
			if not okWrite then
				cleanup()
				return nil, "Failed to write temporary config '" .. tmpPath .. "': " .. tostring(writeErr)
			end

			printf("Opening %s in '%s'...", stepLabel, editorCmd)
			local exitedCleanly = launchEditor(editorCmd, tmpPath, opts.editorRunner)
			if not exitedCleanly then
				cleanup()
				return nil, "Aborted (editor exited with non-zero status)."
			end

			local edited = io.readfile(tmpPath)
			if not edited or not p.toml.hasContent(edited) then
				cleanup()
				return nil, "Aborted (configuration file was left empty)."
			end

			buffer = edited
			local parsed, parseErr = p.toml.parse(edited)
			local validationErrors = nil

			if not parsed then
				validationErrors = { "TOML syntax error - " .. tostring(parseErr) }
			else
				local validated, errs = validatorFn(parsed)
				if validated then
					cleanup()
					return validated, nil
				end
				validationErrors = errs
			end

			term.pushColor(term.errorColor)
			printf("\nValidation failed in %s:", stepLabel)
			for _, e in ipairs(validationErrors) do
				printf("  - %s", e)
			end
			term.popColor()

			if opts.nonInteractiveRetry == false then
				cleanup()
				return nil, table.concat(validationErrors, "; ")
			end

			if not promptYesNo("Re-open in editor to fix?", true, opts.promptReader) then
				cleanup()
				return nil, "Aborted by user."
			end

			buffer = prependErrorBanner(buffer, validationErrors)
		end
	end


---
-- Execute a real Premake backend action (gmake, ninja, vs2022, xcode4, etc.)
-- directly against a newly generated premake5.lua script.
---
	function init.runBackend(actionName, scriptPath)
		local act = p.action.get(actionName)
		if not act or not p.action.isConfigurable(act) then
			return false, string.format("Unknown or non-build backend '%s'.", tostring(actionName))
		end

		p.api.reset()

		_MAIN_SCRIPT = path.getabsolute(scriptPath)
		_MAIN_SCRIPT_DIR = path.getdirectory(_MAIN_SCRIPT)

		p.action.set(actionName)
		local currentAct = p.action.current()
		if currentAct then
			p.action.initialize(currentAct.trigger)
		end

		local prevDir = os.getcwd()
		os.chdir(_MAIN_SCRIPT_DIR)
		dofile(_MAIN_SCRIPT)
		os.chdir(prevDir)

		p.main.preBake()
		p.main.bake()
		p.main.postBake()
		p.main.validate()
		p.main.preAction()
		p.main.callAction()
		p.main.postAction()

		return true
	end


---
-- Run the full interactive TOML wizard, write premake5.lua, and optionally
-- invoke the real build-file generation backend.
---
	function init.runWizard(opts)
		opts = opts or {}
		local workDir = path.getabsolute(opts.workDir or os.getcwd())
		local outFile = opts.outputPath
			or (_OPTIONS["file"] and path.getabsolute(_OPTIONS["file"]))
			or path.join(workDir, "premake5.lua")

		if os.isfile(outFile) and not (opts.force or _OPTIONS["force"]) then
			local rel = path.getrelative(workDir, outFile)
			if not promptYesNo(string.format("'%s' already exists. Overwrite it?", rel), false, opts.promptReader) then
				print("Aborted (existing file kept).")
				return false
			end
		end

		-- Step 1: Check for existing CMake / Makefile build structure first; fallback to directory file scan
		local imported = (not opts.ignoreBuildFiles) and p.init.buildscan.detect(workDir) or nil
		local scan = nil
		if imported then
			local st = imported.summaryStats or {}
			printf(
				"Detected existing %s: %d target(s), %d linked lib(s), %d define(s), %d compiler flag(s).",
				imported.sourceLabel, st.targets or 0, st.links or 0, st.defines or 0, st.compilerFlags or 0
			)
		else
			print("Scanning working directory for C/C++ sources...")
			scan = p.init.scanner.scanDirectory(workDir)
			if scan.found then
				printf("Detected %d source file(s) and %d header file(s); pre-populating Step 1.", scan.sourceCount, scan.headerCount)
			else
				print("No C/C++ files detected; preparing Step 1 with blank defaults.")
			end
		end

		local step1Toml = p.init.steps.renderStep1(scan, imported)
		local step1, err1 = init.editAndValidateStep(
			"Step 1 (Workspace & Targets)",
			".premake-init-step1.toml",
			step1Toml,
			p.init.steps.validateStep1,
			opts
		)
		if not step1 then
			print(err1)
			return false
		end

		-- Automatically accept optional Step 2/3/4 fields discovered from existing CMake/Makefile
		-- so skipping an optional editor step preserves all imported build settings!
		local step2, step3, step4 = p.init.steps.reconcileImportedState(step1, imported)

		-- Step 2 (Optional): Dependencies, Linking & Library Exports
		local step2Prompt = p.init.steps.hasStep2Data(step2)
			and "Dependencies were pre-populated from existing build files. Edit Step 2 in editor? (No = keep detected)"
			or "Configure dependencies, linked libraries, or public exports?"
		if promptYesNo(step2Prompt, false, opts.promptReader) then
			local step2Toml = p.init.steps.renderStep2(step1, step2)
			local edited2, err2 = init.editAndValidateStep(
				"Step 2 (Dependencies & Linking)",
				".premake-init-step2.toml",
				step2Toml,
				function(parsed) return p.init.steps.validateStep2(parsed, step1) end,
				opts
			)
			if not edited2 then
				print(err2)
				return false
			end
			step2 = edited2
		end

		-- Step 3 (Optional): Compiler Settings & OS Overrides
		local step3Prompt = p.init.steps.hasStep3Data(step3)
			and "Compiler flags/defines were pre-populated from existing build files. Edit Step 3 in editor? (No = keep detected)"
			or "Configure compiler flags, sanitizers, or OS-specific overrides?"
		if promptYesNo(step3Prompt, false, opts.promptReader) then
			local step3Toml = p.init.steps.renderStep3(step1, step3)
			local edited3, err3 = init.editAndValidateStep(
				"Step 3 (Compiler & Platform Rules)",
				".premake-init-step3.toml",
				step3Toml,
				function(parsed) return p.init.steps.validateStep3(parsed, step1) end,
				opts
			)
			if not edited3 then
				print(err3)
				return false
			end
			step3 = edited3
		end

		-- Step 4 (Optional): Pre/Post-Build Hooks & Debugger Launch Settings
		local step4Prompt = p.init.steps.hasStep4Data(step4)
			and "Build hooks/debugger settings were pre-populated. Edit Step 4 in editor? (No = keep detected)"
			or "Configure pre/post-build commands or IDE debugger settings?"
		if promptYesNo(step4Prompt, false, opts.promptReader) then
			local step4Toml = p.init.steps.renderStep4(step1, step4)
			local edited4, err4 = init.editAndValidateStep(
				"Step 4 (Build Hooks & Debugger)",
				".premake-init-step4.toml",
				step4Toml,
				function(parsed) return p.init.steps.validateStep4(parsed, step1) end,
				opts
			)
			if not edited4 then
				print(err4)
				return false
			end
			step4 = edited4
		end

		-- Emit valid premake5.lua
		local luaContent = p.init.emit.generateLua({
			step1 = step1,
			step2 = step2,
			step3 = step3,
			step4 = step4,
		})

		local okWrite, writeErr = io.writefile(outFile, luaContent)
		if not okWrite then
			p.error("Failed to write '%s': %s", outFile, tostring(writeErr))
			return false
		end

		term.pushColor(term.infoColor)
		printf("Generated %s.", path.getrelative(workDir, outFile))
		term.popColor()

		if opts.skipBackendPrompt then
			return true, outFile
		end

		local backend = opts.backend or _OPTIONS["backend"]
		if not backend or backend == "" then
			local ans = promptLine(
				"Generate build files now? Enter backend (gmake, ninja, vs2022, xcode4, compilecommands) or press Enter to skip: ",
				opts.promptReader
			)
			if ans then
				backend = ans:match("^%s*(.-)%s*$")
			end
		end

		if backend and backend ~= "" then
			local okBackend, backendErr = init.runBackend(backend, outFile)
			if not okBackend then
				p.error("%s", backendErr)
				return false
			end
		else
			print("Done. Run `premake5 gmake`, `premake5 ninja`, or `premake5 vs2022` anytime to generate build files.")
		end

		return true, outFile
	end


---
-- Write a single, non-interactive blank TOML configuration file (`premake.toml`)
-- containing all required and optional placeholder fields.
---
	function init.writeBlankConfig(opts)
		opts = opts or {}
		local workDir = path.getabsolute(opts.workDir or os.getcwd())
		local outToml = opts.outputPath
			or (_OPTIONS["file"] and path.getabsolute(_OPTIONS["file"]))
			or path.join(workDir, "premake.toml")

		if os.isfile(outToml) and not (opts.force or _OPTIONS["force"]) then
			local rel = path.getrelative(workDir, outToml)
			if init.isInteractiveTerminal() and not opts.nonInteractive then
				if not promptYesNo(string.format("'%s' already exists. Overwrite it?", rel), false, opts.promptReader) then
					print("Aborted (existing file kept).")
					return false
				end
			else
				print(string.format("Error: '%s' already exists (use --force to overwrite).", rel))
				return false
			end
		end

		local content = p.init.steps.renderBlankConfig()
		local okWrite, writeErr = io.writefile(outToml, content)
		if not okWrite then
			p.error("Failed to write '%s': %s", outToml, tostring(writeErr))
			return false
		end

		local relOut = path.getrelative(workDir, outToml)
		term.pushColor(term.infoColor)
		printf("Generated blank configuration template '%s'.", relOut)
		term.popColor()
		printf("Fill in the [REQUIRED] fields, then run `premake5 init --from=%s` or `premake5 gmake`.", relOut)
		return true, outToml
	end


---
-- Parse and validate a unified TOML config file (such as `premake.toml`) and
-- emit a valid `premake5.lua` without opening an interactive editor.
---
	function init.generateFromToml(tomlPath, opts)
		opts = opts or {}
		local absToml = path.getabsolute(tomlPath)
		if not os.isfile(absToml) then
			print(string.format("Error: TOML configuration file '%s' not found.", tomlPath))
			return false
		end

		local raw = io.readfile(absToml)
		local parsed, parseErr = p.toml.parse(raw or "")
		if not parsed then
			term.pushColor(term.errorColor)
			printf("TOML syntax error in '%s': %s", path.getname(absToml), tostring(parseErr))
			term.popColor()
			return false
		end

		local state, valErrors = p.init.steps.validateUnifiedToml(parsed)
		if not state then
			term.pushColor(term.errorColor)
			printf("Validation failed in '%s':", path.getname(absToml))
			for _, e in ipairs(valErrors) do
				printf("  - %s", e)
			end
			term.popColor()
			return false
		end

		local outDir = opts.workDir and path.getabsolute(opts.workDir) or path.getdirectory(absToml)
		local outLua = opts.outputPath or path.join(outDir, "premake5.lua")

		local luaContent = p.init.emit.generateLua(state)
		local okWrite, writeErr = io.writefile(outLua, luaContent)
		if not okWrite then
			p.error("Failed to write '%s': %s", outLua, tostring(writeErr))
			return false
		end

		term.pushColor(term.infoColor)
		printf("Generated %s from %s.", path.getrelative(os.getcwd(), outLua), path.getname(absToml))
		term.popColor()

		local backend = opts.backend or _OPTIONS["backend"]
		if backend and backend ~= "" and not opts.skipBackend then
			local okBackend, backendErr = init.runBackend(backend, outLua)
			if not okBackend then
				p.error("%s", backendErr)
				return false
			end
		end

		return true, outLua
	end


---
-- Scan existing CMake / Makefile (or fallback directory scan) and either write
-- a pre-populated `premake.toml` (`--import`) or emit `premake5.lua` directly (`--auto`).
---
	function init.importExistingBuild(opts)
		opts = opts or {}
		local workDir = path.getabsolute(opts.workDir or os.getcwd())
		local imported = p.init.buildscan.detect(workDir)
		local state = nil
		local label = "directory scan"

		if imported then
			state = imported
			label = imported.sourceLabel
			local st = imported.summaryStats or {}
			printf(
				"Imported %s: %d target(s), %d linked lib(s), %d define(s), %d compiler flag(s).",
				label, st.targets or 0, st.links or 0, st.defines or 0, st.compilerFlags or 0
			)
		else
			local scan = p.init.scanner.scanDirectory(workDir)
			if not scan.found then
				print("Error: no existing CMake/Makefile or C/C++ source files found to auto-import.")
				return false
			end
			local step1Parsed = p.toml.parse(p.init.steps.renderStep1(scan))
			local s1, errs = p.init.steps.validateStep1(step1Parsed)
			if not s1 then
				print("Error: " .. table.concat(errs or {}, "; "))
				return false
			end
			state = { step1 = s1, step2 = {}, step3 = {}, step4 = {} }
		end

		if opts.emitToml then
			local outToml = opts.outputPath
				or (_OPTIONS["file"] and path.getabsolute(_OPTIONS["file"]))
				or path.join(workDir, "premake.toml")

			if os.isfile(outToml) and not (opts.force or _OPTIONS["force"]) then
				print(string.format("Error: '%s' already exists (use --force to overwrite).", path.getrelative(workDir, outToml)))
				return false
			end

			local tomlText = p.init.steps.renderImportedConfig(state, label)
			local okWrite, writeErr = io.writefile(outToml, tomlText)
			if not okWrite then
				p.error("Failed to write '%s': %s", outToml, tostring(writeErr))
				return false
			end

			term.pushColor(term.infoColor)
			printf("Generated pre-populated '%s' from %s.", path.getrelative(workDir, outToml), label)
			term.popColor()
			return true, outToml
		else
			local outLua = opts.outputPath
				or (_OPTIONS["file"] and path.getabsolute(_OPTIONS["file"]))
				or path.join(workDir, "premake5.lua")

			if os.isfile(outLua) and not (opts.force or _OPTIONS["force"]) then
				print(string.format("Error: '%s' already exists (use --force to overwrite).", path.getrelative(workDir, outLua)))
				return false
			end

			local luaContent = p.init.emit.generateLua(state)
			local okWrite, writeErr = io.writefile(outLua, luaContent)
			if not okWrite then
				p.error("Failed to write '%s': %s", outLua, tostring(writeErr))
				return false
			end

			term.pushColor(term.infoColor)
			printf("Generated '%s' from %s.", path.getrelative(workDir, outLua), label)
			term.popColor()

			local backend = opts.backend or _OPTIONS["backend"]
			if backend and backend ~= "" and not opts.skipBackend then
				local okBackend, backendErr = init.runBackend(backend, outLua)
				if not okBackend then
					p.error("%s", backendErr)
					return false
				end
			end

			return true, outLua
		end
	end


	newaction {
		trigger     = "init",
		shortname   = "Interactive Configuration Wizard",
		description = "Create premake5.lua interactively via TOML editor steps (or non-interactively with --blank / --import / --auto / --from)",
		aliases     = { "wizard" },

		execute = function()
			local ok
			if _OPTIONS["blank"] then
				ok = init.writeBlankConfig()
			elseif _OPTIONS["import"] then
				ok = init.importExistingBuild({ emitToml = true })
			elseif _OPTIONS["auto"] then
				ok = init.importExistingBuild({ emitToml = false })
			elseif _OPTIONS["from"] then
				local src = (_OPTIONS["from"] ~= "") and _OPTIONS["from"] or "premake.toml"
				ok = init.generateFromToml(src)
			else
				ok = init.runWizard()
			end

			if not ok then
				os.exit(1)
			end
		end
	}
