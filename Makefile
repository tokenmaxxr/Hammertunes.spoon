LUA  ?= lua
LUAC ?= luac
SRC  := init.lua pill.lua badge.lua backends/spotify.lua backends/applemusic.lua

.PHONY: all test check

all: test

# Syntax-check every Lua source file.
check:
	@for f in $(SRC); do $(LUAC) -p $$f && echo "luac OK: $$f"; done

# Syntax-check, then run the unit suite for the pure logic layer.
test: check
	@$(LUA) tests/run.lua
