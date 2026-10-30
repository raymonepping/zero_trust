SHELL := /bin/sh
.DEFAULT_GOAL := help
BOOTSTRAP_PYTHON ?= python3.14
PYTHON := $(if $(wildcard .venv/bin/python),.venv/bin/python,$(BOOTSTRAP_PYTHON))
export RUNTIME INSTANCE PORT_BASE OVERWRITE VAULT_EDITION
# Every declared target shares one dispatcher prerequisite. GNU Make executes it
# once, even with -j. Validation sees all goals before any runtime operation.
.PHONY: help deps doctor labs up down status prepare resolve verify plan drift adopt unseal check reset bootstrap lab $(shell seq -w 1 10) _dispatch
help deps doctor labs up down status prepare resolve verify plan drift adopt unseal check reset bootstrap lab 01 02 03 04 05 06 07 08 09 10: _dispatch
	@:
_dispatch:
	@$(PYTHON) automation/cli.py --goals $(if $(MAKECMDGOALS),$(MAKECMDGOALS),help) --lab '$(LAB)'
