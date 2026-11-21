--
-- tests/base/test_init_wizard.lua
-- Automated tests for directory scanning, staged TOML skeletons,
-- interactive editor retry/skip flow, and real Premake baking of emitted premake5.lua.
--

	local suite = test.declare("base_init_wizard")
	local p = premake
	local init = p.init
	local real_io_open = io.open

	local tmpRoot


	function suite.setup()
		io.open = real_io_open
		p.api.reset()
		tmpRoot = path.join(os.getcwd(), ".tmp_init_wizard_test_" .. tostring(math.random(100000, 999999)))
		os.mkdir(tmpRoot)
	end


	function suite.teardown()
		if tmpRoot and os.isdir(tmpRoot) then
			os.rmdir(tmpRoot)
		end
	end


	function suite.scanner_emptyDirProducesBlankStep1Defaults()
		io.writefile(path.join(tmpRoot, "README.md"), "# Not a C/C++ file\n")
		local scan = init.scanner.scanDirectory(tmpRoot)
		test.isfalse(scan.found)

		local step1Text = init.steps.renderStep1(scan)
		local parsed, err = p.toml.parse(step1Text)
		test.isnil(err)
		test.isequal("", parsed.workspace.name)
		test.isequal("", parsed.workspace.build_dir)
		test.isequal({}, parsed.workspace.modes)
		test.isequal({}, parsed.workspace.archs)
		test.isequal(1, #parsed.targets)
		test.isequal("", parsed.targets[1].name)
		test.isequal("", parsed.targets[1].type)
		test.isequal("", parsed.targets[1].lang)
		test.isequal({}, parsed.targets[1].sources)
		test.isequal({}, parsed.targets[1].includes)
	end


	function suite.scanner_detectsCppVariantsAndBuildsGlobs()
		io.writefile(path.join(tmpRoot, "src/main.cc"), "int main() { return 0; }\n")
		io.writefile(path.join(tmpRoot, "src/detail/helper.C"), "int helper() { return 1; }\n")
		io.writefile(path.join(tmpRoot, "include/myproj/helper.hpp"), "#pragma once\nint helper();\n")
		-- Files inside ignored build/ directory must not pollute globs
		io.writefile(path.join(tmpRoot, "build/generated.cpp"), "int ignored = 0;\n")

		local scan = init.scanner.scanDirectory(tmpRoot)
		test.istrue(scan.found)
		test.isequal(2, scan.sourceCount)
		test.isequal(1, scan.headerCount)
		test.isequal("exe", scan.targetType)
		test.isequal("c++20", scan.lang)
		test.isequal({ "include/**.hpp", "src/**.C", "src/**.cc" }, scan.sources)
		test.isequal({ "include" }, scan.includes)
	end


	function suite.steps2To4_renderStrictBlankDefaults()
		local step1Parsed = p.toml.parse([=[
[workspace]
name = "BlankTest"
modes = ["debug", "release"]
archs = ["x86_64"]

[[targets]]
name = "mylib"
type = "static_lib"
lang = "c17"
sources = ["lib/**.c"]
includes = ["lib"]

[[targets]]
name = "myapp"
type = "exe"
lang = "c++20"
sources = ["src/**.cpp"]
includes = ["src"]
]=])
		local s1, errs1 = init.steps.validateStep1(step1Parsed)
		test.isnil(errs1)

		local s2Raw, e2 = p.toml.parse(init.steps.renderStep2(s1))
		test.isnil(e2)
		test.isequal({}, s2Raw.exports.mylib.public_includes)
		test.isequal({}, s2Raw.deps.myapp.links)
		local s2, v2 = init.steps.validateStep2(s2Raw, s1)
		test.isnil(v2)
		test.isnotnil(s2)

		local s3Raw, e3 = p.toml.parse(init.steps.renderStep3(s1))
		test.isnil(e3)
		test.isequal("", s3Raw.compiler.warnings)
		test.isfalse(s3Raw.compiler.warnings_as_errors)
		test.isequal({}, s3Raw.platform.linux.defines)
		local s3, v3 = init.steps.validateStep3(s3Raw, s1)
		test.isnil(v3)
		test.isnotnil(s3)

		local s4Raw, e4 = p.toml.parse(init.steps.renderStep4(s1))
		test.isnil(e4)
		test.isnil(s4Raw.debug.mylib) -- static_lib excluded from [debug.*]
		test.isequal("", s4Raw.debug.myapp.working_dir)
		test.isequal({}, s4Raw.hooks.myapp.post_build)
		local s4, v4 = init.steps.validateStep4(s4Raw, s1)
		test.isnil(v4)
		test.isnotnil(s4)
	end


	function suite.wizard_endToEndEmitsValidPremakeAndBakesCleanly()
		io.writefile(path.join(tmpRoot, "libs/math/add.cpp"), "int add(int a, int b) { return a + b; }\n")
		io.writefile(path.join(tmpRoot, "libs/math/include/add.hpp"), "#pragma once\nint add(int a, int b);\n")
		io.writefile(path.join(tmpRoot, "src/main.cpp"), "#include \"add.hpp\"\nint main() { return add(1, 2) - 3; }\n")

		-- Simulate interactive answers:
		-- 1) Step 2? "y"
		-- 2) Step 3? "y"
		-- 3) Step 4? "n" (skip Step 4!)
		-- 4) Backend prompt: "" (skip here; we bake & validate directly below)
		local answers = { "y", "y", "n", "" }
		local ansIdx = 0
		local function mockPromptReader()
			ansIdx = ansIdx + 1
			return answers[ansIdx] or ""
		end

		local editorCalls = 0
		local function mockEditorRunner(_, filePath)
			editorCalls = editorCalls + 1
			if filePath:find("step1", 1, true) then
				-- Verify scanner pre-populated C++ files before replacing with 2-target config
				local initial = io.readfile(filePath)
				test.istrue(initial:find("libs/**.cpp", 1, true) ~= nil)
				io.writefile(filePath, [=[
[workspace]
name = "CalcWorkspace"
build_dir = "build"
modes = ["debug", "release"]
archs = ["x86_64"]

[[targets]]
name = "math_lib"
type = "static_lib"
lang = "c++20"
sources = ["libs/math/**.cpp", "libs/math/**.hpp"]
includes = ["libs/math/include"]

[[targets]]
name = "calc_app"
type = "exe"
lang = "c++20"
sources = ["src/**.cpp"]
includes = ["src"]
]=])
			elseif filePath:find("step2", 1, true) then
				io.writefile(filePath, [[
[exports.math_lib]
public_includes = ["libs/math/include"]
public_defines = ["USE_FAST_MATH=1"]

[deps.calc_app]
links = ["math_lib"]
linux_links = ["m"]
]])
			elseif filePath:find("step3", 1, true) then
				io.writefile(filePath, [[
[compiler]
warnings = "extra"
warnings_as_errors = true
lto_in_release = true
]])
			end
			return true
		end

		local ok, outFile = init.runWizard({
			workDir      = tmpRoot,
			force        = true,
			promptReader = mockPromptReader,
			editorRunner = mockEditorRunner,
		})

		test.istrue(ok)
		test.isequal(3, editorCalls) -- Step 4 was skipped as requested
		test.istrue(os.isfile(outFile))

		-- Execute the generated premake5.lua and run Premake's real Oven + Validator
		p.api.reset()
		p.action.set("gmake")
		local prevDir = os.getcwd()
		os.chdir(tmpRoot)
		dofile(outFile)
		os.chdir(prevDir)

		p.oven.bake()
		p.container.validate(p.api.rootContainer())

		local wks = p.global.getWorkspace("CalcWorkspace")
		test.isnotnil(wks)
		local appPrj = p.workspace.findproject(wks, "calc_app")
		test.isnotnil(appPrj)
		test.isequal("ConsoleApp", appPrj.kind)
		test.isequal("C++", appPrj.language)

		local dbgCfg = p.project.getconfig(appPrj, "Debug", "x86_64")
		test.isnotnil(dbgCfg)
		test.isequal("C++20", dbgCfg.cppdialect)
		test.isequal("Extra", dbgCfg.warnings)
		test.istrue(table.contains(dbgCfg.defines, "USE_FAST_MATH=1"))
		test.istrue(table.contains(dbgCfg.includedirs, path.join(tmpRoot, "libs/math/include")))
	end


	function suite.blankConfig_skipsInteractiveAndRoundTripsToBackend()
		-- Generate blank template even when C++ files exist (must NOT auto-populate)
		io.writefile(path.join(tmpRoot, "src/main.cpp"), "int main() { return 0; }\n")

		local okBlank, blankPath = init.writeBlankConfig({
			workDir        = tmpRoot,
			force          = true,
			nonInteractive = true,
		})
		test.istrue(okBlank)
		test.istrue(os.isfile(blankPath))

		local blankRaw = io.readfile(blankPath)
		local blankParsed, parseErr = p.toml.parse(blankRaw)
		test.isnil(parseErr)
		test.isequal("", blankParsed.workspace.name)
		test.isequal({}, blankParsed.workspace.modes)
		test.isequal("", blankParsed.targets[1].name)
		test.isequal("", blankParsed.targets[1].type)
		test.isequal("", blankParsed.targets[1].lang)
		test.isequal({}, blankParsed.targets[1].sources)
		test.isequal({}, blankParsed.targets[1].links)
		test.isfalse(blankParsed.compiler.warnings_as_errors)

		-- Unfilled blank template must fail validation cleanly on required fields
		local invalidState, valErrs = init.steps.validateUnifiedToml(blankParsed)
		test.isnil(invalidState)
		test.istrue(#valErrs >= 4)

		-- Fill ONLY the required fields + a couple optional fields in premake.toml
		local edited = blankRaw
			:gsub('name = ""', 'name = "BlankDemo"', 1)
			:gsub('name    = ""', 'name    = "demo_bin"', 1)
			:gsub('type    = ""', 'type    = "exe"', 1)
			:gsub('lang    = ""', 'lang    = "c++17"', 1)
			:gsub('sources = %[%]', 'sources = ["src/**.cpp"]', 1)
			:gsub('warnings           = ""', 'warnings           = "high"', 1)
		io.writefile(blankPath, edited)

		local okGen, luaPath = init.generateFromToml(blankPath, {
			workDir     = tmpRoot,
			skipBackend = true,
		})
		test.istrue(okGen)
		test.istrue(os.isfile(luaPath))

		p.api.reset()
		p.action.set("gmake")
		local prevDir = os.getcwd()
		os.chdir(tmpRoot)
		dofile(luaPath)
		os.chdir(prevDir)

		p.oven.bake()
		p.container.validate(p.api.rootContainer())

		local wks = p.global.getWorkspace("BlankDemo")
		test.isnotnil(wks)
		local prj = p.workspace.findproject(wks, "demo_bin")
		test.isnotnil(prj)
		local cfg = p.project.getconfig(prj, "Debug", "x86_64")
		test.isequal("C++17", cfg.cppdialect)
		test.isequal("High", cfg.warnings)
	end


	function suite.buildscan_importsCMakeOptionalFieldsEvenWhenWizardSkipsOptionalEditors()
		io.writefile(path.join(tmpRoot, "CMakeLists.txt"), [=[
cmake_minimum_required(VERSION 3.16)
project(EngineSuite)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_EXTENSIONS OFF)
add_compile_definitions(GLOBAL_FEATURE=1)
add_subdirectory(math)

add_executable(game_app src/main.cpp)
target_include_directories(game_app PRIVATE src SYSTEM vendor/inc)
target_compile_options(game_app PRIVATE -Werror -Wextra -fno-rtti)
target_link_libraries(game_app PRIVATE mathlib pthread)
]=])
		io.writefile(path.join(tmpRoot, "math/CMakeLists.txt"), [=[
add_library(mathlib STATIC vec.cpp)
target_include_directories(mathlib PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_definitions(mathlib PUBLIC MATH_SIMD=1)
]=])
		io.writefile(path.join(tmpRoot, "math/vec.cpp"), "int vec() { return 1; }\n")
		io.writefile(path.join(tmpRoot, "math/include/vec.hpp"), "#pragma once\nint vec();\n")
		io.writefile(path.join(tmpRoot, "src/main.cpp"), "int main() { return 0; }\n")
		os.mkdir(path.join(tmpRoot, "vendor/inc"))

		-- Answer "n" to all optional editor prompts (Steps 2, 3, 4) and "" to backend prompt:
		-- imported optional fields must STILL be automatically accepted!
		local answers = { "n", "n", "n", "" }
		local idx = 0
		local editorCalls = 0

		local ok, luaPath = init.runWizard({
			workDir      = tmpRoot,
			force        = true,
			promptReader = function() idx = idx + 1; return answers[idx] or "" end,
			editorRunner = function() editorCalls = editorCalls + 1; return true end,
		})

		test.istrue(ok)
		test.isequal(1, editorCalls) -- Only Step 1 editor opened!

		p.api.reset()
		p.action.set("gmake")
		local prevDir = os.getcwd()
		os.chdir(tmpRoot)
		dofile(luaPath)
		os.chdir(prevDir)

		p.oven.bake()
		p.container.validate(p.api.rootContainer())

		local wks = p.global.getWorkspace("EngineSuite")
		test.isnotnil(wks)
		local appPrj = p.workspace.findproject(wks, "game_app")
		test.isnotnil(appPrj)
		local cfg = p.project.getconfig(appPrj, "Debug", "x86_64")
		test.isequal("C++17", cfg.cppdialect)
		test.istrue(table.contains(cfg.defines, "GLOBAL_FEATURE=1"))
		test.istrue(table.contains(cfg.defines, "MATH_SIMD=1")) -- inherited via PUBLIC export!
		test.istrue(table.contains(cfg.links, "mathlib"))
		test.istrue(table.contains(cfg.links, "pthread"))
		test.istrue(table.contains(cfg.includedirs, path.join(tmpRoot, "math/include")))
		test.istrue(table.contains(cfg.externalincludedirs, path.join(tmpRoot, "vendor/inc")))
	end


	function suite.buildscan_importsMakefileDefinesDialectAndLibs()
		io.writefile(path.join(tmpRoot, "foo.c"), "int main(void) { return 0; }\n")
		io.writefile(path.join(tmpRoot, "util.c"), "int util(void) { return 1; }\n")
		io.writefile(path.join(tmpRoot, "unused_win32.c"), "#error should not be included\n")
		io.writefile(path.join(tmpRoot, "Makefile"), [=[
CC = clang
CFLAGS = -std=gnu99 -O2 -Wall -W -Wno-unused-parameter
CPPFLAGS = -DAPP_VERSION='"1.2.3"' -D_GNU_SOURCE -I.
LIBS = -lm -lpthread
OBJS = foo.o util.o

mytool: $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LIBS)
]=])

		local okToml, tomlPath = init.importExistingBuild({
			workDir  = tmpRoot,
			emitToml = true,
			force    = true,
		})
		test.istrue(okToml)

		local okLua, luaPath = init.generateFromToml(tomlPath, {
			workDir     = tmpRoot,
			skipBackend = true,
		})
		test.istrue(okLua)

		p.api.reset()
		p.action.set("gmake")
		local prevDir = os.getcwd()
		os.chdir(tmpRoot)
		dofile(luaPath)
		os.chdir(prevDir)

		p.oven.bake()
		p.container.validate(p.api.rootContainer())

		local wks = p.global.getWorkspace("mytool")
		test.isnotnil(wks)
		local prj = p.workspace.findproject(wks, "mytool")
		test.isnotnil(prj)
		local cfg = p.project.getconfig(prj, "Release", "x86_64")
		test.isequal("gnu99", cfg.cdialect)
		test.isequal("Extra", cfg.warnings)
		test.istrue(table.contains(cfg.defines, 'APP_VERSION="1.2.3"'))
		test.istrue(table.contains(cfg.defines, "_GNU_SOURCE"))
		test.istrue(table.contains(cfg.links, "m"))
		test.istrue(table.contains(cfg.links, "pthread"))
		test.isequal(2, #cfg.files) -- exact 2 .c files from OBJS, NOT unused_win32.c!
	end
