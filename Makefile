PREFIX ?= /usr/local
SWIFTC ?= swiftc
DEPLOY ?= $(shell uname -m)-apple-macos13.0
SWIFTFLAGS ?= -O -swift-version 5 -target $(DEPLOY)

BIN  := jpeg2heif
APP  := JPEG2HEIF.app
CORE := $(wildcard Sources/Core/*.swift)
CLI  := $(wildcard Sources/CLI/*.swift)
# GUI_LIB 是界面代码里不含入口的部分，截图工具要用自己的 main。
GUI_LIB := Sources/GUI/MainViewController.swift Sources/GUI/Views.swift Sources/GUI/Model.swift
GUI     := Sources/GUI/main.swift $(GUI_LIB)

.PHONY: all cli app install install-cli install-app uninstall test run snapshot clean \
        print-artifacts

all: cli app

cli: $(BIN)
app: $(APP)

$(BIN): $(CORE) $(CLI)
	$(SWIFTC) $(SWIFTFLAGS) -o $@ $(CORE) $(CLI)

$(APP): $(CORE) $(GUI) Sources/GUI/Info.plist
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	$(SWIFTC) $(SWIFTFLAGS) -o $(APP)/Contents/MacOS/JPEG2HEIF $(CORE) $(GUI)
	@cp Sources/GUI/Info.plist $(APP)/Contents/Info.plist
	@codesign --force --sign - $(APP) 2>/dev/null || true
	@touch $(APP)
	@echo "已生成 $(APP)"

run: $(APP)
	open $(APP)

install: install-cli install-app

install-cli: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/$(BIN)
	@echo "命令行工具已装到 $(PREFIX)/bin/$(BIN)"

install-app: $(APP)
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	@echo "应用已装到 /Applications/$(APP)"

uninstall:
	rm -f $(PREFIX)/bin/$(BIN)
	rm -rf /Applications/$(APP)

# 测试工具一律按同一条规则构建：目标依赖 $(CORE)，各自的额外源码写在
# TOOL_SRC 里。以前四条配方逐字重复、工具清单还在 test 和 clean 各抄一遍，
# 加一个工具要改三处。
#
# TOOL_SRC 既是依赖又是源码，所以只写一遍：.SECONDEXPANSION 让依赖列表里的
# $$(TOOL_SRC) 推迟到目标自身的上下文中展开，配方再用 $^ 把同一份清单喂给
# 编译器。以前这份清单写两遍（一遍当依赖、一遍当参数），只改一处就会出现
# 「改了源码却不重建」或者「重建了却没编进去」。
.SECONDEXPANSION:

TEST_TOOLS := Tests/probe Tests/uisnapshot Tests/unit-test \
              Tests/guimodel-test Tests/mangle-tool

Tests/probe:         TOOL_SRC := Tests/probe-src/main.swift
# 截图工具复用真实的窗口代码离屏渲染成 PNG，无需屏幕录制权限。
Tests/uisnapshot:    TOOL_SRC := $(GUI_LIB) Tests/snapshot/main.swift
# 单元测试把界面的 Model 一并链进来（它只依赖 Foundation），
# 好断言命令行与界面的默认值没跑偏。
Tests/unit-test:     TOOL_SRC := Sources/GUI/Model.swift Sources/CLI/Arguments.swift \
                                  Tests/harness.swift Tests/unit/main.swift
# 界面模型的集成测试：只需 Core + Model（都不依赖 AppKit）。
Tests/guimodel-test: TOOL_SRC := Sources/GUI/Model.swift Tests/harness.swift Tests/guimodel/main.swift
Tests/mangle-tool:   TOOL_SRC := Tests/mangle/main.swift

$(TEST_TOOLS): $(CORE) $$(TOOL_SRC)
	$(SWIFTC) $(SWIFTFLAGS) -o $@ $^

# 夹具不需要 Core，单独一条。
Tests/fixture: Tests/fixture.swift
	$(SWIFTC) $(SWIFTFLAGS) -o $@ $<

snapshot: Tests/uisnapshot
	./Tests/uisnapshot $(or $(OUT),/tmp/jpeg2heif-ui.png) $(ARGS)

# 「跑一遍自检需要哪些产物」只定义一处：test 的前置和 selftest.sh 的新鲜度
# 守卫都从这里取。上一版把它写了两遍（print-artifacts 的 echo 与 test 的前置），
# 注释却说"清单只在这里定义一份"——两行各自被改成不一致就没人发现了。
ARTIFACTS := $(BIN) Tests/fixture $(TEST_TOOLS)

# selftest.sh 用它来问「该检查哪些产物」，免得在脚本里抄一份。
print-artifacts:
	@echo $(ARTIFACTS)

test: $(ARTIFACTS)
	@Tests/selftest.sh

clean:
	rm -rf $(BIN) $(APP) Tests/fixture $(TEST_TOOLS) Tests/.work
