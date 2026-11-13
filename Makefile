PREFIX ?= /usr/local
SWIFTC ?= swiftc
DEPLOY ?= $(shell uname -m)-apple-macos13.0
SWIFTFLAGS ?= -O -swift-version 5 -target $(DEPLOY)

# 两个命令行工具，都由 eclose 模块构建：jpeg2heif 转 JPEG，raw2heif 转相机 RAW。
CLIS := jpeg2heif raw2heif
# 应用的名字（应用包名、Info.plist 的 CFBundleName / CFBundleDisplayName 都由它来）。
# 改名只改这里和 Sources/GUI/AppName.swift。可执行文件名 Glint 和标识符 local.minxu.glint
# 写在 Info.plist 里，改名时不动（用户设置跟着标识符走，不用迁）。
APP_NAME := Glint
APP  := $(APP_NAME).app
ECLOSE := $(wildcard Sources/Eclose/*.swift)
# 两个命令共用的源码；各自的入口在 Sources/CLI/<命令>/main.swift。
CLI_SHARED := $(wildcard Sources/CLI/*.swift)
# GUI_MODEL 是界面里不依赖 AppKit 的模型层，Tests/guimodel 直接链它。
# GUI_LIB 是界面代码里不含入口的部分，截图工具要用自己的 main。
GUI_MODEL := Sources/GUI/Model.swift Sources/GUI/PhotoInfo.swift Sources/GUI/Library.swift \
             Sources/GUI/ConversionRecord.swift Sources/GUI/Settings.swift Sources/GUI/AppName.swift
GUI_VIEWS := $(filter-out Sources/GUI/main.swift $(GUI_MODEL),$(wildcard Sources/GUI/*.swift))
GUI_LIB   := $(GUI_VIEWS) $(GUI_MODEL)
GUI       := Sources/GUI/main.swift $(GUI_LIB)

# 转换模块 eclose（羽化）编成真正的 Swift 模块 Eclose：一个静态库加 .swiftmodule，
# 命令行、应用和测试工具都 `import Eclose` 链它。编两份，都放在 build/ 下：
#   build/release  命令行、应用、截图工具链这一份。它们只看得见 public 的东西，
#                  公开面够不够用由它们能不能编过来证明。
#   build/testing  多一个 -enable-testing，测试工具 `@testable import Eclose` 用它，
#                  好直接断言 internal 的规则函数。
# 为什么不让测试工具继续直接编 Eclose 的源码：那样命令行里的 Arguments.swift（它要
# `import Eclose`）就链不进单测了。为什么不只编一份带 -enable-testing 的：交付出去的
# 命令和应用不该链一份为测试放开了 internal 符号的库。
ECLOSE_RELEASE := build/release/libEclose.a
ECLOSE_TESTING := build/testing/libEclose.a

.PHONY: all cli app icon install install-cli install-dev uninstall test run snapshot clean \
        print-artifacts

all: cli app

cli: $(CLIS)
app: $(APP)

# 同一份 Eclose 源码，$(1) 是额外的编译标志。库和 .swiftmodule 一次编出来，放在目标库旁边。
define build-eclose
	@mkdir -p $(dir $@)
	$(SWIFTC) $(SWIFTFLAGS) $(1) -parse-as-library -module-name Eclose -emit-library -static \
	    -emit-module -emit-module-path $(dir $@)Eclose.swiftmodule -o $@ $(ECLOSE)
endef

$(ECLOSE_RELEASE): $(ECLOSE)
	$(call build-eclose,)

$(ECLOSE_TESTING): $(ECLOSE)
	$(call build-eclose,-enable-testing)

# 链 Eclose 的产物把库本身当输入交给 swiftc（它认 .a，直接拿去链接），-I 指向
# .swiftmodule 所在的目录。库写在依赖里，所以 $^ 里就有它：改了 Eclose 源码 →
# 库重建 → 依赖它的产物全部重建。
eclose-flags = -I $(dir $(filter %/libEclose.a,$^))

$(CLIS): %: $(ECLOSE_RELEASE) $(CLI_SHARED) Sources/CLI/%/main.swift
	$(SWIFTC) $(SWIFTFLAGS) $(eclose-flags) -o $@ $^

ICONS := Resources/AppIcon.icns Resources/AppIcon-Gradient.icns

$(APP): $(ECLOSE_RELEASE) $(GUI) Sources/GUI/Info.plist $(ICONS)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	$(SWIFTC) $(SWIFTFLAGS) $(eclose-flags) -o $(APP)/Contents/MacOS/Glint $(ECLOSE_RELEASE) $(GUI)
	@cp Sources/GUI/Info.plist $(APP)/Contents/Info.plist
	@cp $(ICONS) $(APP)/Contents/Resources/
	@plutil -insert CFBundleName -string '$(APP_NAME)' $(APP)/Contents/Info.plist
	@plutil -insert CFBundleDisplayName -string '$(APP_NAME)' $(APP)/Contents/Info.plist
	@# 应用里选过别的图标时，应用包根目录有自定义图标（Icon\r 和 FinderInfo），签名前去掉
	@rm -f $(APP)/Icon?; xattr -d com.apple.FinderInfo $(APP) 2>/dev/null || true
	@codesign --force --sign - $(APP) 2>/dev/null || true
	@touch $(APP)
	@echo "已生成 $(APP)"

# 重新生成应用图标（Resources/ 下的产物已提交，平时不用跑）。
icon:
	$(SWIFTC) -O Tools/make_icon.swift -o .make_icon && ./.make_icon Resources && rm -f .make_icon

run: $(APP)
	open $(APP)

# 应用不往 /Applications 装，只用 install-dev 放进 ~/Developer；install 只装命令行。
install: install-cli

install-cli: $(CLIS)
	install -d $(PREFIX)/bin
	install -m 755 $(CLIS) $(PREFIX)/bin/
	@echo "命令行工具已装到 $(PREFIX)/bin/：$(CLIS)"

# 在仓库的上一级目录（~/Developer）放一份应用，和那里的 Spark.app 一样随手能点开。
# 是独立的一份拷贝，make clean 不会碰它；改了界面代码后重跑一次才会更新。
install-dev: $(APP)
	rm -rf ../$(APP)
	cp -R $(APP) ../
	@echo "应用已放到 $(abspath ..)/$(APP)"

uninstall:
	rm -f $(addprefix $(PREFIX)/bin/,$(CLIS))

# 测试工具一律按同一条规则构建：目标依赖它链的那一份 Eclose 库（ECLOSE_LIB），
# 各自的额外源码写在 TOOL_SRC 里。加一个工具只改这一处。
#
# TOOL_SRC 和 ECLOSE_LIB 既是依赖又是编译器的输入，所以只写一遍：.SECONDEXPANSION
# 让依赖列表里的 $$(…) 推迟到目标自身的上下文中展开，配方再用 $^ 把同一份清单喂给
# 编译器。写两遍的话只改一处就会出现「改了源码却不重建」或者「重建了却没编进去」。
.SECONDEXPANSION:

TEST_TOOLS := Tests/probe Tests/uisnapshot Tests/unit-test \
              Tests/guimodel-test Tests/mangle-tool

# 测的是内部规则的工具链测试版（@testable import Eclose）。
Tests/probe:         ECLOSE_LIB := $(ECLOSE_TESTING)
Tests/probe:         TOOL_SRC := Tests/probe-src/main.swift
# 截图工具复用真实的窗口代码离屏渲染成 PNG，无需屏幕录制权限。它和应用一样链
# 发行版、只用 public 的东西：界面代码用到的公开面不够时，这里先编不过。
Tests/uisnapshot:    ECLOSE_LIB := $(ECLOSE_RELEASE)
Tests/uisnapshot:    TOOL_SRC := $(GUI_LIB) Tests/snapshot/main.swift
# 单元测试把界面的 Model 一并链进来（它只依赖 Foundation），
# 好断言命令行与界面的默认值没跑偏。
Tests/unit-test:     ECLOSE_LIB := $(ECLOSE_TESTING)
Tests/unit-test:     TOOL_SRC := Sources/GUI/Model.swift Sources/CLI/Arguments.swift \
                                  Tests/harness.swift Tests/DNG.swift Tests/unit/main.swift
# 界面模型的测试：只需 Eclose + 模型层（都不依赖 AppKit）。
Tests/guimodel-test: ECLOSE_LIB := $(ECLOSE_TESTING)
Tests/guimodel-test: TOOL_SRC := $(GUI_MODEL) Tests/harness.swift Tests/DNG.swift Tests/guimodel/main.swift \
                                  Tests/guimodel/browsing.swift Tests/guimodel/raw.swift
Tests/mangle-tool:   ECLOSE_LIB := $(ECLOSE_TESTING)
Tests/mangle-tool:   TOOL_SRC := Tests/mangle/main.swift

$(TEST_TOOLS): $$(ECLOSE_LIB) $$(TOOL_SRC)
	$(SWIFTC) $(SWIFTFLAGS) $(eclose-flags) -o $@ $^

# 夹具不需要 Eclose，单独一条。DNG.swift 是现场生成 DNG 的那一段，单测也链它。
Tests/fixture: Tests/fixture-src/main.swift Tests/DNG.swift
	$(SWIFTC) $(SWIFTFLAGS) -o $@ $^

snapshot: Tests/uisnapshot
	./Tests/uisnapshot $(or $(OUT),/tmp/glint-ui.png) $(ARGS)

# 「跑一遍自检需要哪些产物」只定义一处：test 的前置和 selftest.sh 的新鲜度
# 守卫都从这里取。
ARTIFACTS := $(CLIS) Tests/fixture $(TEST_TOOLS)

# selftest.sh 用它来问「该检查哪些产物」，免得在脚本里抄一份。
print-artifacts:
	@echo $(ARTIFACTS)

test: $(ARTIFACTS)
	@Tests/selftest.sh

clean:
	rm -rf $(CLIS) $(APP) build Tests/fixture $(TEST_TOOLS) Tests/.work*
