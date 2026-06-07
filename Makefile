LUA  ?= lua
LUAC ?= luac
SRC  := init.lua menubar.lua pill.lua rightclick.lua images.lua backends/spotify.lua backends/applemusic.lua

.PHONY: all test check update

all: test

# Pull the latest commit for this Spoon (fast-forward only).
update:
	@git pull --ff-only

# Syntax-check every Lua source file.
check:
	@for f in $(SRC); do $(LUAC) -p $$f && echo "luac OK: $$f"; done

# Syntax-check, then run the unit suite for the pure logic layer.
test: check
	@$(LUA) tests/run.lua
