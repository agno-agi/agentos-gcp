# AgentOS: The self-managing agent platform

AgentOS is an open-source agent platform that runs in your cloud. It comes with a **Super Agent** that builds agents, coordinates their work, and helps you manage the platform. Ask it to run an agent, create a workflow, or break a larger goal into Projects and Tasks.

Built with [Agno](https://github.com/agno-agi/agno), AgentOS brings together:

- **Agents, teams, and workflows** you build in Python, Studio, or through Super Agent.
- **Memory, knowledge, and storage** backed by your own PostgreSQL database.
- **Permissions, human approvals, and scheduling** for managing work.
- **An API and MCP server** to use your agents in products, Claude, and ChatGPT.

Use the [AgentOS UI](https://os.agno.com) to chat with agents, inspect runs and traces,
and track their work. This template runs locally with Docker and deploys to Google Cloud Run.

## Get started

Give this prompt to your coding agent:

```text
Help me set up my agent platform and build my first agent.

Clone https://github.com/agno-agi/agentos-gcp into a folder called agent-platform,
cd into it, and follow .agents/skills/setup-platform/SKILL.md.
```

It checks Docker, helps you configure your API key, starts the platform, and builds
an agent with you. If you've already cloned the repo, ask it to run `/setup-platform`.

### Or run it yourself

You'll need Git, Docker, and an OpenAI API key.

```sh
git clone https://github.com/agno-agi/agentos-gcp agent-platform
cd agent-platform
cp example.env .env
```

Set `OPENAI_API_KEY` in `.env`, then start the platform:

```sh
docker compose up -d --build
```

Once [localhost:8000/docs](http://localhost:8000/docs) loads:

1. Sign in at [os.agno.com](https://os.agno.com).
2. Choose **Connect OS**, select a local connection, and enter `http://localhost:8000`.
3. Open **Super Agent** and tell it what you're working on.

## Put Super Agent to work

Start with a concrete request:

> Build an agent that turns meeting notes into decisions and action items, then run it on these notes: …

Super Agent can use your existing agents or build one for the job. Agents it builds
appear in the Agents list and are available through the API and MCP.

For ongoing work, ask it to create a Project:

> Propose a Project to build a customer support agent. Break it into Tasks for my review.

The **Company** page keeps track of Goals, Projects, Tasks, and scheduled Routines.
You can approve work, assign it, review results, and request changes there or through
Super Agent. Goals describe ongoing responsibilities; Projects and Tasks organize
specific work; Routines run on a schedule.

This template includes a weekly maintenance Routine that reviews the platform for
relevant Agno updates, security issues, and quality problems. It is **disabled by
default**. Enable it from the Company page to receive proposals for review.

## Skills

This repo includes skills for building and managing your agent platform. Ask your
coding agent to follow the relevant skill:

| Task | Skill |
| --- | --- |
| Build an agent | [/create-agent](.agents/skills/create-agent/SKILL.md) |
| Add tools, change behavior, or fix a bug | [/extend-agent](.agents/skills/extend-agent/SKILL.md) |
| Write evals | [/create-evals](.agents/skills/create-evals/SKILL.md) |
| Find weaknesses and improve reliability | [/improve](.agents/skills/improve/SKILL.md) |
| Review the repository before release | [/review-and-improve](.agents/skills/review-and-improve/SKILL.md) |

## Coding agents

This repo comes with **Claude Code** and **Codex** agents. Work with them directly in AgentOS or ask Super Agent to delegate work to them.

They're **off by default**. Follow the [harness setup guide](docs/harnesses.md) to
enable them and configure credentials and sandboxes.

Once enabled, ask Super Agent:

> Ask Codex Engineer to review this project and suggest improvements. Don't change any files yet.

Without a sandbox, engineers run on the API host with its file and credential access.
[Sandboxes](docs/harnesses.md#sandboxes-and-checkpoints) provide isolated execution
and checkpoint recovery.

## Make this platform yours

Create an empty private GitHub repository, then point this checkout at it:

```sh
git remote rename origin upstream
git remote add origin https://github.com/YOUR-ORG/YOUR-REPO.git
git push -u origin HEAD
```

Your work now goes to your repository; `upstream` keeps the template available for
updates. If you use sandboxes, also set your repository URL and branch in the
[harness configuration](docs/harnesses.md#sandboxes-and-checkpoints).

## Deploy in production

Ask your coding agent to follow
[/deploy-platform](.agents/skills/deploy-platform/SKILL.md). This template targets Google Cloud Run.
You’ll need Google Cloud CLI (`gcloud auth login`), a project with billing enabled, Docker and OpenSSL.

Set `GCP_PROJECT_ID`. The scripts create Artifact Registry, Cloud SQL and Cloud Run. Keep at least one instance and CPU available between requests; the scheduler needs both.

Create `.env.production` from [example.env](example.env) if absent. Set `OPENAI_API_KEY`
and any other model credentials you need. Keep `RUNTIME_ENV=prd` or leave it unset.

```sh
./scripts/gcp/up.sh
```

When setup provides the HTTPS URL, connect it as a **Live** connection at
[os.agno.com](https://os.agno.com). Enable JWT authorization in **Settings → OS Security**
and supply the public verification key. If the prompt was skipped, save the full quoted
multiline `JWT_VERIFICATION_KEY` in `.env.production`, then run
`./scripts/gcp/env-sync.sh`. The API requires the key to start in production.

Use `./scripts/gcp/redeploy.sh` for code and `./scripts/gcp/env-sync.sh` for settings.

Keep `AGENTOS_URL` set to the public HTTPS URL for scheduling and MCP OAuth. Verify
`/health`, an authenticated UI connection, and rejection of anonymous `/agents` requests.
Run one API instance and read [scaling](docs/scaling.md) before adding replicas.
For optional hosted sandboxes, follow [harness setup](docs/harnesses.md) and preserve
`SANDBOX_PROVIDER=agentcore` plus the required AWS credentials, runtime and S3 settings.

## Upgrade an existing deployment to 3.3

Back up the database before upgrading. Agno 3.3 renames Company Products to Goals
and migrates Company files. Deploy the updated image, then call
`POST /databases/all/migrate` once with an authenticated OS administrator token.
The API can answer `/health` while Company reports that migration is required;
a healthy API alone does not confirm the upgrade is complete. Company becomes
available after a successful migration without restarting the API.

Verify `/company/goals` and your existing Projects, Tasks, notes and Routines after
migration. Keep existing database settings and record IDs; do not reset the database.
A fresh database provisions the new schema automatically.
Existing `products:*` permissions remain valid as aliases for `goals:*`; saved
role customizations and user assignments are retained.

Saved declarations keep their later edits. Review the saved maintenance Routine in
the UI if its instructions still use Product terminology; changing the declaration
in `app/company.py` does not replace saved instructions.

Super Agent and Company use `gpt-6.1-terra`; the shared default model and Studio
registry retain `gpt-6.1-sol`.

## User roles and Slack

The template follows the [roles and default-role cookbook](https://github.com/agno-agi/agno/blob/de92e096caa37b02b18aa500e58bb55035093351/cookbook/05_agent_os/26_authorization/16_roles_and_default_role.py).
Agno is pinned to candidate commit `de92e096caa37b02b18aa500e58bb55035093351`,
the SDK revision used by [the Render 3.3 template](https://github.com/agno-agi/agentos-render/pull/22).
It combines the [3.3 release work](https://github.com/agno-agi/agno/pull/11877) with
newer Company and Super Agent updates, including the role flow from
[PR #11866](https://github.com/agno-agi/agno/pull/11866). This is a revision for release
testing, rather than a published release.

In production, `Authorization` defines two editable OS roles:

- **Member** is the default: `READ + RUN` for ordinary agents, teams and workflows.
  Broad run scopes do not grant access to Super Agent, Platform Builder or Mini Agent.
- **Platform** adds `PLATFORM`, including access to those built-ins and Company tools.
  It does not grant `agent_os:admin`.

With `SLACK_BOT_TOKEN` and `SLACK_SIGNING_SECRET` configured, Slack uses
`authorize_senders=True` and `resolve_user_identity=True`. A sender's confirmed Slack
email is their directory id, matching their web JWT subject. Their first web request or
Slack message creates a user with Member. Admin-created users also get the default role.

To test, open **User Management > End Users** in the AgentOS UI:

1. Confirm the user's OS role is Member. A Slack request to Super Agent is refused.
2. Assign Platform and retry. The next Slack message uses the updated role.
3. Assign Member again to revoke platform access, or disable the user to block access.

Web/API requests also trust signed JWT scopes: permission from the token or the stored
OS role can allow access. An organization-admin token can therefore allow Super Agent
in the UI while the same user's OS Member role blocks Slack. Organization roles and
OS roles are separate; changes are not automatically copied between them.

Existing saved role scopes and explicit user assignments survive restarts. Update a
previously customized Member role through the UI or `/authz` API if it should match
the new scope bundle. This update does not reset the database. Development mode
(`RUNTIME_ENV=dev`) keeps authorization disabled.

## Connect to Claude, ChatGPT, and coding clients

For MCP clients like Claude and ChatGPT, set `MCP_CONNECT_SECRET` to a random secret in your production environment and apply it with the settings update command above. Connect the client to `https://YOUR-DOMAIN/mcp` and enter the secret on
the consent page.

For supported coding clients:

```sh
uvx agno connect --url https://YOUR-DOMAIN
```

## Local development

Install [uv](https://docs.astral.sh/uv/), then create and activate a virtual environment
from the repository root. If another environment is active, run `deactivate` first.

```sh
./scripts/venv_setup.sh
source .venv/bin/activate
```

The setup script installs the application and development dependencies into `.venv`.
After making changes, format your code and check formatting, lint, and types:

```sh
./scripts/format.sh
./scripts/validate.sh
```

With PostgreSQL running, test Super Agent with the smoke evals. These spend model
calls and save results in the database:

```sh
python -m evals --tag smoke
```

Add cases in [evals/cases.py](evals/cases.py). Use `./scripts/mcp_check.sh` to check
the running MCP server without a model call.

See [AGENTS.md](AGENTS.md) for development conventions and
[Agno documentation](https://docs.agno.com) for framework guides.
