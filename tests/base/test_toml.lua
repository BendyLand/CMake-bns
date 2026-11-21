--
-- tests/base/test_toml.lua
-- Unit tests for Premake's pure-Lua TOML parser.
--

	local suite = test.declare("base_toml")
	local toml = premake.toml


	function suite.parsesTablesAndArraysOfTables()
		local doc = [=[
# Header comment
[workspace]
name = "Demo"
modes = ["debug", "release"] # inline comment

[[targets]]
name = "core-lib"
type = "static_lib"
sources = [
  "src/**.cpp",
  'include/**.hpp', # trailing comma
]

[[targets]]
name = "app"
type = "exe"
sources = ["main.cpp"]
]=]
		local parsed, err = toml.parse(doc)
		test.isnil(err)
		test.isequal("Demo", parsed.workspace.name)
		test.isequal({ "debug", "release" }, parsed.workspace.modes)
		test.isequal(2, #parsed.targets)
		test.isequal("core-lib", parsed.targets[1].name)
		test.isequal({ "src/**.cpp", "include/**.hpp" }, parsed.targets[1].sources)
		test.isequal("app", parsed.targets[2].name)
	end


	function suite.parsesDottedAndQuotedKeysAndBooleans()
		local doc = [[
[compiler]
warnings_as_errors = true
lto_in_release = false
count = 42

[deps."my.special.app"]
links = ["pthread", "dl"]
]]
		local parsed, err = toml.parse(doc)
		test.isnil(err)
		test.istrue(parsed.compiler.warnings_as_errors)
		test.isfalse(parsed.compiler.lto_in_release)
		test.isequal(42, parsed.compiler.count)
		test.isequal({ "pthread", "dl" }, parsed.deps["my.special.app"].links)
	end


	function suite.hasContentIgnoresCommentsAndWhitespace()
		test.isfalse(toml.hasContent(""))
		test.isfalse(toml.hasContent("   \n# comment only\n  # another\n"))
		test.istrue(toml.hasContent("# comment\n[workspace]\n"))
	end


	function suite.reportsLineNumberOnSyntaxError()
		local doc = "[workspace]\nname = \"ok\"\nbad_key = unquoted_word\n"
		local parsed, err, errLine = toml.parse(doc)
		test.isnil(parsed)
		test.isequal(3, errLine)
		test.istrue(err:find("line 3:", 1, true) ~= nil)
	end


	function suite.rejectsDuplicateKeys()
		local doc = "[workspace]\nname = \"a\"\nname = \"b\"\n"
		local parsed, err = toml.parse(doc)
		test.isnil(parsed)
		test.istrue(err:find("duplicate key", 1, true) ~= nil)
	end
