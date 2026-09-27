TF_DIRS := . modules/*/ examples/*/

.PHONY: help test lint fmt validate tflint cfn-lint checkov shellcheck demo

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

test: ## pytest (custom resource + scripts) and terraform test (mocked provider)
	python3 -m pytest -q tests
	@for d in . modules/compliance-bucket; do terraform -chdir=$$d init -backend=false -input=false >/dev/null || exit 1; done
	terraform test
	terraform -chdir=modules/compliance-bucket test

lint: validate tflint cfn-lint checkov shellcheck ## Every linter CI runs

fmt: ## Format the Terraform files
	terraform fmt -recursive

validate: ## terraform fmt -check, then validate the module, submodules and examples
	terraform fmt -check -recursive
	@for d in $(TF_DIRS); do \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && \
	  terraform -chdir=$$d validate -no-color >/dev/null && echo "valid: $$d" || exit 1; \
	done

tflint: ## tflint with the AWS ruleset
	@tflint --init >/dev/null
	tflint --recursive --config "$(CURDIR)/.tflint.hcl"

cfn-lint: ## Lint the CloudFormation templates
	cfn-lint cloudformation/*.yaml

checkov: ## Static security scan of Terraform, CloudFormation and CI
	checkov --config-file .checkov.yaml -d . --skip-download

shellcheck: ## Lint the shell scripts
	shellcheck scripts/*.sh

demo: ## The recording in the README: terraform test, then a reboot-tag dry run against the fake AWS CLI
	@terraform init -backend=false -input=false >/dev/null
	terraform test
	@PATH="$(CURDIR)/tests/fake-aws:$$PATH" scripts/default-reboot-tag.sh --regions us-east-1,us-west-2 --dry-run
