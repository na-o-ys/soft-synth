BIN      := $(HOME)/.local/bin/soft-synth
LABEL    := local.$(USER).soft-synth
PLIST    := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG      := $(HOME)/Library/Logs/soft-synth.log
CONFIG_DIR := $(HOME)/.config/soft-synth
CONFIG   ?= config.example.json

.PHONY: build demo install uninstall restart log monitor

build:
	mkdir -p build
	swiftc -O -swift-version 5 Sources/*.swift -o build/soft-synth \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
	codesign -s - -f -i local.soft-synth build/soft-synth

demo: build
	./build/soft-synth --demo

install: build
	mkdir -p $(dir $(BIN))
	cp build/soft-synth $(BIN)
	mkdir -p $(CONFIG_DIR)
	@test -f $(CONFIG_DIR)/config.json || { cp $(CONFIG) $(CONFIG_DIR)/config.json && echo "config: $(CONFIG) -> $(CONFIG_DIR)/config.json"; }
	sed -e 's|@BIN@|$(BIN)|' -e 's|@LABEL@|$(LABEL)|' -e 's|@LOG@|$(LOG)|' launchd.plist.in > $(PLIST)
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(PLIST)
	@echo "installed: $(LABEL) (log: $(LOG))"

uninstall:
	-launchctl bootout gui/$$(id -u)/$(LABEL)
	rm -f $(PLIST) $(BIN)

restart:
	launchctl kickstart -k gui/$$(id -u)/$(LABEL)

log:
	tail -f $(LOG)

monitor: build
	./build/soft-synth --monitor
