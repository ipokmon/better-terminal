# Better Terminal build. SwiftPM output goes to .build/, the app bundle to build/ (both git-ignored).
VERSION  := $(shell cat VERSION)
APP      := build/Better Terminal.app
BIN      := .build/release/BetterTerminal
INSTALL  := $(HOME)/Applications
# Command Line Tools only (no Xcode): name the swift-testing macro plugin explicitly, or test builds
# fail on every other run with "plugin for module 'TestingMacros' not found".
TESTING_PLUGIN := $(shell xcrun --find swift | sed 's|/bin/swift$$||')/lib/swift/host/plugins/testing/libTestingMacros.dylib

.PHONY: all test selftest gate paste-probe check-windows app install icon clean
all: app

test:
	swift test -Xswiftc -load-plugin-library -Xswiftc "$(TESTING_PLUGIN)"
	swift build --product bt-selftest && .build/debug/bt-selftest

# Real zsh through the real pane model; renders the bubble thread to build/selftest.png, then an
# off-screen window with split panes, focus moves, a theme, and pane/window/classic screenshots.
selftest: $(BIN)
	@mkdir -p build && $(BIN) --render-selftest build/selftest.png
	$(BIN) --window-selftest build

# Real ⌘V + Return in the compose bar, incl. focus on bubble text. Uses the system clipboard:
# saves it first and restores it afterwards.
paste-probe: $(BIN)
	$(BIN) --paste-probe

# File > New Window and New Tab through the real menus of the real app (a window flashes up, ~5 s).
check-windows: $(BIN)
	@BT_CHECK_NEW_WINDOW=1 $(BIN) 2>/dev/null | grep CHECK

# Launch gate T2–T7 (real zsh, a window on your screen; leaves no settings or history behind).
gate: $(BIN)
	$(BIN) --gate-tests

$(BIN): Package.swift $(wildcard Sources/*/*.swift) VERSION
	@grep -q 'string = "$(VERSION)"' Sources/BTCore/Session.swift || { echo "VERSION and BTVersion disagree"; exit 1; }
	swift build -c release --product BetterTerminal

app: $(BIN)
	rm -rf "$(APP)" && mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp $(BIN) "$(APP)/Contents/MacOS/BetterTerminal"
	sed 's/@VERSION@/$(VERSION)/g' Resources/Info.plist > "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --sign - --timestamp=none "$(APP)"
	@echo "built $(APP) $(VERSION)"

install: app
	mkdir -p "$(INSTALL)"
	rm -rf "$(INSTALL)/Better Terminal.app" && cp -R "$(APP)" "$(INSTALL)/"
	@touch "$(INSTALL)/Better Terminal.app" # nudge Finder/Dock to pick up a new icon
	@echo "installed $(INSTALL)/Better Terminal.app"

# Re-render Resources/AppIcon.icns from Resources/icon/MakeIcon.swift.
icon:
	@mkdir -p build/icon && swiftc -O -o build/icon/makeicon Resources/icon/MakeIcon.swift
	rm -rf build/icon/AppIcon.iconset && build/icon/makeicon build/icon/AppIcon.iconset
	iconutil -c icns build/icon/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	rm -rf build .build
