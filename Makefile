# ============================================================
# alertstack -- Makefile
# ============================================================
.DEFAULT_GOAL := help
MAKEFLAGS     += --no-print-directory
SHELL         := /bin/bash

# -- Infrastructure (OpenTofu / AWS) ------------------------------------------
TERRAFORM_DIR := terraform
AWS_PROFILE   ?= limitedsuperpowers
REGION        ?= us-east-1
OUT           ?=

.PHONY: infra-bootstrap infra-init infra-plan infra-apply infra-destroy infra-fmt infra-validate infra-deploy infra-install-redeploy infra-ssh

infra-bootstrap: ## One-time setup: create S3 state bucket and upload redeploy.sh
	AWS_PROFILE=$(AWS_PROFILE) bash $(SCRIPTS_DIR)/bootstrap.sh --profile $(AWS_PROFILE) --region $(REGION)

infra-init: ## tofu init (remote S3 backend)
	cd $(TERRAFORM_DIR) && AWS_PROFILE=$(AWS_PROFILE) tofu init

infra-plan: ## tofu plan (OUT=somefile.out to save plan)
	cd $(TERRAFORM_DIR) && AWS_PROFILE=$(AWS_PROFILE) tofu plan $(if $(OUT),-out=$(OUT))

infra-apply: ## tofu apply (OUT=somefile.out to apply saved plan)
	cd $(TERRAFORM_DIR) && AWS_PROFILE=$(AWS_PROFILE) tofu apply $(if $(OUT),$(OUT))

infra-destroy: ## tofu destroy (prompts for confirmation)
	@echo "WARNING: this will destroy all infrastructure."
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || (echo "Aborted."; exit 1)
	cd $(TERRAFORM_DIR) && AWS_PROFILE=$(AWS_PROFILE) tofu destroy

infra-fmt: ## tofu fmt -recursive
	cd $(TERRAFORM_DIR) && tofu fmt -recursive

infra-validate: ## tofu validate
	cd $(TERRAFORM_DIR) && tofu validate

infra-deploy: ## SSH to EC2 and run redeploy.sh (git pull + stack-up)
	AWS_PROFILE=$(AWS_PROFILE) bash $(SCRIPTS_DIR)/deploy.sh --profile $(AWS_PROFILE)

infra-install-redeploy: ## Copy redeploy.sh directly to EC2 (bypasses S3/user-data)
	@ip=$$(cd $(TERRAFORM_DIR) && AWS_PROFILE=$(AWS_PROFILE) tofu output -raw alertstack_aws_public_ip 2>/dev/null) && \
	  echo "==> Installing redeploy.sh on $$ip" && \
	  scp -i ~/.ssh/alertstack-ec2.pem -o StrictHostKeyChecking=no \
	    $(SCRIPTS_DIR)/redeploy.sh ubuntu@"$$ip":/tmp/redeploy.sh && \
	  ssh -i ~/.ssh/alertstack-ec2.pem -o StrictHostKeyChecking=no ubuntu@"$$ip" \
	    "sudo mv /tmp/redeploy.sh /usr/local/bin/redeploy.sh && sudo chmod +x /usr/local/bin/redeploy.sh" && \
	  echo "Done. Run: make infra-deploy"

infra-ssh: ## SSH into the EC2 instance
	@ip=$$(cd $(TERRAFORM_DIR) && AWS_PROFILE=$(AWS_PROFILE) tofu output -raw alertstack_aws_public_ip 2>/dev/null) && \
	  echo "Connecting to $$ip..." && \
	  ssh -i ~/.ssh/alertstack-ec2.pem ubuntu@"$$ip"


# Snapshot env vars that the user may have exported before loading .env,
# so they can override the .env defaults.
_ENV_ALERTSTACK_HOST := $(ALERTSTACK_HOST)
_ENV_CERT_DOMAIN     := $(CERT_DOMAIN)

# Load .env if present (silently skip if absent)
-include .env

# Restore any values that were set in the calling environment.
ifneq ($(_ENV_ALERTSTACK_HOST),)
ALERTSTACK_HOST := $(_ENV_ALERTSTACK_HOST)
endif
ifneq ($(_ENV_CERT_DOMAIN),)
CERT_DOMAIN := $(_ENV_CERT_DOMAIN)
endif

# -- Colors ---------------------------------------------------
BOLD   := \033[1m
RED    := \033[31m
GREEN  := \033[32m
CYAN   := \033[36m
YELLOW := \033[33m
RESET  := \033[0m

# -- Tooling --------------------------------------------------
UV      := uv
LINE_LENGTH := 119

# Prefer the plugin form (docker compose); fall back to the standalone binary
DOCKER_COMPOSE := $(shell if docker compose version >/dev/null 2>&1; then echo "docker compose"; else echo "docker-compose"; fi)

# -- Paths ----------------------------------------------------
APP_DIR    := app
SCRIPTS_DIR := scripts

# -- Docker ---------------------------------------------------
IMAGE_NAME     := alertstack/pingpong
IMAGE_TAG      ?= latest
GF_ADMIN_USER  ?= admin
GF_ADMIN_PASSWORD ?= grafana


ALERTSTACK_HOST  ?= alertstack.org
ENVOY_PORT_TLS   ?= 8443
#ENVOY_PORT ?= 8080

# -- Certificates ---------------------------------------------
CERT_DOMAIN ?= $(ALERTSTACK_HOST)
CERT_DIR    := app/certs
GEN_CERT    := $(UV) run --extra dev python $(SCRIPTS_DIR)/gen_cert.py
CERT        := $(CERT_DIR)/$(CERT_DOMAIN).crt
KEY         := $(CERT_DIR)/$(CERT_DOMAIN).key

# -- Help -----------------------------------------------------
.PHONY: help
help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-22s$(RESET) %s\n", $$1, $$2}'

		
# -- System checks --------------------------------------------
.PHONY: check-uv
check-uv: ## Verify uv is available
	@command -v $(UV) >/dev/null 2>&1 || \
	  (printf "$(RED)ERROR:$(RESET) uv not found. Install: https://docs.astral.sh/uv/\n"; exit 1)

.PHONY: install-ubuntu
install-ubuntu: ## Bootstrap a fresh Ubuntu host (run as root or with sudo)
	apt-get update
	apt-get install -y make docker.io htop lsof docker-compose golang locate
	snap install astral-uv --classic
	updatedb
	$(MAKE) install-tools
	@printf "$(GREEN)Ubuntu bootstrap done.$(RESET)\n"
	@printf "$(CYAN)Add Go bin to PATH:$(RESET)  export PATH=/root/go/bin:\$$PATH\n"
	@printf "$(CYAN)Useful aliases:$(RESET)      eval \"\$$(make aliases)\"\n"
	@printf "$(CYAN)Override host:$(RESET)       ALERTSTACK_HOST=<ip-or-hostname> make stack-up\n"

# -- Install --------------------------------------------------
.PHONY: install
install: check-uv ## Install dependencies via uv
	$(UV) sync --all-extras
	@printf "$(GREEN)Dependencies installed.$(RESET)\n"

# -- Certificates ---------------------------------------------
.PHONY: gen-cert
gen-cert: check-uv ## Generate self-signed TLS cert (CERT_DOMAIN=$(ALERTSTACK_HOST))
	$(GEN_CERT) --domain $(CERT_DOMAIN) --cert-dir $(CERT_DIR)
	@printf "$(GREEN)Certificate written to$(RESET) $(CERT_DIR)/\n"

.PHONY: clean-certs
clean-certs: ## Remove generated TLS certificates
	@printf "$(CYAN)Removing$(RESET) $(CERT_DIR)/...\n"
	@rm -f $(CERT_DIR)/*.crt $(CERT_DIR)/*.key 2>/dev/null || true
	@printf "  $(GREEN)ok$(RESET)\n"

# -- Docker image ---------------------------------------------
.PHONY: docker-build
docker-build: ## Build the pingpong Docker image (IMAGE_TAG overridable)
	docker build --tag $(IMAGE_NAME):$(IMAGE_TAG) $(APP_DIR)
	@printf "$(GREEN)Built$(RESET) $(IMAGE_NAME):$(IMAGE_TAG)\n"

.PHONY: docker-run
docker-run: docker-build ## Run the pingpong container (HTTP only, port 8090)
	docker rm -f pingpong 2>/dev/null || true
	docker run --rm -d -p 8090:8090 --name pingpong $(IMAGE_NAME):$(IMAGE_TAG) \
	  -disable-tls

.PHONY: docker-run-tls
docker-run-tls: docker-build ## Run the pingpong container with TLS (ports 8090+8443); generates cert if absent
	@[ -f $(CERT) ] || $(MAKE) gen-cert
	docker rm -f pingpong 2>/dev/null || true
	docker run --rm -d -p 8090:8090 -p 8443:8443 \
	  -v "$(CURDIR)/$(CERT_DIR):/app/certs:ro" \
	  --name pingpong $(IMAGE_NAME):$(IMAGE_TAG) \
	  -cert certs/$(CERT_DOMAIN).crt -key certs/$(CERT_DOMAIN).key

.PHONY: docker-stop
docker-stop: ## Stop and remove the running pingpong container
	docker rm -f pingpong 2>/dev/null || true
	@printf "  $(GREEN)ok$(RESET)\n"

.PHONY: docker-clean
docker-clean: ## Remove the pingpong Docker image
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true
	@printf "  $(GREEN)ok$(RESET)\n"

.PHONY: docker-reset
docker-reset: docker-stop docker-clean clean ## Stop container, remove image, and clean all build artifacts

# -- Stack ----------------------------------------------------
.PHONY: endpoints
endpoints: ## Print stack service URLs (direct and via Envoy proxy)
	@printf "$(GREEN)Stack ready (direct):$(RESET)\n"
	@printf "  Prometheus:   http://localhost:9090\n"
	@printf "  Alertmanager: http://localhost:9093\n"
	@printf "  Grafana:      http://localhost:3000\n"
	@printf "  pingpong:     http://localhost:8090\n"
	@printf "$(GREEN)Stack Envoy (HTTPS via proxy):$(RESET)\n"
	@printf "  Prometheus:   https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/prometheus\n"
	@printf "  Alertmanager: https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/alertmanager\n"
	@printf "  Grafana:      https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/grafana\n"
	@printf "  pingpong:     https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/\n"
	@printf "$(CYAN)HTTP on :${ENVOY_PORT:-8080} redirects to HTTPS on :${ENVOY_PORT_TLS}.$(RESET)\n"
	@printf "\n$(BOLD)Accessing via hostname$(RESET)\n"
	@if [ -n "$(_ENV_ALERTSTACK_HOST)" ]; then \
	  src="environment"; \
	elif grep -qs "^ALERTSTACK_HOST" .env 2>/dev/null; then \
	  src=".env"; \
	else \
	  src="Makefile default"; \
	fi; \
	printf "  $(CYAN)ALERTSTACK_HOST$(RESET) = $(BOLD)${ALERTSTACK_HOST}$(RESET)  (set via $$src)\n"
	@public_ip=$$(curl -sf --max-time 3 ifconfig.me 2>/dev/null || echo "unavailable"); \
	printf "  Public IP: $(BOLD)$$public_ip$(RESET)\n"; \
	if [ "$$public_ip" != "unavailable" ]; then \
	  printf "\n  If $(CYAN)${ALERTSTACK_HOST}$(RESET) is not in DNS, add it to /etc/hosts:\n"; \
	  printf "    $(YELLOW)sudo sh -c 'echo \"$$public_ip ${ALERTSTACK_HOST}\" >> /etc/hosts'$(RESET)\n"; \
	fi

.PHONY: stack-up
stack-up: ## Start the alertstack (Prometheus, Alertmanager, Grafana, pingpong)
	@[ -n "$$(ls -A $(CERT_DIR) 2>/dev/null)" ] || $(MAKE) gen-cert
	$(DOCKER_COMPOSE) up --force-recreate --remove-orphans --detach -V
	@$(MAKE) endpoints

.PHONY: stack-down
stack-down: ## Stop the alertstack
	$(DOCKER_COMPOSE) down

.PHONY: stack-logs
stack-logs: ## Tail logs from all stack services
	$(DOCKER_COMPOSE) logs -f

.PHONY: stack-clean
stack-clean: ## Tear down the stack and delete all named volumes
	$(DOCKER_COMPOSE) down -v
	@printf "$(GREEN)Stack stopped and volumes removed.$(RESET)\n"

.PHONY: stack-reset
stack-reset: stack-clean ## Wipe stack volumes and restart fresh
	$(MAKE) stack-up

# -- Dev tools ------------------------------------------------
.PHONY: install-tools
install-tools: ## Install prom2json, amtool go install
	GOTOOLCHAIN=auto go install github.com/prometheus/prom2json/cmd/prom2json@latest
	GOTOOLCHAIN=auto go install github.com/prometheus/alertmanager/cmd/amtool@latest
	@printf "$(GREEN)prom2json, amtool installed.$(RESET)\n"

.PHONY: aliases
aliases: ## Print shell aliases for docker-exec tools (eval or source)
	@printf "alias promtool='docker exec prometheus promtool '\n"
	@printf "alias amtool='docker exec alertmanager amtool '\n"
	@printf "alias promql='docker exec prometheus promtool query '\n"
	@printf "\n$(CYAN)Tip:$(RESET) eval \"\$$(make aliases)\" to load into your current shell\n"

# -- Go tests -------------------------------------------------
.PHONY: test
test: ## Run Go unit tests for the pingpong server
	@cd $(APP_DIR) && GOTOOLCHAIN=go1.24.0 go test ./... -v

# -- Examples / smoke tests -----------------------------------
.PHONY: examples
examples: ## Print copy-pasteable curl examples for the running stack
	@printf "\n$(BOLD)Prerequisites$(RESET)\n"
	@printf "  1. $(CYAN)${ALERTSTACK_HOST}$(RESET) resolves to 127.0.0.1 -- add to /etc/hosts if missing:\n"
	@printf "       sudo sh -c 'echo \"127.0.0.1 ${ALERTSTACK_HOST}\" >> /etc/hosts'\n\n"
	@printf "  2. Stack is running:\n"
	@printf "       $(CYAN)make stack-up$(RESET)\n\n"
	@printf "  3. $(CYAN)prom2json$(RESET) on PATH for JSON pipeline examples:\n"
	@printf "       go install github.com/prometheus/prom2json/cmd/prom2json@latest\n\n"
	@printf "$(BOLD)Stack UIs (via Envoy HTTPS proxy)$(RESET)\n"
	@printf "  Grafana:      https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/grafana/\n"
	@printf "  Prometheus:   https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/prometheus/\n"
	@printf "  Alertmanager: https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/alertmanager/\n\n"
	@printf "$(BOLD)pingpong endpoints (via Envoy HTTPS proxy)$(RESET)\n"
	@printf "  curl -k https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/ping\n"
	@printf "  curl -k https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/time\n"
	@printf "  curl -k https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/echo\n"
	@printf "  curl -k https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/metrics\n\n"
	@printf "$(BOLD)Envoy admin (direct -- not proxied)$(RESET)\n"
	@printf "  curl -s http://localhost:9901/stats/prometheus | head -40\n\n"
	@printf "$(BOLD)Envoy -- request rate per cluster (last 5 min)$(RESET)\n"
	@printf "  rate(envoy_cluster_upstream_rq_total[5m])\n\n"
	@printf "$(BOLD)Envoy -- active upstream connections per cluster$(RESET)\n"
	@printf "  envoy_cluster_upstream_cx_active\n\n"
	@printf "$(BOLD)Envoy -- HTTP response class breakdown (2xx/4xx/5xx)$(RESET)\n"
	@printf "  sum by (envoy_response_code_class) (rate(envoy_http_downstream_rq_xx[5m]))\n\n"
	@printf "$(BOLD)Envoy -- server uptime (seconds)$(RESET)\n"
	@printf "  envoy_server_uptime\n\n"
	@printf "$(BOLD)Envoy -- list all metric names via prom2json$(RESET)\n"
	@printf "  curl -s http://localhost:9901/stats/prometheus | prom2json | jq '.[].name'\n\n"
	@printf "$(BOLD)HTTP redirects to HTTPS$(RESET)\n"
	@printf "  curl -k -L http://${ALERTSTACK_HOST}:${ENVOY_PORT:-8080}/ping\n\n"
	@printf "$(BOLD)Create a metric (prom text exposition format)$(RESET)\n"
	@printf "  echo 'envoy_cluster_upstream_rq_total{cluster_name=\"frontend\",envoy_response_code_class=\"5xx\",severity=\"critical\"} 6' | curl -k --data-binary @- https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/create\n\n"
	@printf "$(BOLD)Create a metric from a .prom file$(RESET)\n"
	@printf "  cat app/test/envoy_upstream_rq.prom | curl -k --data-binary @- https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/create\n\n"
	@printf "$(BOLD)Create a metric in JSON format (via prom2json)$(RESET)\n"
	@printf "  cat app/test/envoy_upstream_rq.prom | prom2json | curl -k -H 'Content-Type: application/json' --data-binary @- https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/create\n\n"
	@printf "$(BOLD)Update a metric$(RESET)\n"
	@printf "  cat app/test/envoy_upstream_rq.prom | curl -k --data-binary @- https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/update\n\n"
	@printf "$(BOLD)View metric names (via prom2json + jq)$(RESET)\n"
	@printf "  curl -k -s https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/metrics | prom2json | jq '.[].name'\n\n"
	@printf "$(BOLD)Simulate a webhook/notification enqueue$(RESET)\n"
	@printf "  curl -k -s https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/metrics | prom2json | curl -k -H 'Content-Type: application/json' --data-binary @- https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}/v2/enqueue\n\n"
	@printf "$(BOLD)Run the full integration test suite$(RESET)\n"
	@printf "  bash $(APP_DIR)/test/examples.sh\n\n"

# -- Clean ----------------------------------------------------
.PHONY: clean
clean: clean-certs ## Remove build artifacts
	@printf "$(CYAN)Cleaning$(RESET) build artifacts...\n"
	@rm -f $(APP_DIR)/pingpong $(APP_DIR)/app
	@printf "  $(GREEN)ok$(RESET)\n"
