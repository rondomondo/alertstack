# Project Configuration

PROJECT := alertstack
VERSION := 3.12
SHELL := /bin/bash
VENV := .venv
SOURCE := $(shell which source)
PYTHON := $(shell which python3)
PIP := $(shell which pip3)
PYCODESTYLE := $(shell which pycodestyle)
REQUIREMENTS := requirements.txt
MAIN_SCRIPT := alertstack.py 
LINE_LENGTH := 119


.PHONY: help build venv install format lint codestyle sanity clean

help:  ## Display this help message
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

build: ## run build precursers
	./build.sh

venv:  ## Create a virtual environment
	$(PYTHON) -m venv $(VENV)

install: build ## Install dependencies
	$(PIP) install -r $(REQUIREMENTS)

format: ## Format code using autopep8
	$(PYTHON) -m autopep8 --max-line-length  $(LINE_LENGTH) --in-place --aggressive $(MAIN_SCRIPT)

style: ## Format code using pycodestyle
	$(PYCODESTYLE) --statistics  --max-line-length $(LINE_LENGTH) --max-doc-length $(LINE_LENGTH) $(MAIN_SCRIPT)

lint: ## Lint code using flake8 
	$(PYTHON) -m flake8 --max-line-length=$(LINE_LENGTH)  $(MAIN_SCRIPT)

sanity: ## Run the main script
	$(PYTHON) $(MAIN_SCRIPT) --help

clean:  ## Clean up generated files and directories
	@rm -rf $(VENV) __pycache__ *.pyc temp/

