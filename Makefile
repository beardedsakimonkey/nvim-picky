NVIM ?= nvim

.PHONY: test
test:
	@$(NVIM) -l tests/run.lua $(FILTER)
