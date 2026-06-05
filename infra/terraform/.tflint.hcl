#============================================================================
# tflint configuration for klz-accelerator-finops (Terraform stack)
#----------------------------------------------------------------------------
# Run from this directory:
#   tflint --init                                  (one-time, downloads azurerm plugin)
#   tflint --recursive --config $(pwd)/.tflint.hcl (lints every module)
#
# CI invocation (.github/workflows/pr.yml):
#   - uses: terraform-linters/setup-tflint@v4
#   - run: tflint --init
#   - run: tflint --recursive --format compact
#
# Documented warning baseline lives in docs/lint-baseline.md. Anything beyond
# the baseline must either be fixed in the PR or appended to the baseline
# table with a justification.
#============================================================================

config {
  format             = "compact"
  call_module_type   = "all"
  force              = false
  disabled_by_default = false
}

# Built-in Terraform ruleset — best-practice naming, syntax, deprecations.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Azure-specific rules: valid SKUs, region names, deprecated resource args, etc.
plugin "azurerm" {
  enabled = true
  version = "0.29.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# Project-specific waivers (each must cite a reason).
#
# terraform_required_version: pinning lives in versions.tf; rule double-counts
# when ran from blueprints/ which re-use the root provider block.
rule "terraform_required_version" {
  enabled = true
}

# We intentionally use _ in module local names for readability (e.g. ai_search,
# foundry_stack). The default rule allows snake_case, so this stays on.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Unused declarations should always be cleaned up.
rule "terraform_unused_declarations" {
  enabled = true
}

# Provider-version pinning is mandatory across the stack.
rule "terraform_required_providers" {
  enabled = true
}
