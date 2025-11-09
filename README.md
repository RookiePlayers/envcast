envcast – Configuration Casting for Modern DevOps

A precision-engineered command-line tool that transforms your local .env or .yaml configuration files into GitHub Actions secrets or variables, with a guided interactive UX and seamless automation support.

⸻

Overview

envcast was built with one principle in mind:

Move configuration from your local workspace into GitHub CI with zero friction.

This includes:
	•	Complex .env files
	•	Layered environment prefixes (DEV_, STAGING_, PROD_)
	•	GitHub Environments (staging/production/etc.)
	•	GitHub Actions secrets
	•	GitHub Actions variables
	•	Full automation mode for CI/CD tooling
	•	Interactive wizard mode for human setup flows
	•	YAML and .env config file loading

You tell envcast where your config lives and where you want it to go — it takes care of the rest.

⸻

Core Philosophy

DX (Developer Experience) First

Everything in envcast is designed around ergonomics:
	•	Clean, descriptive prompts
	•	Intelligent defaults
	•	Searchable fzf menus (optional)
	•	Numbered fallbacks if fzf isn’t present
	•	No hidden behavior: flags override prompts

Safety by Default
	•	Encrypted secrets via GitHub’s native secret store
	•	YAML parsing isolates sensitive vs non-sensitive content
	•	BOM-aware line parsing ensures data integrity
	•	Value normalization, unquoting, inline-comment stripping

Automation Ready

envcast can be scripted with flags only:
	•	Perfect for CI/CD pipelines
	•	Shell-friendly
	•	Validates repositories + org access before writing
	•	Disables interactive flows automatically

⸻

How It Works

1) Reads your config

Supported formats:
	•	.env
	•	.yaml / .yml

The parser supports:
	•	Key/value pairs
	•	Export syntax (export MY_KEY=value)
	•	BOM, CRLF normalization
	•	Inline comments (KEY=VALUE # comment)
	•	Quoted values
	•	Multiline YAML values

2) Determines your target scope

You choose whether to write into:
	•	GitHub Actions secrets
	•	GitHub Actions variables
	•	GitHub environments (staging, production)

Or in flag-based mode, you specify with:

--secrets
--variables
--env production

3) Applies optional prefix strategy

When not targeting a GitHub Environment, you can apply prefixes:

DEV_API_KEY
STAGING_DB_URI
PROD_REDISHOST

4) Writes safely to GitHub

Under the hood, envcast uses:
	•	gh secret set (stdin-piped bodies)
	•	gh variable set with explicit --body

Secrets are encrypted. Variables remain plaintext.

5) Detailed summary output

At the end of a sync, you’ll see:

Processed 12 lines (12 set, 0 skipped).
Done.


⸻

Command Modes

Interactive Mode

Triggered when:
	•	Flags are missing
	•	Or --interactive is passed

Features:
	•	Owner selection (user account first, then orgs)
	•	Repository selection (via fzf or numbered menu)
	•	Mode selection
	•	Prefix selection
	•	Environment selection

Non-Interactive Mode

Triggered when all required flags are provided.
Ideal for automation.

Example:

envcast \
  --file .env \
  --secrets \
  --repo RookiePlayers/ruki_utils \
  --prefix DEV_


⸻

Configuration File Support (--config-file)

You can load settings from a YAML or env-formatted file:

Example envcast.yaml:

file: ./config/.env.staging
mode: secrets
repo: RookiePlayers/ruki_utils
environment: staging
prefix: STAGING_

Invoke with:

envcast --config-file envcast.yaml

All command-line flags override values from config.

⸻

Repository Selection Flow

If you choose interactive mode or omit flags:
	•	envcast fetches your GitHub user account
	•	Displays your orgs
	•	Lets you choose owner
	•	Lists all repos under that owner

Fallback to numbered menu if fzf is unavailable.

⸻

Error Handling & Validation

Built-In Protections

envcast validates:
	•	File existence
	•	Repo accessibility
	•	GitHub authentication
	•	Org access
	•	Key formatting
	•	Missing values

Automatic Recovery

If gh is missing:
	•	You’re prompted to install it

If auth is missing:
	•	envcast guides you through GitHub login (web flow)

⸻

Examples

Push all staging env values to staging environment

envcast \
  --file .env.staging \
  --secrets \
  --repo RookiePlayers/myservice \
  --env staging

Push dev secrets with prefix

envcast \
  --file .env.dev \
  --secrets \
  --repo RookiePlayers/myservice \
  --prefix DEV_

Push variables instead of secrets

envcast \
  --file .env \
  --variables \
  --repo RookiePlayers/myservice

Load config from YAML only

envcast --config-file ./envcast.yaml


⸻

Advanced Features

BOM-Proof Parsing

.env files copied from Windows or IDEs often contain a BOM.
envcast strips it automatically.

Inline Comment Stripping

KEY=value # comment

→ becomes KEY=value

Quoted Values

API_KEY="secret"

quotes removed safely.

Escaped Hash Handling

PASSWORD=ab\#cd

→ preserves literal #

⸻

Installation

Place envcast in your PATH:

chmod +x envcast
mv envcast /usr/local/bin/envcast

Test it:

envcast --version


⸻

Recommendations
	•	Pair with gh auth refresh for CI workflows
	•	Commit your envcast.yaml in private repos only
	•	Use prefixes for multi-env monorepos
	•	Use environment scopes for production

⸻

Roadmap
	•	Support for AWS Secrets Manager / GCP Secret Manager
	•	Bulk org secret replication
	•	Validation schemas

⸻

License

MIT License

⸻

Author

Built for modern, multi-environment workflows that demand clarity and reliability.