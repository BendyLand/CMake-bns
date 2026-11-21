--
-- base/toml.lua
-- Lightweight pure-Lua TOML parser for interactive configuration skeletons.
-- Supports comments (#), basic & literal strings (single & multi-line),
-- integers, floats, booleans, single/multi-line arrays, inline tables,
-- [tables], [dotted.tables], and [[array_of_tables]].
--

	local p = premake
	p.toml = {}
	local toml = p.toml


---
-- Format a key safely for TOML headers or key = value assignments.
---
	function toml.formatKey(key)
		key = tostring(key)
		if key ~= "" and key:match("^[A-Za-z0-9_%-]+$") then
			return key
		end
		return toml.formatString(key)
	end


---
-- Format a Lua string as a valid TOML basic string.
---
	function toml.formatString(s)
		s = tostring(s or "")
		s = s:gsub("\\", "\\\\")
		s = s:gsub('"', '\\"')
		s = s:gsub("\b", "\\b")
		s = s:gsub("\f", "\\f")
		s = s:gsub("\n", "\\n")
		s = s:gsub("\r", "\\r")
		s = s:gsub("\t", "\\t")
		return '"' .. s .. '"'
	end


---
-- Format a flat Lua array of strings as a TOML array literal.
-- Uses multi-line formatting automatically when there are many items or long strings.
---
	function toml.formatStringArray(arr)
		if not arr or #arr == 0 then
			return "[]"
		end
		local parts = {}
		local totalLen = 2
		for i = 1, #arr do
			parts[i] = toml.formatString(arr[i])
			totalLen = totalLen + #parts[i] + 2
		end
		if #arr <= 4 and totalLen <= 76 then
			return "[" .. table.concat(parts, ", ") .. "]"
		end
		local lines = { "[" }
		for i = 1, #parts do
			table.insert(lines, "  " .. parts[i] .. ",")
		end
		table.insert(lines, "]")
		return table.concat(lines, "\n")
	end


---
-- Check whether a TOML document contains any non-comment, non-whitespace text.
---
	function toml.hasContent(text)
		if not text then
			return false
		end
		for line in (text .. "\n"):gmatch("(.-)\n") do
			local stripped = line:match("^%s*(.-)%s*$")
			if stripped ~= "" and stripped:sub(1, 1) ~= "#" then
				return true
			end
		end
		return false
	end


---
-- Parse a TOML string into a Lua table.
-- @return table on success, or (nil, errMsg, errLine) on failure.
---
	function toml.parse(input)
		if type(input) ~= "string" then
			return nil, "expected string input", 1
		end

		-- Normalize UTF-8 BOM and CRLF line endings while preserving line numbers
		if input:sub(1, 3) == "\239\187\191" then
			input = input:sub(4)
		end
		input = input:gsub("\r\n", "\n"):gsub("\r", "\n")

		local len = #input
		local pos = 1
		local line = 1

		local root = {}
		local currentTable = root
		-- Track metadata cleanly outside data tables so pairs() stays pure
		local arrayTables = {}     -- set of tables created by [[...]]
		local definedTables = {}   -- set of tables explicitly opened via [...]
		local assignedKeys = {}    -- assignedKeys[tbl][key] = true

		local function fail(msg, atLine)
			local ln = atLine or line
			error({ msg = string.format("line %d: %s", ln, msg), line = ln }, 0)
		end

		local function peek(offset)
			local idx = pos + (offset or 0)
			if idx > len then
				return ""
			end
			return input:sub(idx, idx)
		end

		local function advance(n)
			n = n or 1
			for _ = 1, n do
				if pos <= len then
					if input:sub(pos, pos) == "\n" then
						line = line + 1
					end
					pos = pos + 1
				end
			end
		end

		local function skipHorizontalWs()
			while pos <= len do
				local ch = peek()
				if ch == " " or ch == "\t" then
					pos = pos + 1
				else
					break
				end
			end
		end

		local function skipComment()
			if peek() == "#" then
				while pos <= len and peek() ~= "\n" do
					pos = pos + 1
				end
			end
		end

		local function skipWsAndComments(allowNewlines)
			while pos <= len do
				local ch = peek()
				if ch == " " or ch == "\t" then
					pos = pos + 1
				elseif allowNewlines and ch == "\n" then
					line = line + 1
					pos = pos + 1
				elseif ch == "#" then
					skipComment()
				else
					break
				end
			end
		end

		local function encodeUtf8(codepoint)
			if codepoint < 0 or (codepoint >= 0xD800 and codepoint <= 0xDFFF) or codepoint > 0x10FFFF then
				fail(string.format("invalid Unicode scalar U+%04X", codepoint))
			end
			if codepoint <= 0x7F then
				return string.char(codepoint)
			elseif codepoint <= 0x7FF then
				local b1 = 0xC0 + math.floor(codepoint / 0x40)
				local b2 = 0x80 + (codepoint % 0x40)
				return string.char(b1, b2)
			elseif codepoint <= 0xFFFF then
				local b1 = 0xE0 + math.floor(codepoint / 0x1000)
				local b2 = 0x80 + (math.floor(codepoint / 0x40) % 0x40)
				local b3 = 0x80 + (codepoint % 0x40)
				return string.char(b1, b2, b3)
			else
				local b1 = 0xF0 + math.floor(codepoint / 0x40000)
				local b2 = 0x80 + (math.floor(codepoint / 0x1000) % 0x40)
				local b3 = 0x80 + (math.floor(codepoint / 0x40) % 0x40)
				local b4 = 0x80 + (codepoint % 0x40)
				return string.char(b1, b2, b3, b4)
			end
		end

		local escapes = {
			['"']  = '"',
			["\\"] = "\\",
			["b"]  = "\b",
			["f"]  = "\f",
			["n"]  = "\n",
			["r"]  = "\r",
			["t"]  = "\t",
		}

		local function parseBasicString()
			local startLine = line
			local multiline = (input:sub(pos, pos + 2) == '"""')
			if multiline then
				advance(3)
				if peek() == "\n" then
					advance(1)
				end
			else
				advance(1)
			end

			local out = {}
			while pos <= len do
				if multiline and input:sub(pos, pos + 2) == '"""' then
					advance(3)
					-- Up to two extra quotes allowed inside closing delimiter
					while peek() == '"' do
						table.insert(out, '"')
						advance(1)
					end
					return table.concat(out)
				elseif not multiline and peek() == '"' then
					advance(1)
					return table.concat(out)
				elseif not multiline and peek() == "\n" then
					fail("unterminated string literal", startLine)
				elseif peek() == "\\" then
					advance(1)
					local esc = peek()
					if multiline and (esc == " " or esc == "\t" or esc == "\n") then
						-- Line-ending backslash trims whitespace/newlines
						local sawNewline = false
						while pos <= len do
							local c = peek()
							if c == " " or c == "\t" then
								advance(1)
							elseif c == "\n" then
								sawNewline = true
								advance(1)
							else
								break
							end
						end
						if not sawNewline then
							fail("invalid line-continuation backslash in multiline string")
						end
					elseif escapes[esc] then
						table.insert(out, escapes[esc])
						advance(1)
					elseif esc == "u" or esc == "U" then
						local digits = (esc == "u") and 4 or 8
						advance(1)
						local hex = input:sub(pos, pos + digits - 1)
						if #hex ~= digits or not hex:match("^[0-9A-Fa-f]+$") then
							fail("invalid Unicode escape '\\" .. esc .. hex .. "'")
						end
						advance(digits)
						table.insert(out, encodeUtf8(tonumber(hex, 16)))
					else
						fail("invalid escape sequence '\\" .. esc .. "' (use '/' for paths or single-quoted literal strings '...')")
					end
				else
					table.insert(out, peek())
					advance(1)
				end
			end

			fail("unterminated string literal", startLine)
		end

		local function parseLiteralString()
			local startLine = line
			local multiline = (input:sub(pos, pos + 2) == "'''")
			if multiline then
				advance(3)
				if peek() == "\n" then
					advance(1)
				end
			else
				advance(1)
			end

			local out = {}
			while pos <= len do
				if multiline and input:sub(pos, pos + 2) == "'''" then
					advance(3)
					while peek() == "'" do
						table.insert(out, "'")
						advance(1)
					end
					return table.concat(out)
				elseif not multiline and peek() == "'" then
					advance(1)
					return table.concat(out)
				elseif not multiline and peek() == "\n" then
					fail("unterminated literal string", startLine)
				else
					table.insert(out, peek())
					advance(1)
				end
			end

			fail("unterminated literal string", startLine)
		end

		local function parseKeySegment()
			skipHorizontalWs()
			local ch = peek()
			if ch == '"' then
				if input:sub(pos, pos + 2) == '"""' then
					fail("multiline strings cannot be used as keys")
				end
				return parseBasicString()
			elseif ch == "'" then
				if input:sub(pos, pos + 2) == "'''" then
					fail("multiline strings cannot be used as keys")
				end
				return parseLiteralString()
			else
				local m = input:match("^[A-Za-z0-9_%-]+", pos)
				if not m then
					fail(string.format("expected key name, got '%s'", ch == "\n" and "end of line" or ch))
				end
				pos = pos + #m
				return m
			end
		end

		local function parseKeyPath()
			local parts = { parseKeySegment() }
			skipHorizontalWs()
			while peek() == "." do
				advance(1)
				skipHorizontalWs()
				table.insert(parts, parseKeySegment())
				skipHorizontalWs()
			end
			return parts
		end

		local parseValue -- forward declaration

		local function parseArray()
			local startLine = line
			advance(1) -- '['
			local arr = {}
			while true do
				skipWsAndComments(true)
				if pos > len then
					fail("unterminated array '['", startLine)
				end
				if peek() == "]" then
					advance(1)
					return arr
				end

				local val = parseValue()
				table.insert(arr, val)

				skipWsAndComments(true)
				local ch = peek()
				if ch == "," then
					advance(1)
				elseif ch == "]" then
					advance(1)
					return arr
				else
					fail(string.format("expected ',' or ']' in array, got '%s'", ch == "\n" and "newline" or ch))
				end
			end
		end

		local function parseInlineTable()
			local startLine = line
			advance(1) -- '{'
			local tbl = {}
			assignedKeys[tbl] = {}

			skipHorizontalWs()
			if peek() == "}" then
				advance(1)
				return tbl
			end

			while true do
				skipHorizontalWs()
				if pos > len or peek() == "\n" then
					fail("unterminated inline table '{'", startLine)
				end
				local keyPath = parseKeyPath()
				skipHorizontalWs()
				if peek() ~= "=" then
					fail("expected '=' after key in inline table")
				end
				advance(1)
				skipHorizontalWs()
				local val = parseValue()

				local target = tbl
				for i = 1, #keyPath - 1 do
					local seg = keyPath[i]
					if target[seg] == nil then
						target[seg] = {}
						assignedKeys[target[seg]] = {}
					elseif type(target[seg]) ~= "table" then
						fail("cannot index non-table key '" .. seg .. "'")
					end
					target = target[seg]
				end

				local leaf = keyPath[#keyPath]
				assignedKeys[target] = assignedKeys[target] or {}
				if target[leaf] ~= nil or assignedKeys[target][leaf] then
					fail("duplicate key '" .. leaf .. "' in inline table")
				end
				target[leaf] = val
				assignedKeys[target][leaf] = true

				skipHorizontalWs()
				local ch = peek()
				if ch == "," then
					advance(1)
				elseif ch == "}" then
					advance(1)
					return tbl
				else
					fail("expected ',' or '}' in inline table")
				end
			end
		end

		local function parseNumberOrBool()
			local token = input:match("^[^%s,#%]%}]+", pos)
			if not token then
				fail("expected value")
			end

			if token == "true" then
				pos = pos + 4
				return true
			elseif token == "false" then
				pos = pos + 5
				return false
			end

			-- Strip valid underscores between digits
			if token:find("__", 1, true) or token:match("^_") or token:match("_$") then
				fail("invalid number '" .. token .. "'")
			end
			local cleaned = token:gsub("_", "")

			-- Hex / octal / binary integers
			if cleaned:match("^0x[0-9A-Fa-f]+$") then
				pos = pos + #token
				return tonumber(cleaned)
			elseif cleaned:match("^0o[0-7]+$") then
				pos = pos + #token
				return tonumber(cleaned:sub(3), 8)
			elseif cleaned:match("^0b[01]+$") then
				pos = pos + #token
				return tonumber(cleaned:sub(3), 2)
			end

			-- Standard integer or float
			if cleaned:match("^[%+%-]?%d+$") or
			   cleaned:match("^[%+%-]?%d+%.%d+$") or
			   cleaned:match("^[%+%-]?%d+%.?%d*[eE][%+%-]?%d+$") then
				local num = tonumber(cleaned)
				if num == nil then
					fail("invalid number '" .. token .. "'")
				end
				pos = pos + #token
				return num
			end

			fail(string.format("invalid value '%s' (strings must be quoted with \"...\")", token))
		end

		parseValue = function()
			skipHorizontalWs()
			local ch = peek()
			if ch == "" or ch == "\n" or ch == "#" then
				fail("missing value after '='")
			elseif ch == '"' then
				return parseBasicString()
			elseif ch == "'" then
				return parseLiteralString()
			elseif ch == "[" then
				return parseArray()
			elseif ch == "{" then
				return parseInlineTable()
			else
				return parseNumberOrBool()
			end
		end

		local function navigateTableHeader(keyPath, isArrayTable)
			local target = root
			for i = 1, #keyPath - 1 do
				local seg = keyPath[i]
				local nextVal = target[seg]
				if nextVal == nil then
					nextVal = {}
					target[seg] = nextVal
					assignedKeys[nextVal] = {}
				elseif type(nextVal) ~= "table" then
					fail("key '" .. seg .. "' already defined as a non-table value")
				elseif arrayTables[nextVal] then
					nextVal = nextVal[#nextVal]
				end
				target = nextVal
			end

			local leaf = keyPath[#keyPath]
			if isArrayTable then
				local arr = target[leaf]
				if arr == nil then
					arr = {}
					arrayTables[arr] = true
					target[leaf] = arr
				elseif type(arr) ~= "table" or not arrayTables[arr] then
					fail("cannot redefine table '" .. leaf .. "' as array of tables '[[' .. leaf .. ']]'")
				end
				local entry = {}
				assignedKeys[entry] = {}
				table.insert(arr, entry)
				return entry
			else
				local tbl = target[leaf]
				if tbl == nil then
					tbl = {}
					assignedKeys[tbl] = {}
					definedTables[tbl] = true
					target[leaf] = tbl
				elseif type(tbl) ~= "table" or arrayTables[tbl] then
					fail("cannot redefine '" .. leaf .. "' as a standard table")
				elseif definedTables[tbl] then
					fail("duplicate table header '[" .. table.concat(keyPath, ".") .. "]'")
				else
					definedTables[tbl] = true
				end
				return tbl
			end
		end

		local function assignKeyValue(baseTable, keyPath, val)
			local target = baseTable
			for i = 1, #keyPath - 1 do
				local seg = keyPath[i]
				local nextVal = target[seg]
				if nextVal == nil then
					nextVal = {}
					assignedKeys[nextVal] = {}
					target[seg] = nextVal
				elseif type(nextVal) ~= "table" or arrayTables[nextVal] then
					fail("cannot assign dotted key through '" .. seg .. "'")
				end
				target = nextVal
			end

			local leaf = keyPath[#keyPath]
			assignedKeys[target] = assignedKeys[target] or {}
			if target[leaf] ~= nil or assignedKeys[target][leaf] then
				fail("duplicate key '" .. leaf .. "'")
			end
			target[leaf] = val
			assignedKeys[target][leaf] = true
		end

		local ok, err = pcall(function()
			assignedKeys[root] = {}

			while pos <= len do
				skipWsAndComments(true)
				if pos > len then
					break
				end

				if peek() == "[" then
					local isArrayTable = (input:sub(pos, pos + 1) == "[[")
					if isArrayTable then
						advance(2)
					else
						advance(1)
					end

					local keyPath = parseKeyPath()
					skipHorizontalWs()

					if isArrayTable then
						if input:sub(pos, pos + 1) ~= "]]" then
							fail("expected closing ']]' for array of tables header")
						end
						advance(2)
					else
						if peek() ~= "]" then
							fail("expected closing ']' for table header")
						end
						advance(1)
					end

					currentTable = navigateTableHeader(keyPath, isArrayTable)
				else
					local keyPath = parseKeyPath()
					skipHorizontalWs()
					if peek() ~= "=" then
						fail("expected '=' after key '" .. table.concat(keyPath, ".") .. "'")
					end
					advance(1)
					local val = parseValue()
					assignKeyValue(currentTable, keyPath, val)
				end

				skipHorizontalWs()
				skipComment()
				if pos <= len then
					if peek() == "\n" then
						advance(1)
					else
						fail("unexpected trailing characters '" .. peek() .. "' at end of line")
					end
				end
			end
		end)

		if not ok then
			if type(err) == "table" then
				return nil, err.msg, err.line
			end
			return nil, tostring(err), line
		end

		return root
	end
