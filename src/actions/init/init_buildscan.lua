--
-- actions/init/init_buildscan.lua
-- Parses existing project build files (Makefiles, Automake/Autoconf Makefiles,
-- and CMakeLists.txt) to automatically pre-populate both mandatory and optional
-- Premake configuration fields (targets, exact sources, includes, defines,
-- linked libraries, language dialect, warnings, sanitizers, and compiler/linker flags).
--

	local p = premake
	p.init = p.init or {}
	p.init.buildscan = {}
	local buildscan = p.init.buildscan


	local SOURCE_CANDIDATE_EXTS = { ".c", ".cpp", ".cc", ".cxx", ".C", ".c++", ".cp" }
	local KNOWN_SOURCE_EXTS = {
		[".c"] = true, [".cpp"] = true, [".cc"] = true, [".cxx"] = true,
		[".C"] = true, [".c++"] = true, [".cp"] = true, [".ixx"] = true, [".cppm"] = true,
		[".h"] = true, [".hpp"] = true, [".hh"] = true, [".hxx"] = true,
		[".H"] = true, [".h++"] = true, [".inl"] = true, [".ipp"] = true, [".inc"] = true,
	}
	local CPP_EXTS = {
		[".cpp"] = true, [".cc"] = true, [".cxx"] = true, [".C"] = true,
		[".c++"] = true, [".cp"] = true, [".ixx"] = true, [".cppm"] = true,
		[".hpp"] = true, [".hh"] = true, [".hxx"] = true, [".H"] = true, [".h++"] = true,
	}


	local function appendUnique(list, item)
		if item and item ~= "" and not table.contains(list, item) then
			table.insert(list, item)
		end
	end


	local function sliceArray(arr, first, last)
		local out = {}
		for idx = first, (last or #arr) do
			if arr[idx] ~= nil then
				table.insert(out, arr[idx])
			end
		end
		return out
	end


	local function getExtExact(fname)
		local dot = fname:match("^.*()%.")
		if not dot or dot == 1 then
			return nil
		end
		return fname:sub(dot)
	end


	local function normalizeRelPath(rootDir, baseDir, rawPath)
		if not rawPath or rawPath == "" then
			return nil
		end
		rawPath = rawPath:gsub("\\", "/")
		rawPath = rawPath:gsub("^%./", "")
		if rawPath == "" then
			rawPath = "."
		end

		-- Preserve globs carefully relative to rootDir
		if rawPath:find("*", 1, true) then
			local full = path.isabsolute(rawPath) and rawPath or path.join(baseDir, rawPath)
			return path.getrelative(rootDir, full)
		end

		local abs = path.isabsolute(rawPath) and path.normalize(rawPath) or path.getabsolute(path.join(baseDir, rawPath))
		local rel = path.getrelative(rootDir, abs)
		if rel == "" then
			rel = "."
		end
		return rel
	end


---
-- POSIX-style shell tokenizer that handles single quotes, double quotes, and
-- backslash escapes so flags like `-DFOO='"bar baz"'` and `-DFOO=\"bar\ baz\"`
-- both cleanly become `-DFOO="bar baz"`.
---
	function buildscan.tokenizeShellWords(str)
		local tokens = {}
		if not str or str == "" then
			return tokens
		end

		local i = 1
		local n = #str
		local cur = {}
		local inToken = false
		local quoteMode = nil -- nil | "'" | '"'

		while i <= n do
			local ch = str:sub(i, i)

			if quoteMode == "'" then
				if ch == "'" then
					quoteMode = nil
				else
					table.insert(cur, ch)
				end
				i = i + 1
			elseif quoteMode == '"' then
				if ch == '"' then
					quoteMode = nil
					i = i + 1
				elseif ch == "\\" and i < n then
					local nxt = str:sub(i + 1, i + 1)
					if nxt == '"' or nxt == "\\" or nxt == "$" or nxt == "`" then
						table.insert(cur, nxt)
						i = i + 2
					else
						table.insert(cur, ch)
						i = i + 1
					end
				else
					table.insert(cur, ch)
					i = i + 1
				end
			else
				if ch == " " or ch == "\t" or ch == "\r" or ch == "\n" then
					if inToken then
						table.insert(tokens, table.concat(cur))
						cur = {}
						inToken = false
					end
					i = i + 1
				elseif ch == "'" or ch == '"' then
					quoteMode = ch
					inToken = true
					i = i + 1
				elseif ch == "\\" and i < n then
					inToken = true
					table.insert(cur, str:sub(i + 1, i + 1))
					i = i + 2
				else
					inToken = true
					table.insert(cur, ch)
					i = i + 1
				end
			end
		end

		if inToken then
			table.insert(tokens, table.concat(cur))
		end

		return tokens
	end


	local STD_FLAG_MAP = {
		["c89"]            = "c89",
		["iso9899:1990"]   = "c89",
		["c90"]            = "c90",
		["c99"]            = "c99",
		["iso9899:1999"]   = "c99",
		["c11"]            = "c11",
		["iso9899:2011"]   = "c11",
		["c17"]            = "c17",
		["c18"]            = "c17",
		["c2x"]            = "c23",
		["c23"]            = "c23",
		["gnu89"]          = "gnu89",
		["gnu90"]          = "gnu90",
		["gnu99"]          = "gnu99",
		["gnu11"]          = "gnu11",
		["gnu17"]          = "gnu17",
		["gnu18"]          = "gnu17",
		["gnu2x"]          = "gnu23",
		["gnu23"]          = "gnu23",
		["c++98"]          = "c++98",
		["c++03"]          = "c++98",
		["c++11"]          = "c++11",
		["c++0x"]          = "c++11",
		["c++14"]          = "c++14",
		["c++1y"]          = "c++14",
		["c++17"]          = "c++17",
		["c++1z"]          = "c++17",
		["c++20"]          = "c++20",
		["c++2a"]          = "c++20",
		["c++23"]          = "c++23",
		["c++2b"]          = "c++23",
		["c++26"]          = "c++26",
		["c++2c"]          = "c++26",
		["c++latest"]      = "c++latest",
		["gnu++11"]        = "gnu++11",
		["gnu++14"]        = "gnu++14",
		["gnu++17"]        = "gnu++17",
		["gnu++20"]        = "gnu++20",
		["gnu++23"]        = "gnu++23",
	}


	local function createFlagBucket()
		return {
			defines          = {},
			includes         = {},
			systemIncludes   = {},
			libDirs          = {},
			links            = {},
			macosLinks       = {},
			linuxLinks       = {},
			windowsLinks     = {},
			compilerFlags    = {},
			linkerFlags      = {},
			sanitizers       = {},
			lang             = nil,
			warnings         = nil,
			warningsAsErrors = false,
			rtti             = nil,
			exceptions       = nil,
			staticRuntime    = nil,
			ltoInRelease     = false,
		}
	end


---
-- Classify compiler, preprocessor, and linker CLI flags into structured Premake
-- front-end fields.
---
	local function parseFlagsIntoBucket(tokens, rootDir, baseDir, bucket, mode)
		local i = 1
		while i <= #tokens do
			local tok = tokens[i]

			-- Skip unexpanded autoconf placeholders like @XOPEN_DEFINES@
			if tok:match("^@.-@$") or tok == "" then
				-- ignore
			elseif tok == "-D" and i < #tokens then
				i = i + 1
				local d = tokens[i]
				if d ~= "DEBUG" and d ~= "_DEBUG" and d ~= "NDEBUG" then
					appendUnique(bucket.defines, d)
				end
			elseif tok:sub(1, 2) == "-D" and #tok > 2 then
				local d = tok:sub(3)
				if d ~= "DEBUG" and d ~= "_DEBUG" and d ~= "NDEBUG" then
					appendUnique(bucket.defines, d)
				end
			elseif (tok == "-I" or tok == "-iquote") and i < #tokens then
				i = i + 1
				local inc = normalizeRelPath(rootDir, baseDir, tokens[i])
				if inc and not inc:find("^/usr/include") then
					appendUnique(bucket.includes, inc)
				end
			elseif tok:sub(1, 2) == "-I" and #tok > 2 then
				local inc = normalizeRelPath(rootDir, baseDir, tok:sub(3))
				if inc and not inc:find("^/usr/include") then
					appendUnique(bucket.includes, inc)
				end
			elseif tok:sub(1, 7) == "-iquote" and #tok > 7 then
				local inc = normalizeRelPath(rootDir, baseDir, tok:sub(8))
				if inc then
					appendUnique(bucket.includes, inc)
				end
			elseif tok == "-isystem" and i < #tokens then
				i = i + 1
				local inc = normalizeRelPath(rootDir, baseDir, tokens[i])
				if inc then
					appendUnique(bucket.systemIncludes, inc)
				end
			elseif tok:sub(1, 8) == "-isystem" and #tok > 8 then
				local inc = normalizeRelPath(rootDir, baseDir, tok:sub(9))
				if inc then
					appendUnique(bucket.systemIncludes, inc)
				end
			elseif tok == "-L" and i < #tokens then
				i = i + 1
				local dir = normalizeRelPath(rootDir, baseDir, tokens[i])
				if dir then
					appendUnique(bucket.libDirs, dir)
				end
			elseif tok:sub(1, 2) == "-L" and #tok > 2 then
				local dir = normalizeRelPath(rootDir, baseDir, tok:sub(3))
				if dir then
					appendUnique(bucket.libDirs, dir)
				end
			elseif tok == "-l" and i < #tokens then
				i = i + 1
				appendUnique(bucket.links, tokens[i])
			elseif tok:sub(1, 2) == "-l" and #tok > 2 then
				appendUnique(bucket.links, tok:sub(3))
			elseif tok == "-framework" and i < #tokens then
				i = i + 1
				local fw = tokens[i]
				if not fw:endswith(".framework") then
					fw = fw .. ".framework"
				end
				appendUnique(bucket.macosLinks, fw)
			elseif tok == "-pthread" then
				appendUnique(bucket.linuxLinks, "pthread")
			elseif tok:sub(1, 5) == "-std=" or tok:sub(1, 5) == "/std:" then
				local stdVal = tok:sub(6):lower()
				if STD_FLAG_MAP[stdVal] then
					bucket.lang = STD_FLAG_MAP[stdVal]
				end
			elseif tok == "-Werror" or tok == "/WX" then
				bucket.warningsAsErrors = true
			elseif tok == "-Wextra" or tok == "-W" or tok == "/W4" then
				bucket.warnings = "extra"
			elseif tok == "-Wall" or tok == "/W3" then
				if bucket.warnings ~= "extra" then
					bucket.warnings = "high"
				end
			elseif tok == "-w" or tok == "/W0" then
				bucket.warnings = "off"
			elseif tok == "-fno-rtti" or tok == "/GR-" then
				bucket.rtti = "Off"
			elseif tok == "-fno-exceptions" then
				bucket.exceptions = "Off"
			elseif tok == "-flto" or tok:match("^%-flto=") then
				bucket.ltoInRelease = true
			elseif tok:match("^%-fsanitize=") then
				local list = tok:sub(12)
				for item in list:gmatch("[^,]+") do
					local mapped = p.init.steps.SANITIZERS[item:lower()]
					if mapped then
						appendUnique(bucket.sanitizers, mapped)
					end
				end
			elseif tok == "-MM" or tok == "-MMD" or tok == "-MD" or tok == "-MP" or tok == "-c" or tok == "-pipe" then
				-- Dependency-tracking / compile-only flags handled natively by Premake backends
			elseif (tok == "-MF" or tok == "-MT" or tok == "-MQ" or tok == "-o") and i < #tokens then
				i = i + 1
			elseif tok:match("^%-O[0123sfastg]?$") or tok:match("^%-g[%d]?$") or tok == "-ggdb" then
				-- Optimization and debug symbol flags are managed by Premake Debug/Release modes
			elseif mode == "link" then
				if tok:sub(1, 1) == "-" then
					appendUnique(bucket.linkerFlags, tok)
				elseif tok:match("%.[a]$") or tok:match("%.[sS][oO]$") or tok:match("%.lib$") then
					local relLib = normalizeRelPath(rootDir, baseDir, tok)
					if relLib and os.isfile(path.join(rootDir, relLib)) then
						appendUnique(bucket.links, relLib)
					end
				end
			else
				if tok:sub(1, 4) == "-Wl," then
					appendUnique(bucket.linkerFlags, tok)
				elseif tok:sub(1, 1) == "-" then
					appendUnique(bucket.compilerFlags, tok)
				end
			end

			i = i + 1
		end
	end


-- =============================================================================
-- 1. MAKEFILE & AUTOMAKE / AUTOCONF PARSER
-- =============================================================================

	local function stripMakeComment(line)
		local quoteMode = nil
		local i = 1
		local n = #line
		while i <= n do
			local ch = line:sub(i, i)
			if quoteMode then
				if ch == "\\" and quoteMode == '"' and i < n then
					i = i + 2
				elseif ch == quoteMode then
					quoteMode = nil
					i = i + 1
				else
					i = i + 1
				end
			else
				if ch == "'" or ch == '"' then
					quoteMode = ch
					i = i + 1
				elseif ch == "\\" and i < n then
					i = i + 2
				elseif ch == "#" then
					return line:sub(1, i - 1)
				else
					i = i + 1
				end
			end
		end
		return line
	end


	local function readLogicalMakeLines(content)
		content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
		local logical = {}
		local buf = nil

		for rawLine in (content .. "\n"):gmatch("(.-)\n") do
			-- Full-line comment fast path
			if not buf and rawLine:match("^%s*#") then
				-- skip comment line completely (do not honor trailing '\' on comments)
			else
				local stripped = stripMakeComment(rawLine)
				local cont = stripped:match("^(.-)\\$")
				if cont then
					buf = (buf and (buf .. " ") or "") .. cont:match("^%s*(.-)%s*$")
				else
					if buf then
						table.insert(logical, buf .. " " .. stripped:match("^%s*(.-)%s*$"))
						buf = nil
					else
						table.insert(logical, stripped)
					end
				end
			end
		end

		if buf then
			table.insert(logical, buf)
		end

		return logical
	end


	local function expandMakeExpr(expr, vars, rootDir, baseDir, depth)
		depth = depth or 0
		if depth > 12 or not expr or expr == "" then
			return expr or ""
		end

		local function resolveOne(inner)
			inner = expandMakeExpr(inner, vars, rootDir, baseDir, depth + 1)

			-- $(wildcard pattern1 pattern2)
			local wcArgs = inner:match("^wildcard%s+(.+)$")
			if wcArgs then
				return wcArgs
			end

			-- $(patsubst from,to,text)
			local pFrom, pTo, pText = inner:match("^patsubst%s+([^,]+),([^,]*),(.+)$")
			if pFrom then
				local fromExt = pFrom:match("^%%(.*)$")
				local toExt   = pTo:match("^%%(.*)$")
				if fromExt and toExt then
					local out = {}
					for w in pText:gmatch("%S+") do
						if w:endswith(fromExt) then
							table.insert(out, w:sub(1, #w - #fromExt) .. toExt)
						else
							table.insert(out, w)
						end
					end
					return table.concat(out, " ")
				end
			end

			-- $(VAR:.o=.c) or $(VAR:%.o=%.c)
			local varName, lhs, rhs = inner:match("^([A-Za-z0-9_%.%-]+):%%?([^=]*)=%%?(.*)$")
			if varName then
				local baseVal = expandMakeExpr(vars[varName] or "", vars, rootDir, baseDir, depth + 1)
				local out = {}
				for w in baseVal:gmatch("%S+") do
					if lhs == "" or w:endswith(lhs) then
						table.insert(out, w:sub(1, #w - #lhs) .. rhs)
					else
						table.insert(out, w)
					end
				end
				return table.concat(out, " ")
			end

			if vars[inner] ~= nil then
				return expandMakeExpr(vars[inner], vars, rootDir, baseDir, depth + 1)
			end
			return ""
		end

		-- Expand single-letter $U (Automake ANSI2KNR empty macro) while leaving $$ intact
		local result = expr:gsub("%$%$", "\001DOLLAR\001")

		local changed = true
		local guard = 0
		while changed and guard < 12 do
			changed = false
			guard = guard + 1
			local nextStr, n1 = result:gsub("%$%(([^%(%)]+)%)", function(inner)
				changed = true
				return resolveOne(inner)
			end)
			local nextStr2, n2 = nextStr:gsub("%${([^{}]+)}", function(inner)
				changed = true
				return resolveOne(inner)
			end)
			result = nextStr2
			if n1 == 0 and n2 == 0 then
				break
			end
		end

		-- Strip unexpanded single-char Automake $U macro, then restore literal '$'
		result = result:gsub("%$U", "")
		result = result:gsub("\001DOLLAR\001", "$")
		return result
	end


	local function resolveSourceItemFromMakeToken(tok, rootDir, baseDir)
		if not tok or tok == "" or tok:sub(1, 1) == "-" then
			return nil
		end
		tok = tok:gsub("^%./", "")
		if tok:find("@", 1, true) then
			-- Autoconf @PLATFORM@ placeholder when Makefile.am hasn't been configured
			local hostOs = os.target()
			if hostOs == "macosx" then hostOs = "darwin" end
			tok = tok:gsub("@PLATFORM@", hostOs)
		end

		-- Wildcard glob
		if tok:find("*", 1, true) then
			return normalizeRelPath(rootDir, baseDir, tok)
		end

		local ext = getExtExact(tok)
		if ext and KNOWN_SOURCE_EXTS[ext] then
			local rel = normalizeRelPath(rootDir, baseDir, tok)
			if rel and os.isfile(path.join(rootDir, rel)) then
				return rel
			end
			return nil
		end

		-- Yacc / Lex (.y / .l) -> check if generated .c / .cpp already exists on disk
		if ext == ".y" or ext == ".l" then
			local stem = tok:sub(1, #tok - #ext)
			for _, candExt in ipairs(SOURCE_CANDIDATE_EXTS) do
				local rel = normalizeRelPath(rootDir, baseDir, stem .. candExt)
				if rel and os.isfile(path.join(rootDir, rel)) then
					return rel
				end
			end
			return nil
		end

		-- Object file (.o, .obj, .lo) -> map back to existing .c / .cpp / .cc / .cxx on disk
		if ext == ".o" or ext == ".obj" or ext == ".lo" then
			local stem = tok:sub(1, #tok - #ext)
			for _, candExt in ipairs(SOURCE_CANDIDATE_EXTS) do
				local candRel = normalizeRelPath(rootDir, baseDir, stem .. candExt)
				if candRel and os.isfile(path.join(rootDir, candRel)) then
					return candRel
				end
			end
			-- Also check basename in rootDir or src/ if object had obj/ prefix
			local baseStem = path.getbasename(stem)
			for _, dirPrefix in ipairs({ "", "src/", "source/", "lib/" }) do
				for _, candExt in ipairs(SOURCE_CANDIDATE_EXTS) do
					local candRel = dirPrefix .. baseStem .. candExt
					if os.isfile(path.join(rootDir, candRel)) then
						return candRel
					end
				end
			end
		end

		return nil
	end


	function buildscan.parseMakefile(makefilePath, rootDir)
		rootDir = path.getabsolute(rootDir or path.getdirectory(makefilePath))
		local baseDir = path.getdirectory(path.getabsolute(makefilePath))
		local content = io.readfile(makefilePath)
		if not content then
			return nil
		end

		-- Never treat a Premake-generated Makefile as an upstream input Makefile
		if content:sub(1, 256):find("autogenerated by Premake", 1, true) then
			return nil
		end

		local vars = {
			OBJEXT       = "o",
			EXEEXT       = "",
			srcdir       = ".",
			top_srcdir   = ".",
			builddir     = ".",
			top_builddir = ".",
			sysconfdir   = "/etc",
			prefix       = "/usr/local",
			exec_prefix  = "/usr/local",
			bindir       = "/usr/local/bin",
			libdir       = "/usr/local/lib",
			includedir   = "/usr/local/include",
			datarootdir  = "/usr/local/share",
			datadir      = "/usr/local/share",
		}

		local rules = {}
		local currentRule = nil
		local lines = readLogicalMakeLines(content)

		for _, line in ipairs(lines) do
			if line:sub(1, 1) == "\t" then
				if currentRule then
					table.insert(currentRule.recipes, line:sub(2))
				end
			else
				local trimmed = line:match("^%s*(.-)%s*$")
				if trimmed == "" or trimmed:match("^if%s+") or trimmed:match("^ifdef%s+")
					or trimmed:match("^ifndef%s+") or trimmed:match("^ifeq%s*")
					or trimmed:match("^ifneq%s*") or trimmed == "else" or trimmed == "endif"
					or trimmed:match("^%-?include%s+") then
					currentRule = nil
				else
					-- Variable assignment (=, :=, ?=, +=)
					local lhs, op, rhs = trimmed:match("^([A-Za-z0-9_%.%-]+)%s*([:%?%+]=)%s*(.*)$")
					if not lhs then
						lhs, op, rhs = trimmed:match("^([A-Za-z0-9_%.%-]+)%s*(=)%s*(.*)$")
					end

					if lhs and not lhs:find(":", 1, true) then
						currentRule = nil
						if op == ":=" then
							vars[lhs] = expandMakeExpr(rhs, vars, rootDir, baseDir, 0)
						elseif op == "+=" then
							if vars[lhs] and vars[lhs] ~= "" then
								vars[lhs] = vars[lhs] .. " " .. rhs
							else
								vars[lhs] = rhs
							end
						elseif op == "?=" then
							if vars[lhs] == nil then
								vars[lhs] = rhs
							end
						else
							vars[lhs] = rhs
						end
					else
						-- Target rule: `target: prereqs`
						local rTarget, rDeps = trimmed:match("^([^:=]+):%s*(.*)$")
						if rTarget and not rTarget:match("^%.") then
							currentRule = {
								target  = rTarget:match("^%s*(.-)%s*$"),
								deps    = rDeps or "",
								recipes = {},
							}
							table.insert(rules, currentRule)
						else
							currentRule = nil
						end
					end
				end
			end
		end

		local function getExpanded(varName)
			if not vars[varName] then
				return ""
			end
			return expandMakeExpr(vars[varName], vars, rootDir, baseDir, 0)
		end

		-- Collect workspace-wide compiler/preprocessor/linker flags
		local globalFlags = createFlagBucket()
		local cppFlagVars = { "DEFS", "DEFAULT_INCLUDES", "INCLUDES", "AM_CPPFLAGS", "CPPFLAGS" }
		local cFlagVars   = { "AM_CFLAGS", "CFLAGS", "AM_CXXFLAGS", "CXXFLAGS" }
		local ldFlagVars  = { "AM_LDFLAGS", "LDFLAGS" }
		local libVars     = { "LIBS", "LDLIBS" }

		for _, v in ipairs(cppFlagVars) do
			parseFlagsIntoBucket(buildscan.tokenizeShellWords(getExpanded(v)), rootDir, baseDir, globalFlags, "compile")
		end
		for _, v in ipairs(cFlagVars) do
			parseFlagsIntoBucket(buildscan.tokenizeShellWords(getExpanded(v)), rootDir, baseDir, globalFlags, "compile")
		end
		for _, v in ipairs(ldFlagVars) do
			parseFlagsIntoBucket(buildscan.tokenizeShellWords(getExpanded(v)), rootDir, baseDir, globalFlags, "link")
		end
		for _, v in ipairs(libVars) do
			parseFlagsIntoBucket(buildscan.tokenizeShellWords(getExpanded(v)), rootDir, baseDir, globalFlags, "link")
		end

		local targets = {}

		-- 1) Check Automake program / library variables first
		local automakeGroups = {
			{ vars = { "bin_PROGRAMS", "sbin_PROGRAMS", "noinst_PROGRAMS" }, type = "exe" },
			{ vars = { "lib_LIBRARIES", "noinst_LIBRARIES" },                type = "static_lib" },
			{ vars = { "lib_LTLIBRARIES", "noinst_LTLIBRARIES" },            type = "shared_lib" },
		}

		for _, grp in ipairs(automakeGroups) do
			for _, vname in ipairs(grp.vars) do
				local rawList = getExpanded(vname)
				for _, prog in ipairs(buildscan.tokenizeShellWords(rawList)) do
					local cleanName = path.getname(prog)
					cleanName = cleanName:gsub("%.exe$", ""):gsub("%.la$", ""):gsub("%.a$", "")
					if grp.type ~= "exe" then
						cleanName = cleanName:gsub("^lib", "")
					end
					local canon = prog:gsub("%.exe$", ""):gsub("[^A-Za-z0-9_]", "_")

					local sources = {}
					-- Prefer <canon>_OBJECTS when present (reflects active ./configure conditionals!)
					local objTokens = buildscan.tokenizeShellWords(getExpanded(canon .. "_OBJECTS"))
					if #objTokens > 0 then
						for _, otok in ipairs(objTokens) do
							local src = resolveSourceItemFromMakeToken(otok, rootDir, baseDir)
							appendUnique(sources, src)
						end
					end

					-- Also check <canon>_SOURCES / dist_<canon>_SOURCES / nodist_<canon>_SOURCES
					-- for headers (or all sources if _OBJECTS wasn't defined, e.g. Makefile.am)
					local srcVarNames = {
						canon .. "_SOURCES",
						"dist_" .. canon .. "_SOURCES",
						"nodist_" .. canon .. "_SOURCES",
					}
					for _, sv in ipairs(srcVarNames) do
						for _, stok in ipairs(buildscan.tokenizeShellWords(getExpanded(sv))) do
							local resolved = resolveSourceItemFromMakeToken(stok, rootDir, baseDir)
							if resolved then
								local ext = getExtExact(resolved)
								-- If _OBJECTS already gave us the exact active .c/.cpp list, only pull headers from _SOURCES
								if #objTokens == 0 or (ext and (ext == ".h" or ext == ".hpp" or ext == ".hh" or ext == ".hxx")) then
									appendUnique(sources, resolved)
								end
							end
						end
					end

					-- Check <canon>_LDADD / LDADD for compatibility LIBOBJS (.o files) and extra -l libs
					local targetBucket = createFlagBucket()
					local ldaddRaw = getExpanded(canon .. "_LDADD")
					if ldaddRaw == "" then
						ldaddRaw = getExpanded("LDADD")
					end
					for _, ltok in ipairs(buildscan.tokenizeShellWords(ldaddRaw)) do
						local ext = getExtExact(ltok)
						if ext == ".o" or ext == ".obj" or ext == ".lo" then
							local compatSrc = resolveSourceItemFromMakeToken(ltok, rootDir, baseDir)
							appendUnique(sources, compatSrc)
						else
							parseFlagsIntoBucket({ ltok }, rootDir, baseDir, targetBucket, "link")
						end
					end

					-- Per-target Automake CFLAGS / CPPFLAGS / LDFLAGS
					for _, tv in ipairs({ canon .. "_CPPFLAGS", canon .. "_CFLAGS", canon .. "_CXXFLAGS" }) do
						parseFlagsIntoBucket(buildscan.tokenizeShellWords(getExpanded(tv)), rootDir, baseDir, targetBucket, "compile")
					end
					parseFlagsIntoBucket(buildscan.tokenizeShellWords(getExpanded(canon .. "_LDFLAGS")), rootDir, baseDir, targetBucket, "link")

					if #sources > 0 then
						table.insert(targets, {
							name   = cleanName,
							type   = grp.type,
							sources = sources,
							bucket = targetBucket,
						})
					end
				end
			end
		end

		-- 2) Fallback: Handwritten Makefile rules & common SRCS/OBJS/TARGET variables
		if #targets == 0 then
			local phonySet = {
				all = true, clean = true, distclean = true, mostlyclean = true,
				install = true, uninstall = true, test = true, check = true,
				run = true, rebuild = true, depend = true, tags = true,
			}
			for _, ptok in ipairs(buildscan.tokenizeShellWords(getExpanded(".PHONY"))) do
				phonySet[ptok] = true
			end

			for _, r in ipairs(rules) do
				local tname = expandMakeExpr(r.target, vars, rootDir, baseDir, 0):match("^%s*(.-)%s*$")
				if tname ~= "" and not tname:find("[%%%$%s]") and not phonySet[tname] and not tname:match("%.[oh]$") then
					local depsExpanded = expandMakeExpr(r.deps, vars, rootDir, baseDir, 0)
					local sources = {}
					for _, dtok in ipairs(buildscan.tokenizeShellWords(depsExpanded)) do
						local resolved = resolveSourceItemFromMakeToken(dtok, rootDir, baseDir)
						appendUnique(sources, resolved)
					end

					if #sources > 0 then
						local recipeText = expandMakeExpr(table.concat(r.recipes, " "), vars, rootDir, baseDir, 0)
						local ttype = "exe"
						if tname:endswith(".a") or recipeText:match("%f[%w]ar%s+") then
							ttype = "static_lib"
							tname = path.getbasename(tname):gsub("^lib", "")
						elseif tname:endswith(".so") or tname:endswith(".dylib") or tname:endswith(".dll") or recipeText:find("-shared", 1, true) then
							ttype = "shared_lib"
							tname = path.getbasename(tname):gsub("^lib", "")
						else
							tname = path.getname(tname):gsub("%.exe$", "")
						end

						local rBucket = createFlagBucket()
						parseFlagsIntoBucket(buildscan.tokenizeShellWords(recipeText), rootDir, baseDir, rBucket, "link")

						table.insert(targets, {
							name    = tname,
							type    = ttype,
							sources = sources,
							bucket  = rBucket,
						})
					end
				end
			end

			-- Variable-only Makefile fallback (SRCS / SOURCES / OBJS + TARGET / BIN)
			if #targets == 0 then
				local sources = {}
				for _, sv in ipairs({ "SRCS", "SOURCES", "CFILES", "CPPFILES", "CXXFILES", "OBJS", "OBJECTS", "OBJ" }) do
					for _, stok in ipairs(buildscan.tokenizeShellWords(getExpanded(sv))) do
						local resolved = resolveSourceItemFromMakeToken(stok, rootDir, baseDir)
						appendUnique(sources, resolved)
					end
				end
				if #sources > 0 then
					local tname = getExpanded("TARGET")
					if tname == "" then tname = getExpanded("BIN") end
					if tname == "" then tname = getExpanded("PROGRAM") end
					if tname == "" then tname = getExpanded("APP") end
					if tname == "" then tname = path.getname(rootDir) end
					tname = path.getname(tname):gsub("%.exe$", "")
					table.insert(targets, {
						name    = tname,
						type    = "exe",
						sources = sources,
						bucket  = createFlagBucket(),
					})
				end
			end
		end

		if #targets == 0 then
			return nil
		end

		-- Determine workspace name (PACKAGE_NAME / PACKAGE from Makefile, configure.ac AC_INIT, or folder/first target)
		local wksName = getExpanded("PACKAGE_NAME")
		if wksName == "" then wksName = getExpanded("PACKAGE") end
		if wksName == "" then
			local configureAc = path.join(rootDir, "configure.ac")
			if os.isfile(configureAc) then
				local acText = io.readfile(configureAc) or ""
				local acName = acText:match("AC_INIT%s*%(%s*%[?([^,%]%)]+)")
				if acName then
					wksName = acName:gsub('["\'%s]', "")
				end
			end
		end
		if wksName == "" then
			wksName = targets[1].name ~= "" and targets[1].name or path.getname(rootDir)
		end

		return buildscan._assembleImportedState("Makefile (" .. path.getname(makefilePath) .. ")", rootDir, wksName, globalFlags, targets)
	end


-- =============================================================================
-- 2. CMAKE (`CMakeLists.txt`) PARSER
-- =============================================================================

	local function tokenizeCMakeCommands(content)
		content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
		local commands = {}
		local i = 1
		local n = #content

		local function skipWsAndComments()
			while i <= n do
				local ch = content:sub(i, i)
				if ch == " " or ch == "\t" or ch == "\n" then
					i = i + 1
				elseif ch == "#" then
					-- Bracket comment #[[ ... ]] or #[=[ ... ]=]
					local eqs = content:match("^#%[(=*)%[", i)
					if eqs then
						local closePat = "%]" .. eqs .. "%]"
						local _, endIdx = content:find(closePat, i + 3 + #eqs)
						i = endIdx and (endIdx + 1) or (n + 1)
					else
						while i <= n and content:sub(i, i) ~= "\n" do
							i = i + 1
						end
					end
				else
					break
				end
			end
		end

		while i <= n do
			skipWsAndComments()
			if i > n then break end

			local cmdName, nextPos = content:match("^([A-Za-z_][A-Za-z0-9_]*)%s*%(()", i)
			if not cmdName then
				-- Advance past unexpected line
				while i <= n and content:sub(i, i) ~= "\n" do
					i = i + 1
				end
			else
				i = nextPos
				local args = {}
				local depth = 1

				while i <= n and depth > 0 do
					skipWsAndComments()
					if i > n then break end

					local ch = content:sub(i, i)
					if ch == "(" then
						depth = depth + 1
						table.insert(args, "(")
						i = i + 1
					elseif ch == ")" then
						depth = depth - 1
						if depth > 0 then
							table.insert(args, ")")
						end
						i = i + 1
					elseif ch == '"' then
						i = i + 1
						local buf = {}
						while i <= n do
							local c = content:sub(i, i)
							if c == '"' then
								i = i + 1
								break
							elseif c == "\\" and i < n then
								local nxt = content:sub(i + 1, i + 1)
								if nxt == '"' or nxt == "\\" or nxt == "n" or nxt == "t" then
									if nxt == "n" then table.insert(buf, "\n")
									elseif nxt == "t" then table.insert(buf, "\t")
									else table.insert(buf, nxt) end
									i = i + 2
								else
									table.insert(buf, c)
									i = i + 1
								end
							else
								table.insert(buf, c)
								i = i + 1
							end
						end
						table.insert(args, table.concat(buf))
					else
						local word, afterWord = content:match("^([^%s%(%)#\"]+)()", i)
						if word then
							table.insert(args, word)
							i = afterWord
						else
							i = i + 1
						end
					end
				end

				table.insert(commands, {
					name = cmdName:lower(),
					args = args,
				})
			end
		end

		return commands
	end


	local function expandCMakeArg(arg, vars)
		if not arg then return "" end
		-- Skip $<INSTALL_INTERFACE:...> generator expressions
		if arg:match("^%$<INSTALL_INTERFACE:.*>$") then
			return ""
		end
		-- Unwrap $<BUILD_INTERFACE:...>
		arg = arg:gsub("%$<BUILD_INTERFACE:(.-)>", "%1")
		-- Strip any other unsupported generator expressions cleanly
		if arg:match("^%$<.*>$") then
			return ""
		end

		local guard = 0
		while guard < 10 do
			guard = guard + 1
			local replaced, count = arg:gsub("%${([A-Za-z0-9_]+)}", function(vname)
				if vars[vname] ~= nil then
					if type(vars[vname]) == "table" then
						return table.concat(vars[vname], ";")
					end
					return tostring(vars[vname])
				end
				return ""
			end)
			arg = replaced
			if count == 0 then break end
		end
		return arg
	end


	local function expandCMakeArgs(rawArgs, vars)
		local out = {}
		for _, raw in ipairs(rawArgs) do
			local exp = expandCMakeArg(raw, vars)
			if exp ~= "" then
				-- CMake lists are semicolon-separated
				if exp:find(";", 1, true) then
					for part in exp:gmatch("[^;]+") do
						if part ~= "" then
							table.insert(out, part)
						end
					end
				else
					table.insert(out, exp)
				end
			end
		end
		return out
	end


	function buildscan.parseCMake(cmakeFile, rootDir)
		rootDir = path.getabsolute(rootDir or path.getdirectory(cmakeFile))

		local wksName = nil
		local globalFlags = createFlagBucket()
		local cStandard = nil
		local cExtensions = true
		local cxxStandard = nil
		local cxxExtensions = true

		local targets = {}
		local targetMap = {}
		local visitedDirs = {}

		local function getOrCreateTarget(name, ttype)
			local t = targetMap[name]
			if not t then
				t = {
					name          = name,
					type          = ttype or "exe",
					sources       = {},
					bucket        = createFlagBucket(),
					publicInc     = {},
					publicDefines = {},
					pchHeader     = nil,
				}
				targetMap[name] = t
				table.insert(targets, t)
			end
			return t
		end

		local function processDirectory(dirAbs, parentVars)
			dirAbs = path.getabsolute(dirAbs)
			if visitedDirs[dirAbs] then return end
			visitedDirs[dirAbs] = true

			local fileAbs = path.join(dirAbs, "CMakeLists.txt")
			if not os.isfile(fileAbs) then return end
			local content = io.readfile(fileAbs)
			if not content then return end

			local envCc = (os.getenv("CC") or ""):lower()
			local isClangDefault = os.istarget("macosx") or (envCc:find("clang", 1, true) ~= nil)
			local vars = {
				CMAKE_SOURCE_DIR         = rootDir,
				PROJECT_SOURCE_DIR       = rootDir,
				CMAKE_CURRENT_SOURCE_DIR = dirAbs,
				CMAKE_BINARY_DIR         = path.join(rootDir, "build"),
				CMAKE_CURRENT_BINARY_DIR = path.join(rootDir, "build"),
				CMAKE_COMPILER_IS_GNU    = isClangDefault and "" or "1",
				CMAKE_COMPILER_IS_GNUCC  = isClangDefault and "" or "1",
				CMAKE_COMPILER_IS_CLANG  = isClangDefault and "1" or "",
			}
			if parentVars then
				for k, v in pairs(parentVars) do
					vars[k] = type(v) == "table" and table.shallowcopy(v) or v
				end
				vars.CMAKE_CURRENT_SOURCE_DIR = dirAbs
				vars.CMAKE_CURRENT_BINARY_DIR = path.join(rootDir, "build")
			end

			local function isCMakeTruthy(token)
				if token == nil then return false end
				local up = tostring(token):upper()
				if up == "" or up == "0" or up == "OFF" or up == "NO" or up == "FALSE" or up == "N" or up == "IGNORE" or up == "NOTFOUND" or up:endswith("-NOTFOUND") then
					return false
				end
				if up == "1" or up == "ON" or up == "YES" or up == "TRUE" or up == "Y" then
					return true
				end
				if vars[token] ~= nil then
					local v = vars[token]
					if type(v) == "table" then return #v > 0 end
					local vup = tostring(v):upper()
					return not (vup == "" or vup == "0" or vup == "OFF" or vup == "NO" or vup == "FALSE" or vup:endswith("-NOTFOUND"))
				end
				return false
			end

			local function evalCMakeCond(rawArgs)
				local joined = table.concat(rawArgs, " "):upper()
				if joined == "WIN32" or joined == "MSVC" or joined == "CMAKE_HOST_WIN32" then
					return true, "windows"
				elseif joined == "APPLE" or joined == "MACOSX" then
					return true, "macos"
				elseif joined == "LINUX" or joined == "UNIX AND NOT APPLE" then
					return true, "linux"
				elseif joined:find("CMAKE_COMPILER_IS_IAR", 1, true) or joined:find("CMAKE_COMPILER_IS_MSVC", 1, true) then
					return false, nil
				end

				-- Evaluate simple NOT / DEFINED / single-var / AND / OR expressions
				if #rawArgs == 1 then
					local tok = expandCMakeArg(rawArgs[1], vars)
					if vars[rawArgs[1]] ~= nil then
						return isCMakeTruthy(rawArgs[1]), nil
					end
					return isCMakeTruthy(tok), nil
				elseif #rawArgs == 2 and rawArgs[1]:upper() == "NOT" then
					local subOk = evalCMakeCond({ rawArgs[2] })
					return (not subOk), nil
				elseif #rawArgs == 2 and rawArgs[1]:upper() == "DEFINED" then
					return (vars[rawArgs[2]] ~= nil), nil
				elseif #rawArgs == 3 and rawArgs[1]:upper() == "NOT" and rawArgs[2]:upper() == "DEFINED" then
					return (vars[rawArgs[3]] == nil), nil
				end

				-- Handle simple `A AND B` / `A OR B`
				for idx, tok in ipairs(rawArgs) do
					local up = tok:upper()
					if up == "AND" and idx > 1 and idx < #rawArgs then
						local left = evalCMakeCond(sliceArray(rawArgs, 1, idx - 1))
						local right = evalCMakeCond(sliceArray(rawArgs, idx + 1, #rawArgs))
						return (left and right), nil
					elseif up == "OR" and idx > 1 and idx < #rawArgs then
						local left = evalCMakeCond(sliceArray(rawArgs, 1, idx - 1))
						local right = evalCMakeCond(sliceArray(rawArgs, idx + 1, #rawArgs))
						return (left or right), nil
					end
				end

				return true, nil
			end

			local condStack = {} -- { active = bool, seenTrue = bool, osTag = string|nil }
			local fnDepth = 0

			local function isActiveBranch()
				if fnDepth > 0 then return false end
				for idx = 1, #condStack do
					if not condStack[idx].active then
						return false
					end
				end
				return true
			end

			local function activeOs()
				for idx = #condStack, 1, -1 do
					if condStack[idx].osTag then
						return condStack[idx].osTag
					end
				end
				return nil
			end

			local cmds = tokenizeCMakeCommands(content)

			local function runCommandRange(startIdx, endIdx)
				local idxCmd = startIdx
				while idxCmd <= endIdx do
					local cmd = cmds[idxCmd]
					local cname = cmd.name

					if cname == "function" or cname == "macro" then
						fnDepth = fnDepth + 1
						idxCmd = idxCmd + 1
					elseif cname == "endfunction" or cname == "endmacro" then
						if fnDepth > 0 then fnDepth = fnDepth - 1 end
						idxCmd = idxCmd + 1
					elseif fnDepth > 0 then
						idxCmd = idxCmd + 1
					elseif cname == "if" then
						if not isActiveBranch() then
							table.insert(condStack, { active = false, seenTrue = true, osTag = nil })
						else
							local okCond, osTag = evalCMakeCond(cmd.args)
							table.insert(condStack, { active = okCond, seenTrue = okCond, osTag = osTag })
						end
						idxCmd = idxCmd + 1
					elseif cname == "elseif" then
						local top = condStack[#condStack]
						if top then
							if top.seenTrue then
								top.active = false
								top.osTag  = nil
							else
								local okCond, osTag = evalCMakeCond(cmd.args)
								top.active   = okCond
								top.seenTrue = okCond
								top.osTag    = osTag
							end
						end
						idxCmd = idxCmd + 1
					elseif cname == "else" then
						local top = condStack[#condStack]
						if top then
							top.active = (not top.seenTrue)
							top.seenTrue = true
							top.osTag = nil
						end
						idxCmd = idxCmd + 1
					elseif cname == "endif" then
						if #condStack > 0 then
							table.remove(condStack)
						end
						idxCmd = idxCmd + 1
					elseif cname == "foreach" then
						-- Find matching endforeach
						local depth = 1
						local closeIdx = idxCmd + 1
						while closeIdx <= endIdx and depth > 0 do
							if cmds[closeIdx].name == "foreach" then
								depth = depth + 1
							elseif cmds[closeIdx].name == "endforeach" then
								depth = depth - 1
								if depth == 0 then break end
							end
							closeIdx = closeIdx + 1
						end

						if isActiveBranch() and #cmd.args >= 2 then
							local loopVar = cmd.args[1]
							local items = {}
							if cmd.args[2] and cmd.args[2]:upper() == "IN" and cmd.args[3] and cmd.args[3]:upper() == "LISTS" then
								for li = 4, #cmd.args do
									local lv = vars[cmd.args[li]]
									if type(lv) == "table" then
										for _, it in ipairs(lv) do table.insert(items, it) end
									elseif lv and lv ~= "" then
										for part in tostring(lv):gmatch("[^;]+") do table.insert(items, part) end
									end
								end
							else
								local startLi = (cmd.args[2] and cmd.args[2]:upper() == "IN" and cmd.args[3] and cmd.args[3]:upper() == "ITEMS") and 4 or 2
								items = expandCMakeArgs(sliceArray(cmd.args, startLi, #cmd.args), vars)
							end

							local prevVal = vars[loopVar]
							for _, itemVal in ipairs(items) do
								vars[loopVar] = itemVal
								runCommandRange(idxCmd + 1, closeIdx - 1)
							end
							vars[loopVar] = prevVal
						end
						idxCmd = closeIdx + 1
					elseif not isActiveBranch() then
						idxCmd = idxCmd + 1
					else
						local args = expandCMakeArgs(cmd.args, vars)

						if cname == "option" and #args >= 1 then
							local optName = args[1]
							local optDef  = args[3] or "OFF"
							if vars[optName] == nil then
								vars[optName] = optDef
							end
						elseif cname == "project" and #args >= 1 then
					if not wksName then
						wksName = args[1]
					end
					vars.PROJECT_NAME = args[1]
				elseif cname == "set" and #args >= 1 then
					local varName = cmd.args[1] and expandCMakeArg(cmd.args[1], vars) or args[1]
					local vals = {}
					local hasParentScope = false
					for idx = 2, #args do
						local a = args[idx]
						if a == "CACHE" or a == "FORCE" then
							break
						elseif a == "PARENT_SCOPE" then
							hasParentScope = true
							break
						else
							table.insert(vals, a)
						end
					end
					vars[varName] = (#vals == 1) and vals[1] or vals
					if hasParentScope and parentVars then
						parentVars[varName] = vars[varName]
					end

					if varName == "CMAKE_C_STANDARD" and vals[1] then
						cStandard = vals[1]
					elseif varName == "CMAKE_C_EXTENSIONS" and vals[1] then
						cExtensions = (vals[1]:upper() ~= "OFF" and vals[1]:upper() ~= "FALSE")
					elseif varName == "CMAKE_CXX_STANDARD" and vals[1] then
						cxxStandard = vals[1]
					elseif varName == "CMAKE_CXX_EXTENSIONS" and vals[1] then
						cxxExtensions = (vals[1]:upper() ~= "OFF" and vals[1]:upper() ~= "FALSE")
					elseif varName == "CMAKE_C_FLAGS" or varName == "CMAKE_CXX_FLAGS" then
						parseFlagsIntoBucket(buildscan.tokenizeShellWords(table.concat(vals, " ")), rootDir, dirAbs, globalFlags, "compile")
					end
				elseif cname == "list" and #args >= 2 and args[1]:upper() == "APPEND" then
					local varName = args[2]
					local cur = vars[varName]
					if type(cur) ~= "table" then
						cur = (cur and cur ~= "") and { tostring(cur) } or {}
					end
					for idx = 3, #args do
						table.insert(cur, args[idx])
					end
					vars[varName] = cur
				elseif cname == "file" and #args >= 2 and (args[1]:upper() == "GLOB" or args[1]:upper() == "GLOB_RECURSE") then
					local isRecurse = (args[1]:upper() == "GLOB_RECURSE")
					local varIdx = 2
					local skipNext = false
					local patterns = {}
					local outVar = nil
					while varIdx <= #args do
						local a = args[varIdx]
						local up = a:upper()
						if skipNext then
							skipNext = false
						elseif up == "CONFIGURE_DEPENDS" or up == "FOLLOW_SYMLINKS" then
							-- ignore keyword
						elseif up == "RELATIVE" or up == "LIST_DIRECTORIES" then
							skipNext = true
						elseif not outVar then
							outVar = a
						else
							local relPat = normalizeRelPath(rootDir, dirAbs, a)
							if relPat and isRecurse and not relPat:find("**", 1, true) then
								relPat = relPat:gsub("%*", "**", 1)
							end
							if relPat then
								table.insert(patterns, relPat)
							end
						end
						varIdx = varIdx + 1
					end
					if outVar then
						vars[outVar] = patterns
					end
				elseif cname == "include_directories" then
					local isSys = false
					for _, a in ipairs(args) do
						local up = a:upper()
						if up == "SYSTEM" then
							isSys = true
						elseif up ~= "BEFORE" and up ~= "AFTER" then
							local rel = normalizeRelPath(rootDir, dirAbs, a)
							if rel then
								appendUnique(isSys and globalFlags.systemIncludes or globalFlags.includes, rel)
							end
						end
					end
				elseif cname == "link_directories" then
					for _, a in ipairs(args) do
						local up = a:upper()
						if up ~= "BEFORE" and up ~= "AFTER" then
							local rel = normalizeRelPath(rootDir, dirAbs, a)
							appendUnique(globalFlags.libDirs, rel)
						end
					end
				elseif cname == "add_compile_definitions" or cname == "add_definitions" then
					for _, a in ipairs(args) do
						local d = a:gsub("^%-D", "")
						if d ~= "" and d ~= "DEBUG" and d ~= "_DEBUG" and d ~= "NDEBUG" then
							appendUnique(globalFlags.defines, d)
						end
					end
				elseif cname == "add_compile_options" then
					parseFlagsIntoBucket(args, rootDir, dirAbs, globalFlags, "compile")
				elseif cname == "add_link_options" then
					parseFlagsIntoBucket(args, rootDir, dirAbs, globalFlags, "link")
				elseif cname == "add_executable" and #args >= 1 then
					local tname = args[1]
					local isImportedOrAlias = false
					local ttype = "exe"
					local srcList = {}
					for idx = 2, #args do
						local a = args[idx]
						local up = a:upper()
						if up == "IMPORTED" or up == "ALIAS" then
							isImportedOrAlias = true
							break
						elseif up == "WIN32" or up == "MACOSX_BUNDLE" then
							ttype = "gui"
						elseif up ~= "EXCLUDE_FROM_ALL" then
							local rel = normalizeRelPath(rootDir, dirAbs, a)
							appendUnique(srcList, rel)
						end
					end
					if not isImportedOrAlias then
						local t = getOrCreateTarget(tname, ttype)
						t.type = ttype
						for _, s in ipairs(srcList) do
							appendUnique(t.sources, s)
						end
					end
				elseif cname == "add_library" and #args >= 1 then
					local tname = args[1]
					local isImportedOrAlias = false
					local ttype = "static_lib"
					local startIdx = 2
					if args[2] then
						local up2 = args[2]:upper()
						if up2 == "ALIAS" or up2 == "IMPORTED" then
							isImportedOrAlias = true
						elseif up2 == "STATIC" or up2 == "OBJECT" then
							ttype = "static_lib"
							startIdx = 3
						elseif up2 == "SHARED" or up2 == "MODULE" then
							ttype = "shared_lib"
							startIdx = 3
						elseif up2 == "INTERFACE" then
							ttype = "header_only"
							startIdx = 3
						end
					end
					for idx = startIdx, #args do
						local up = args[idx]:upper()
						if up == "IMPORTED" or up == "ALIAS" then
							isImportedOrAlias = true
							break
						end
					end
					if not isImportedOrAlias then
						local t = getOrCreateTarget(tname, ttype)
						t.type = ttype
						for idx = startIdx, #args do
							local a = args[idx]
							if a:upper() ~= "EXCLUDE_FROM_ALL" then
								local rel = normalizeRelPath(rootDir, dirAbs, a)
								appendUnique(t.sources, rel)
							end
						end
					end
				elseif cname == "target_sources" and #args >= 2 then
					local t = targetMap[args[1]]
					if t then
						for idx = 2, #args do
							local a = args[idx]
							local up = a:upper()
							if up ~= "PRIVATE" and up ~= "PUBLIC" and up ~= "INTERFACE" then
								local rel = normalizeRelPath(rootDir, dirAbs, a)
								appendUnique(t.sources, rel)
							end
						end
					end
				elseif cname == "target_include_directories" and #args >= 2 then
					local t = targetMap[args[1]]
					if t then
						local isSys = false
						local vis = "PRIVATE"
						for idx = 2, #args do
							local a = args[idx]
							local up = a:upper()
							if up == "SYSTEM" then
								isSys = true
							elseif up == "PUBLIC" or up == "PRIVATE" or up == "INTERFACE" then
								vis = up
							elseif up ~= "BEFORE" and up ~= "AFTER" then
								local rel = normalizeRelPath(rootDir, dirAbs, a)
								if rel then
									if isSys then
										appendUnique(t.bucket.systemIncludes, rel)
									else
										appendUnique(t.bucket.includes, rel)
										if (vis == "PUBLIC" or vis == "INTERFACE") and t.type ~= "exe" and t.type ~= "gui" then
											appendUnique(t.publicInc, rel)
										end
									end
								end
							end
						end
					end
				elseif cname == "target_compile_definitions" and #args >= 2 then
					local t = targetMap[args[1]]
					if t then
						local vis = "PRIVATE"
						for idx = 2, #args do
							local a = args[idx]
							local up = a:upper()
							if up == "PUBLIC" or up == "PRIVATE" or up == "INTERFACE" then
								vis = up
							else
								local d = a:gsub("^%-D", "")
								if d ~= "" and d ~= "DEBUG" and d ~= "_DEBUG" and d ~= "NDEBUG" then
									appendUnique(t.bucket.defines, d)
									if (vis == "PUBLIC" or vis == "INTERFACE") and t.type ~= "exe" and t.type ~= "gui" then
										appendUnique(t.publicDefines, d)
									end
								end
							end
						end
					end
				elseif cname == "target_compile_options" and #args >= 2 then
					local t = targetMap[args[1]]
					if t then
						local filtered = {}
						for idx = 2, #args do
							local up = args[idx]:upper()
							if up ~= "PUBLIC" and up ~= "PRIVATE" and up ~= "INTERFACE" and up ~= "BEFORE" then
								table.insert(filtered, args[idx])
							end
						end
						parseFlagsIntoBucket(filtered, rootDir, dirAbs, t.bucket, "compile")
					end
				elseif cname == "target_compile_features" and #args >= 2 then
					local t = targetMap[args[1]]
					if t then
						for idx = 2, #args do
							local low = args[idx]:lower()
							local cxxVer = low:match("^cxx_std_(%d+)$")
							local cVer   = low:match("^c_std_(%d+)$")
							if cxxVer and STD_FLAG_MAP["c++" .. cxxVer] then
								t.bucket.lang = STD_FLAG_MAP["c++" .. cxxVer]
							elseif cVer and STD_FLAG_MAP["c" .. cVer] then
								t.bucket.lang = STD_FLAG_MAP["c" .. cVer]
							end
						end
					end
				elseif cname == "target_link_directories" and #args >= 2 then
					local t = targetMap[args[1]]
					if t then
						for idx = 2, #args do
							local up = args[idx]:upper()
							if up ~= "PUBLIC" and up ~= "PRIVATE" and up ~= "INTERFACE" and up ~= "BEFORE" then
								local rel = normalizeRelPath(rootDir, dirAbs, args[idx])
								appendUnique(t.bucket.libDirs, rel)
							end
						end
					end
				elseif cname == "target_link_options" and #args >= 2 then
					local t = targetMap[args[1]]
					if t then
						local filtered = {}
						for idx = 2, #args do
							local up = args[idx]:upper()
							if up ~= "PUBLIC" and up ~= "PRIVATE" and up ~= "INTERFACE" and up ~= "BEFORE" then
								table.insert(filtered, args[idx])
							end
						end
						parseFlagsIntoBucket(filtered, rootDir, dirAbs, t.bucket, "link")
					end
				elseif cname == "target_link_libraries" and #args >= 2 then
					local t = targetMap[args[1]]
					if t then
						local curOs = activeOs()
						for idx = 2, #args do
							local lib = args[idx]
							local up = lib:upper()
							if up ~= "PUBLIC" and up ~= "PRIVATE" and up ~= "INTERFACE"
								and up ~= "LINK_PUBLIC" and up ~= "LINK_PRIVATE"
								and up ~= "OPTIMIZED" and up ~= "DEBUG" and up ~= "GENERAL" then
								lib = lib:gsub("^%-l", "")
								if lib == "Threads::Threads" then
									appendUnique(t.bucket.linuxLinks, "pthread")
								else
									-- Resolve Foo::bar alias if `bar` is a target in this workspace
									local _, shortAlias = lib:match("^(.-)::(.+)$")
									if shortAlias and targetMap[shortAlias] then
										lib = shortAlias
									end
									if not lib:find("::", 1, true) then
										if curOs == "windows" then
											appendUnique(t.bucket.windowsLinks, lib)
										elseif curOs == "linux" then
											appendUnique(t.bucket.linuxLinks, lib)
										elseif curOs == "macos" then
											appendUnique(t.bucket.macosLinks, lib)
										else
											appendUnique(t.bucket.links, lib)
										end
									end
								end
							end
						end
					end
				elseif cname == "target_precompile_headers" and #args >= 2 then
					local t = targetMap[args[1]]
					if t then
						for idx = 2, #args do
							local a = args[idx]
							local up = a:upper()
							if up ~= "PUBLIC" and up ~= "PRIVATE" and up ~= "INTERFACE" and up ~= "REUSE_FROM" then
								t.pchHeader = a:gsub("^<(.+)>$", "%1")
								break
							end
						end
					end
				elseif cname == "add_subdirectory" and #args >= 1 then
					local subName = args[1]
					local subLower = path.getname(subName):lower()
					-- Skip pure test/fuzz/doc/program-demo subdirectories when importing library/app targets
					if subLower ~= "tests" and subLower ~= "test" and subLower ~= "regress"
						and subLower ~= "docs" and subLower ~= "doc" and subLower ~= "doxygen" then
						local subAbs = path.isabsolute(subName) and subName or path.join(dirAbs, subName)
						if os.isdir(subAbs) then
							processDirectory(subAbs, vars)
						end
					end
				end
						idxCmd = idxCmd + 1
					end
				end
			end

			runCommandRange(1, #cmds)
		end

		processDirectory(path.getdirectory(path.getabsolute(cmakeFile)), nil)

		-- Filter out any degenerate target with 0 sources unless header_only
		local validTargets = {}
		for _, t in ipairs(targets) do
			if t.name and t.name ~= "" and (t.type == "header_only" or #t.sources > 0) then
				table.insert(validTargets, t)
			end
		end
		targets = validTargets

		if #targets == 0 then
			return nil
		end

		-- Apply global CMake C and C++ standards separately so pure-C targets stay C!
		if cxxStandard then
			local prefix = cxxExtensions and "gnu++" or "c++"
			globalFlags.cxxLang = STD_FLAG_MAP[prefix .. tostring(cxxStandard)] or STD_FLAG_MAP["c++" .. tostring(cxxStandard)]
		end
		if cStandard then
			local prefix = cExtensions and "gnu" or "c"
			globalFlags.cLang = STD_FLAG_MAP[prefix .. tostring(cStandard)] or STD_FLAG_MAP["c" .. tostring(cStandard)]
		end

		wksName = wksName or targets[1].name or path.getname(rootDir)
		wksName = wksName:gsub("%s+", "_")

		return buildscan._assembleImportedState("CMake (CMakeLists.txt)", rootDir, wksName, globalFlags, targets)
	end


-- =============================================================================
-- 3. ASSEMBLING UNIFIED WIZARD STATE FROM EXTRACTED BUILD DATA
-- =============================================================================

	function buildscan._assembleImportedState(sourceLabel, rootDir, wksName, globalFlags, rawTargets)
		local hostArch = os.hostarch and os.hostarch() or "x86_64"
		local normArch = p.init.steps.ARCHS[tostring(hostArch):lower()] or "x86_64"

		local step1Targets = {}
		local exportsInput = {}
		local depsInput    = {}
		local ovrInput     = {}
		local summaryStats = {
			targets       = #rawTargets,
			links         = 0,
			defines       = #globalFlags.defines,
			compilerFlags = #globalFlags.compilerFlags,
		}

		for _, rt in ipairs(rawTargets) do
			local tb = rt.bucket or createFlagBucket()

			-- Infer target language if not explicitly specified by -std= or target_compile_features
			local hasCpp = false
			for _, s in ipairs(rt.sources) do
				local ext = getExtExact(s)
				if ext and CPP_EXTS[ext] then
					hasCpp = true
					break
				end
			end

			local chosenLang = tb.lang
			if not chosenLang then
				if hasCpp then
					chosenLang = globalFlags.cxxLang or globalFlags.lang or "c++20"
				else
					chosenLang = globalFlags.cLang or globalFlags.lang or "c17"
				end
			end
			if hasCpp and chosenLang:sub(1, 3) ~= "c++" and chosenLang:sub(1, 5) ~= "gnu++" then
				chosenLang = globalFlags.cxxLang or "c++20"
			end

			local mergedInc = table.shallowcopy(globalFlags.includes)
			for _, inc in ipairs(tb.includes) do
				appendUnique(mergedInc, inc)
			end
			-- If rootDir headers exist alongside rootDir sources and no include dir was explicit, add "."
			if #mergedInc == 0 then
				for _, s in ipairs(rt.sources) do
					if not s:find("/", 1, true) then
						table.insert(mergedInc, ".")
						break
					end
				end
			end

			local langMeta = p.init.steps.LANGUAGES[chosenLang] or { language = "C" }
			local kind     = p.init.steps.TARGET_TYPES[rt.type] or "ConsoleApp"

			table.insert(step1Targets, {
				name       = rt.name,
				rawType    = rt.type,
				kind       = kind,
				langKey    = chosenLang,
				language   = langMeta.language,
				cdialect   = langMeta.cdialect,
				cppdialect = langMeta.cppdialect,
				sources    = rt.sources,
				includes   = mergedInc,
			})

			-- Step 2: Public library exports & dependencies
			if (rt.publicInc and #rt.publicInc > 0) or (rt.publicDefines and #rt.publicDefines > 0) then
				exportsInput[rt.name] = {
					publicIncludes = rt.publicInc or {},
					publicDefines  = rt.publicDefines or {},
				}
			end

			local mergedLinks    = table.shallowcopy(globalFlags.links)
			local mergedSysInc   = table.shallowcopy(globalFlags.systemIncludes)
			local mergedLibDirs  = table.shallowcopy(globalFlags.libDirs)
			local mergedWinLinks = table.shallowcopy(globalFlags.windowsLinks)
			local mergedLinLinks = table.shallowcopy(globalFlags.linuxLinks)
			local mergedMacLinks = table.shallowcopy(globalFlags.macosLinks)

			for _, v in ipairs(tb.links)          do appendUnique(mergedLinks, v) end
			for _, v in ipairs(tb.systemIncludes) do appendUnique(mergedSysInc, v) end
			for _, v in ipairs(tb.libDirs)        do appendUnique(mergedLibDirs, v) end
			for _, v in ipairs(tb.windowsLinks)   do appendUnique(mergedWinLinks, v) end
			for _, v in ipairs(tb.linuxLinks)     do appendUnique(mergedLinLinks, v) end
			for _, v in ipairs(tb.macosLinks)     do appendUnique(mergedMacLinks, v) end

			summaryStats.links = summaryStats.links + #mergedLinks + #mergedWinLinks + #mergedLinLinks + #mergedMacLinks

			depsInput[rt.name] = {
				links          = mergedLinks,
				systemIncludes = mergedSysInc,
				libDirs        = mergedLibDirs,
				windowsLinks   = mergedWinLinks,
				linuxLinks     = mergedLinLinks,
				macosLinks     = mergedMacLinks,
			}

			-- Step 3: Per-target defines, compiler/linker flags, PCH
			local mergedDefines  = table.shallowcopy(globalFlags.defines)
			local mergedCFlags   = table.shallowcopy(globalFlags.compilerFlags)
			local mergedLdFlags  = table.shallowcopy(globalFlags.linkerFlags)

			for _, v in ipairs(tb.defines)       do appendUnique(mergedDefines, v) end
			for _, v in ipairs(tb.compilerFlags) do appendUnique(mergedCFlags, v) end
			for _, v in ipairs(tb.linkerFlags)   do appendUnique(mergedLdFlags, v) end

			summaryStats.defines       = math.max(summaryStats.defines, #mergedDefines)
			summaryStats.compilerFlags = math.max(summaryStats.compilerFlags, #mergedCFlags)

			ovrInput[rt.name] = {
				pchHeader      = rt.pchHeader,
				pchSource      = nil,
				defines        = mergedDefines,
				excludeSources = {},
				compilerFlags  = mergedCFlags,
				linkerFlags    = mergedLdFlags,
			}
		end

		local step1 = {
			workspace = {
				name     = wksName,
				buildDir = "build",
				modes    = { "Debug", "Release" },
				archs    = { normArch },
			},
			targets = step1Targets,
		}

		local step2 = {
			exports     = exportsInput,
			deps        = depsInput,
			subprojects = {},
		}

		local warningsRaw = globalFlags.warnings
		local warningsCanonical = warningsRaw and p.init.steps.WARNINGS[warningsRaw:lower()] or nil

		local step3 = {
			compiler = {
				warnings         = warningsCanonical,
				warningsKey      = warningsRaw or "",
				warningsAsErrors = globalFlags.warningsAsErrors == true,
				rtti             = globalFlags.rtti,
				exceptions       = globalFlags.exceptions,
				staticRuntime    = globalFlags.staticRuntime,
				ltoInRelease     = globalFlags.ltoInRelease == true,
				debugSanitizers  = globalFlags.sanitizers,
			},
			platforms       = {},
			targetOverrides = ovrInput,
		}

		local step4 = {
			debug = {},
			hooks = {},
		}

		return {
			sourceLabel  = sourceLabel,
			rootDir      = rootDir,
			summaryStats = summaryStats,
			step1        = step1,
			step2        = step2,
			step3        = step3,
			step4        = step4,
		}
	end


---
-- Detect and parse an existing build configuration in `rootDir` (if present).
---
	function buildscan.detect(rootDir)
		rootDir = path.getabsolute(rootDir or os.getcwd())

		-- 1) Configured Autotools Makefile (contains exact ./configure host DEFS, LIBS, LIBOBJS)
		for _, mkName in ipairs({ "Makefile", "GNUmakefile", "makefile" }) do
			local mkPath = path.join(rootDir, mkName)
			if os.isfile(mkPath) then
				local head = (io.readfile(mkPath) or ""):sub(1, 512)
				if head:find("Generated from Makefile.in by configure", 1, true) then
					local res = buildscan.parseMakefile(mkPath, rootDir)
					if res then return res end
				end
			end
		end

		-- 2) CMakeLists.txt
		local cmakePath = path.join(rootDir, "CMakeLists.txt")
		if os.isfile(cmakePath) then
			local res = buildscan.parseCMake(cmakePath, rootDir)
			if res then return res end
		end

		-- 3) Handwritten Makefile / GNUmakefile / makefile
		for _, mkName in ipairs({ "Makefile", "GNUmakefile", "makefile" }) do
			local mkPath = path.join(rootDir, mkName)
			if os.isfile(mkPath) then
				local res = buildscan.parseMakefile(mkPath, rootDir)
				if res then return res end
			end
		end

		-- 4) Unconfigured Automake Makefile.am
		local amPath = path.join(rootDir, "Makefile.am")
		if os.isfile(amPath) then
			local res = buildscan.parseMakefile(amPath, rootDir)
			if res then return res end
		end

		return nil
	end
