SWIFTC ?= swiftc
SWIFTFLAGS ?= -O

all: drift_gui drift

drift_gui: drift_gui.swift
	$(SWIFTC) $(SWIFTFLAGS) drift_gui.swift -o drift_gui

drift: drift.swift
	$(SWIFTC) $(SWIFTFLAGS) drift.swift -o drift

run: drift_gui
	./drift_gui

clean:
	rm -f drift_gui drift

.PHONY: all run clean
