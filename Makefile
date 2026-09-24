BIN      := $(HOME)/.local/bin/soft-synth
LABEL    := local.$(USER).soft-synth
PLIST    := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG      := $(HOME)/Library/Logs/soft-synth.log

.PHONY: build demo install uninstall restart log

build:
	mkdir -p build
	swiftc -O -swift-version 5 Sources/main.swift -o build/soft-synth

demo: build
	./build/soft-synth --demo

install: build
	mkdir -p $(dir $(BIN))
	cp build/soft-synth $(BIN)
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
