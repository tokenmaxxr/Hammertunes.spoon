LUA  ?= lua
LUAC ?= luac
SRC  := $(wildcard *.lua backends/*.lua backends/*/*.lua)

.PHONY: all test check update

all: test

# Pull the latest commit for this Spoon (fast-forward only).
update:
	@git pull --ff-only

# Syntax-check every Lua source file.
check:
	@for f in $(SRC); do $(LUAC) -p "$$f" || exit $$?; echo "luac OK: $$f"; done

# Syntax-check, then run the unit suite.
test: check
	@$(LUA) tests/run.lua
