# Dotfiles management facade — discovery only. Each target runs a root script.
.DEFAULT_GOAL := help

.PHONY: help bootstrap install apply status doctor keys test test-fast

help:
	@./help

bootstrap install:
	./update-user-home-dir.sh $(ARGS)

apply:
	./apply $(ARGS)

status:
	./status $(ARGS)

doctor:
	./doctor $(ARGS)

keys:
	./keys $(ARGS)

test:
	./test-update-user-home-dir.sh $(ARGS)

test-fast:
	./test-update-user-home-dir.sh --no-net $(ARGS)
