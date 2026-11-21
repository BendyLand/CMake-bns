--
-- actions/init/init_scanner.lua
-- Recursively scans a project directory for C/C++ source and header files
-- (including variants like .C, .cc, .cxx, .hpp, .hh, etc.) and synthesizes
-- Premake glob paths and include directories for Step 1 pre-population.
--

	local p = premake
	p.init = p.init or {}
	p.init.scanner = {}
	local scanner = p.init.scanner

	-- Directories ignored during recursive auto-detection
	local IGNORED_DIRS = {
		["build"]        = true,
		["bin"]          = true,
		["obj"]          = true,
		["out"]          = true,
		["debug"]        = true,
		["release"]      = true,
		["x64"]          = true,
		["win32"]        = true,
		["cmakefiles"]   = true,
		["node_modules"] = true,
		["target"]       = true,
		["dist"]         = true,
	}

	-- Case-sensitive C / C++ extension classification
	local CPP_SOURCE_EXTS = {
		[".cpp"]  = true,
		[".cc"]   = true,
		[".cxx"]  = true,
		[".c++"]  = true,
		[".cp"]   = true,
		[".C"]    = true,
		[".ixx"]  = true,
		[".cppm"] = true,
	}

	local C_SOURCE_EXTS = {
		[".c"] = true,
	}

	local CPP_HEADER_EXTS = {
		[".hpp"] = true,
		[".hh"]  = true,
		[".hxx"] = true,
		[".h++"] = true,
		[".H"]   = true,
		[".inl"] = true,
		[".ipp"] = true,
		[".tpp"] = true,
	}

	local COMMON_HEADER_EXTS = {
		[".h"]   = true,
		[".inc"] = true,
	}


	local function getExtensionExact(filename)
		local dot = filename:match("^.*()%.")
		if not dot or dot == 1 then
			return nil
		end
		return filename:sub(dot)
	end


	local function fileDefinesMain(filepath)
		local st = os.stat(filepath)
		if st and st.size and st.size > 262144 then
			return false
		end
		local f = io.open(filepath, "rb")
		if not f then
			return false
		end
		local content = f:read("*a")
		f:close()
		if not content then
			return false
		end
		-- Match common C/C++ entry points: main(...), wmain(...), WinMain(...), wWinMain(...)
		if content:match("%f[%w_]main%s*%(") or
		   content:match("%f[%w_]wmain%s*%(") or
		   content:match("%f[%w_]WinMain%s*%(") or
		   content:match("%f[%w_]wWinMain%s*%(") then
			return true
		end
		return false
	end


	local function sanitizeIdentifier(name)
		if not name or name == "" then
			return "app"
		end
		local cleaned = name:gsub("[^A-Za-z0-9_%-]", "_")
		cleaned = cleaned:gsub("_+", "_")
		cleaned = cleaned:gsub("^_+", ""):gsub("_+$", "")
		if cleaned == "" then
			return "app"
		end
		return cleaned
	end


---
-- Scan `rootDir` recursively for C/C++ source and header files.
--
-- If valid files are found, returns `found = true` along with detected
-- glob paths (`sources`), `includes`, `lang`, `targetType`, `workspaceName`,
-- and `targetName`.
-- If NO valid C/C++ files are found, returns `found = false` so Step 1 leaves
-- all fields at blank defaults ("" / []).
---
	function scanner.scanDirectory(rootDir)
		rootDir = path.getabsolute(rootDir or os.getcwd())

		local rootExts = {}       -- ext -> true for files directly in rootDir
		local subdirExts = {}     -- topDir -> { ext -> true }
		local includeDirs = {}    -- dir -> true
		local hasCpp = false
		local hasC = false
		local hasCompilableSource = false
		local hasMain = false
		local sourceCount = 0
		local headerCount = 0

		local function walk(absDir, relDir, topDir)
			local m = os.matchstart(path.join(absDir, "*"))
			local entries = {}
			while os.matchnext(m) do
				local name = os.matchname(m)
				local isFile = os.matchisfile(m)
				table.insert(entries, { name = name, isFile = isFile })
			end
			os.matchdone(m)

			for i = 1, #entries do
				local entry = entries[i]
				local name = entry.name

				-- Always skip hidden files/directories (.git, .vs, .cache, etc.)
				if name:sub(1, 1) ~= "." then
					local childAbs = path.join(absDir, name)
					local childRel = (relDir == "") and name or (relDir .. "/" .. name)

					if entry.isFile then
						local ext = getExtensionExact(name)
						if ext then
							local isCppSrc = CPP_SOURCE_EXTS[ext]
							local isCSrc   = C_SOURCE_EXTS[ext]
							local isCppHdr = CPP_HEADER_EXTS[ext]
							local isHdr    = isCppHdr or COMMON_HEADER_EXTS[ext]

							if isCppSrc or isCSrc or isHdr then
								if isCppSrc or isCppHdr then
									hasCpp = true
								end
								if isCSrc then
									hasC = true
								end
								if isCppSrc or isCSrc then
									hasCompilableSource = true
									sourceCount = sourceCount + 1
									if not hasMain and fileDefinesMain(childAbs) then
										hasMain = true
									end
								else
									headerCount = headerCount + 1
								end

								if not topDir then
									rootExts[ext] = true
								else
									subdirExts[topDir] = subdirExts[topDir] or {}
									subdirExts[topDir][ext] = true
								end

								if isHdr then
									if not topDir then
										includeDirs["."] = true
									else
										-- Detect nested `.../include` convention (e.g. libs/foo/include)
										local nestedInc = childRel:match("^(.-/include)/")
										if nestedInc then
											includeDirs[nestedInc] = true
										else
											includeDirs[topDir] = true
										end
									end
								end
							end
						end
					else
						if not IGNORED_DIRS[name:lower()] then
							walk(childAbs, childRel, topDir or name)
						end
					end
				end
			end
		end

		walk(rootDir, "", nil)

		local totalFiles = sourceCount + headerCount
		if totalFiles == 0 then
			return {
				found       = false,
				rootDir     = rootDir,
				sourceCount = 0,
				headerCount = 0,
				sources     = {},
				includes    = {},
			}
		end

		-- Build deterministic glob list
		local sources = {}

		local rootExtKeys = table.keys(rootExts)
		table.sort(rootExtKeys)
		for _, ext in ipairs(rootExtKeys) do
			table.insert(sources, "*" .. ext)
		end

		local topDirs = table.keys(subdirExts)
		table.sort(topDirs)
		for _, dir in ipairs(topDirs) do
			local exts = table.keys(subdirExts[dir])
			table.sort(exts)
			for _, ext in ipairs(exts) do
				table.insert(sources, dir .. "/**" .. ext)
			end
		end

		-- Build deterministic include directories list
		local includes = table.keys(includeDirs)
		table.sort(includes, function(a, b)
			-- Put "include" first when present
			if a == "include" and b ~= "include" then return true end
			if b == "include" and a ~= "include" then return false end
			return a < b
		end)

		local lang = hasCpp and "c++20" or "c17"
		local targetType
		if not hasCompilableSource then
			targetType = "header_only"
		elseif hasMain then
			targetType = "exe"
		else
			targetType = "static_lib"
		end

		local folderName = path.getname(rootDir)
		local targetName = sanitizeIdentifier(folderName)

		local hostArch = os.hostarch and os.hostarch() or "x86_64"
		if hostArch == "amd64" or hostArch == "x64" then
			hostArch = "x86_64"
		elseif hostArch == "aarch64" or hostArch == "ARM64" then
			hostArch = "arm64"
		end

		return {
			found         = true,
			rootDir       = rootDir,
			sourceCount   = sourceCount,
			headerCount   = headerCount,
			workspaceName = sanitizeIdentifier(folderName),
			targetName    = targetName,
			targetType    = targetType,
			lang          = lang,
			sources       = sources,
			includes      = includes,
			buildDir      = "build",
			modes         = { "debug", "release" },
			archs         = { hostArch },
		}
	end
