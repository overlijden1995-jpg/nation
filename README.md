![Banner image](https://user-images.githubusercontent.com/10284570/173569848-c624317f-42b1-45a6-ab09-f0ea3c247648.png)

# n8n – The Platform for AI Agents and Workflow Automation

Fair-code platform to build and deploy AI agents and workflows. Combine a visual
canvas with custom code, run it self-hosted or in the
[cloud](https://app.n8n.cloud/login), and connect to 1500+ integrations. AI
automation you can trust with real work, from prototype to production.

![n8n.io - Screenshot](https://raw.githubusercontent.com/n8n-io/n8n/master/assets/n8n-screenshot-readme.png)

---

# Set n8n up on your own computer

This guide assumes **no technical background**. Every command is written out in
full and can be copied and pasted. If a step produces something different from
what is described, jump to
[If something goes wrong](#if-something-goes-wrong) — the answer is probably
there.

You will need about **15 minutes** and **3 GB of free disk space**.

## Contents

1. [Pick your path](#1-pick-your-path)
2. [Open a terminal](#2-open-a-terminal)
3. [Install Docker](#3-install-docker)
4. [Install n8n](#4-install-n8n)
5. [Open n8n and create your account](#5-open-n8n-and-create-your-account)
6. [Connect an AI model](#6-connect-an-ai-model)
7. [Build your first workflow](#7-build-your-first-workflow)
8. [Protect your setup](#8-protect-your-setup)
9. [Day-to-day use](#9-day-to-day-use)
10. [If something goes wrong](#if-something-goes-wrong)
11. [Other ways to run n8n](#other-ways-to-run-n8n)

---

## 1. Pick your path

There are three ways to get n8n running. They are not equally good; pick the row
that matches your situation.

| | What it is | Good for | Time |
|---|---|---|---|
| **A. The installer** (recommended) | A script in this repository that sets everything up properly: database, secrets, backups, updates | Actually using n8n | ~15 min |
| **B. A quick trial** | One command, runs n8n from your Node.js installation | Seeing what n8n looks like before committing | ~5 min |
| **C. Build from source** | Compile this repository yourself | Changing n8n's own code | ~30 min+ |

**Most people want A.** It gives you a setup that keeps working after you close
the laptop, survives restarts, and can be backed up and updated. Path B is a
throwaway demo. Path C is for developers contributing to n8n itself.

The rest of this guide is path A. Paths B and C are
[at the end](#other-ways-to-run-n8n).

### What you are actually installing

Two programs, working together:

- **n8n** — the thing you will use. It runs in a web browser at an address on
  your own machine. Nothing is sent to n8n's servers.
- **Docker** — a way to run software in a sealed box. It is what keeps n8n and
  its database contained and predictable, so you do not have to install and
  configure a database yourself.

You will also get **Postgres**, a database, but Docker installs it for you. You
never have to touch it directly.

---

## 2. Open a terminal

A terminal (also called a shell, console, or command prompt) is a window where
you type instructions instead of clicking. You will paste commands into it.

**macOS.** Press `Cmd + Space`, type `Terminal`, press `Enter`. A small window
opens with a prompt ending in `%` or `$`.

**Windows.** Press the `Windows` key, type `PowerShell`, press `Enter`. A blue
window opens with a prompt ending in `>`.

**Linux.** Press `Ctrl + Alt + T`, or search your applications for `Terminal`.

### Two rules that prevent most problems

1. **Copy the whole command, paste it, then press `Enter`.** Do not retype it by
   hand; one wrong character produces a confusing error.
2. **Wait for the command to finish** before pasting the next one. You can tell
   it finished when the prompt (`$`, `%`, or `>`) comes back.

> **Never paste a command from a stranger into a terminal.** Commands run with
> your full permissions. Everything below either comes from this repository or
> from the official website of the company that makes the software.

---

## 3. Install Docker

Docker is a free download. Install it now if you have not already.

### macOS

1. Go to <https://www.docker.com/products/docker-desktop/> and download **Docker
   Desktop for Mac**. Pick **Apple silicon** if your Mac is from 2020 or later,
   otherwise **Intel**.
2. Open the downloaded `.dmg` and drag the whale icon into **Applications**.
3. Open **Docker** from Applications. macOS will ask for your password — this is
   normal, it is installing a helper that lets Docker run.
4. Wait until the whale icon in the menu bar says **Docker Desktop is running**.

### Windows

1. Go to <https://www.docker.com/products/docker-desktop/> and download **Docker
   Desktop for Windows**.
2. Run the installer and accept the defaults. If it offers to enable **WSL 2**,
   say yes — n8n's installer needs it.
3. When asked, **restart your computer**.
4. Open **Docker Desktop** from the Start menu and wait for **Engine running** in
   the bottom-left corner.

### Linux

Install Docker Engine and the Compose plugin using the official instructions for
your distribution: <https://docs.docker.com/engine/install/>

Then allow your user to run Docker without `sudo`:

```bash
sudo usermod -aG docker $USER
```

Log out and back in for that to take effect.

### Check that Docker works

Copy this into your terminal and press `Enter`:

```bash
docker --version
```

**You should see** something like:

```
Docker version 27.3.1, build ce12230
```

The exact numbers do not matter. If you instead see `command not found` or
`not recognized as an internal or external command`, Docker is not installed
properly — redo the step above, and on Windows make sure you restarted.

Now check that Docker is actually **running**:

```bash
docker info
```

**You should see** a long block of text ending with lines like `Server Version:
27.3.1`. If you see `Cannot connect to the Docker daemon` or `error during
connect`, Docker is installed but not started: open Docker Desktop and wait for
it to say **running**, then try again.

> **Windows users:** from here on, use the **Ubuntu** app that Docker Desktop
> installed (search the Start menu for `Ubuntu`) instead of PowerShell. The n8n
> installer is a bash script and needs that environment. Everything still works
> the same way; `~/n8n` means your home folder inside Ubuntu.

---

## 4. Install n8n

You need this repository on your computer. There are two ways to get it.

**With a ZIP file (no tools needed).** Open
<https://github.com/n8n-io/n8n>, click the green **Code** button, choose
**Download ZIP**, then unzip it into your home folder and rename the unzipped
folder to `n8n-src`.

**With `git`.** Skip this if the command `git --version` does not respond. Use
the name `n8n-src` so it does not collide with the `~/n8n` folder the installer
is about to create:

```bash
cd ~
git clone https://github.com/n8n-io/n8n.git n8n-src
```

Now move into that folder. `cd` means "change directory". Replace the path with
wherever yours actually is:

```bash
cd ~/n8n-src
```

> Not sure where you are? Type `pwd` and press `Enter` — it prints your current
> folder. `ls` lists what is in it; you should see `README.md`, `package.json`,
> and a `scripts` folder.

### 4a. Look before you leap

This command changes nothing. It prints the configuration files the installer
*would* write, so you can see what will happen:

```bash
bash scripts/self-host/setup-n8n.sh --dry-run
```

**You should see** two blocks of text: one for a file called `.env` (settings and
passwords) and one for `docker-compose.yml` (the recipe for the two containers).
Read them if you like. Nothing has been created yet.

### 4b. Check your computer is ready

```bash
bash scripts/self-host/setup-n8n.sh doctor
```

**You should see** a list of checks. The ones that matter are `docker found`,
`docker daemon is running`, `compose`, `openssl found`, `curl found`, and a free
port. A warning in that list is the thing to fix before continuing — each line
tells you what it means.

> **`permission denied` when running the script?** Use `bash
> scripts/self-host/setup-n8n.sh` (as written above) rather than
> `./scripts/self-host/setup-n8n.sh`. Calling `bash` explicitly skips the need
> for the file to be marked executable.

### 4c. Run the installer

```bash
bash scripts/self-host/setup-n8n.sh
```

This is the only command in the guide that changes your computer. Here is what
it does, in order:

1. Creates a folder at `~/n8n` — that is, a folder called `n8n` in your home
   directory. Everything lives there.
2. Generates two long random passwords: one for the database and one encryption
   key for your saved credentials.
3. Writes two files into `~/n8n`: `.env` (the passwords, readable only by you)
   and `docker-compose.yml` (the instructions for Docker).
4. Downloads the n8n and Postgres images. **This is the slow part** — a few
   minutes on a normal connection, and you will see progress bars.
5. Starts both containers.
6. Waits until n8n reports that it is ready.

**You should see** something like this at the end:

```
  ✓ generated .env (secrets, mode 600)
    N8N_ENCRYPTION_KEY is in /Users/you/n8n/.env — back it up, it is unrecoverable
  ✓ wrote docker-compose.yml
  ✓ compose file is valid
==> Starting n8n
  waiting for n8n on http://127.0.0.1:5678 ........
  ✓ n8n is ready

==> Next steps
  1. Open http://127.0.0.1:5678 and create the owner account.
  ...
```

`n8n is ready` is the line that matters. If you see it, the hard part is over.

> **Port already in use?** Something else on your computer uses 5678. Re-run
> with a different port, for example
> `bash scripts/self-host/setup-n8n.sh --port 8080`, and use
> `http://127.0.0.1:8080` everywhere below.

> **Want it somewhere else?** Add `--dir /path/to/folder` to the command.

### What the installer created

```
~/n8n/
├── .env                  ← your passwords. Never share this file.
├── docker-compose.yml    ← safe to read and copy; holds no secrets
└── backups/
    └── RESTORE.md        ← how to restore, read it before you need it
```

You do not need to edit either file. If you re-run the installer later, it
reuses the existing `.env`, so your passwords and encryption key never change.

---

## 5. Open n8n and create your account

Open a web browser and go to:

**<http://127.0.0.1:5678>**

You will see a setup screen asking for your email, password, first name and last
name. This account exists only on your computer; it is not an n8n.io account and
nothing is sent anywhere. Use any email address you like, even a made-up one.

Fill it in and click through the short welcome questionnaire. You can skip the
questions.

**You should now see** the n8n editor: a large empty canvas with a menu on the
left and a **+** button.

> **The page does not load?** Check that the containers are still running with
> `bash scripts/self-host/setup-n8n.sh status` from inside the repository. If it
> says `ready: no`, see [If something goes wrong](#if-something-goes-wrong).

---

## 6. Connect an AI model

n8n works without any AI. If you only want to connect apps and move data around,
skip to [step 7](#7-build-your-first-workflow). If you want AI agents and chat
nodes, n8n needs an API key from a model provider.

### First, an important distinction

A **chat subscription** (Claude Pro, Google AI Plus, ChatGPT Plus, and similar)
is a licence for a website or app. It does **not** include access to the API that
n8n calls. Think of it as the difference between a gym membership and hiring a
personal trainer: both involve the gym, but one does not pay for the other.

You need a separate **API key**, which is billed per use. Costs are small for
personal experimenting — a few cents for a day of testing.

### Get a key (do at least one)

**Google Gemini** — there is a free tier, which makes this the easiest start.

1. Go to <https://aistudio.google.com/apikey> and sign in with a Google account.
2. Click **Create API key** and copy it somewhere temporary.
3. Note that the free tier covers the faster **Flash** models. The larger
   **Pro** models are paid.

**Anthropic Claude** — no free tier, but a small prepaid balance lasts a long
time.

1. Go to <https://console.anthropic.com> and create an account.
2. Open **Billing** and buy the smallest amount of credit offered.
3. Open **API Keys**, click **Create key**, and copy it. **You will not be shown
   it again.**

An API key looks like a long line of random letters and numbers. It is a
password: anyone who has it can spend your credit. Do not email it to yourself,
paste it into a chat, or commit it to a repository.

### Add the key to n8n

**Option 1 — through the interface (easiest):**

1. In n8n, click **Credentials** in the left menu, then **Add credential**.
2. Type `Gemini` (or `Anthropic`) in the search box.
3. Choose **Google Gemini(PaLM) Api** for Gemini, or **Anthropic** for Claude.
4. Paste the key into the **API Key** field. Leave everything else alone.
5. Click **Save**, then **Test connection**. A green "Connection tested
   successfully" message means it works.

**Option 2 — from the terminal**, if you would rather not click:

```bash
GEMINI_API_KEY=paste-your-key-here bash scripts/self-host/setup-n8n.sh credentials
```

Add `ANTHROPIC_API_KEY=paste-your-key-here` on the same line to do both at once.

> **"Owner account needed first"** — n8n cannot attach a credential until your
> user account exists. Finish [step 5](#5-open-n8n-and-create-your-account), then
> run the command again.

---

## 7. Build your first workflow

A **workflow** is a chain of steps. Each step is a **node** — a small box on the
canvas. You connect the boxes left to right, and data flows through them.

We will build four nodes: a chat box, an AI agent, a model, and memory.

### The nodes

1. Click **+** on the canvas, search for **Chat Trigger**, and select it. This
   puts a chat window on your canvas, so you can talk to the workflow.
2. Click the **+** on the right of the Chat Trigger, search for **AI Agent**, and
   select it. This is the brain.
3. On the AI Agent box you will see small **+** connectors underneath it. Click
   the **Chat Model** one, choose **Google Gemini Chat Model** (or **Anthropic
   Chat Model**), and pick a model from the dropdown — a **Flash** model for
   Gemini, or a **Sonnet** model for Claude.
4. Click the **Memory** connector and choose **Simple Memory**. This lets the
   agent remember earlier messages in the same conversation.

### Try it

Click **Chat** at the bottom of the canvas, type `Hello, what can you do?`, and
press `Enter`. After a second or two, the model answers inside the box.

That is a working AI agent. Everything else in n8n is a variation on this
pattern: nodes in a row, data flowing through them.

### Make it useful

- **Give it a tool.** Every AI Agent has a **Tool** connector. Attach, for
  example, a **Google Sheets** node and the agent can read and write your
  spreadsheet when it decides it needs to.
- **Start from a template.** There are thousands of prebuilt workflows at
  <https://n8n.io/workflows>. Download one and use **Import from URL** in the
  top-right menu. Reading a working example teaches faster than building from
  scratch.
- **Trigger it automatically.** Swap the Chat Trigger for a **Schedule Trigger**
  (run every morning) or a **Webhook** (run when another system calls it).

### Save it

Click **Save** in the top right. Give it a name. Workflows only run on a schedule
or by a trigger once they are saved and **Active** — an inactive workflow sits
there doing nothing.

---

## 8. Protect your setup

Two things can cost you your work. Both take a minute to prevent.

### Your encryption key is the key to everything

n8n encrypts every saved credential with the `N8N_ENCRYPTION_KEY` in
`~/n8n/.env`. A database backup **without that key is useless**: your workflows
come back, but every credential inside them is unreadable, and you must re-enter
all of them by hand.

Store it in your password manager now:

```bash
grep N8N_ENCRYPTION_KEY ~/n8n/.env
```

Copy the value after the `=` sign (64 characters) into your password manager.
Label it "n8n encryption key".

> **Windows/WSL:** the folder is inside WSL, but you can open it in Explorer by
> pasting `\\wsl$\Ubuntu\home\` into the address bar and browsing to `~/n8n`.

### Take a backup

```bash
bash scripts/self-host/setup-n8n.sh backup --include-key
```

This saves a dump of the database **and** a copy of the key next to it, in
`~/n8n/backups/`. Move the key copy into your password manager, then delete it
from disk.

Do this before every update, and otherwise whenever you have built something you
would hate to lose.

### Restoring, if you ever need to

```bash
bash scripts/self-host/setup-n8n.sh restore ~/n8n/backups/n8n-20261024-101500.sql.gz
```

It asks for confirmation, because it overwrites the current database. If your
credentials look broken afterwards, the encryption key does not match the backup
— put the original key back into `~/n8n/.env` and restart.

---

## 9. Day-to-day use

Run all of these from inside the repository folder:

```bash
cd ~/n8n-src
```

Two folders are involved, and they are different: `~/n8n-src` is the downloaded
repository you run commands from, and `~/n8n` is where your n8n data lives.

| I want to… | Command |
|---|---|
| Start n8n after a reboot | `bash scripts/self-host/setup-n8n.sh setup` |
| Check whether it is running | `bash scripts/self-host/setup-n8n.sh status` |
| See what it is doing / debug | `bash scripts/self-host/setup-n8n.sh logs` (press `Ctrl + C` to stop watching) |
| Stop it | `bash scripts/self-host/setup-n8n.sh down` |
| Back up | `bash scripts/self-host/setup-n8n.sh backup --include-key` |
| Update to a newer n8n | `bash scripts/self-host/setup-n8n.sh upgrade 2.34.0` |

n8n restarts itself whenever Docker starts, so in normal use you do not need the
first row. `down` is for when you want it switched off.

### Updating

n8n is pinned to a specific version on purpose, so an update cannot land while
you are asleep and break something.

```bash
bash scripts/self-host/setup-n8n.sh upgrade 2.34.0
```

Replace `2.34.0` with the version you want — see the
[releases page](https://github.com/n8n-io/n8n/releases) for the latest. The
command backs up first, changes the pinned version, downloads it and restarts.
Database changes are applied automatically on start. To go back, run the same
command with the old version number.

### Uninstalling

```bash
bash scripts/self-host/setup-n8n.sh down
docker volume rm n8n_pgdata n8n_n8n_data
rm -rf ~/n8n
```

Do this only if you are sure. The second line deletes your workflows and
credentials permanently.

---

## If something goes wrong

Start with `bash scripts/self-host/setup-n8n.sh status`. It tells you whether the
containers are running and whether n8n is answering.

| What you see | What it means | What to do |
|---|---|---|
| `docker: command not found` | Docker is not installed, or the terminal cannot see it | Redo [step 3](#3-install-docker); on Windows, restart the computer |
| `Cannot connect to the Docker daemon` | Docker is installed but not running | Open Docker Desktop and wait for "running" |
| `permission denied` running the script | The file is not marked executable | Run it as `bash scripts/self-host/setup-n8n.sh` |
| `port 5678 is already in use` | Another program has that port | Re-run with `--port 8080` and use `http://127.0.0.1:8080` |
| `n8n did not become ready` | It started but crashed or is still booting | Run `logs` and read the last lines; a failed download or full disk is most common |
| The browser page never loads | Containers stopped | Run `status`, then `setup` to restart |
| `401` or `invalid API key` when testing a credential | The key is wrong, or from the wrong account | Create a fresh key and paste it again; check for a trailing space |
| `429` or `quota exceeded` on Gemini | Free-tier daily limit reached | Wait until tomorrow, or add credit, or switch to another provider |
| `model not found` | That model was retired or renamed | Pick a different model from the node's dropdown |
| Credentials all show as broken | The encryption key changed | Restore the original `N8N_ENCRYPTION_KEY` in `~/n8n/.env`, then restart |
| Webhooks never fire | n8n is not reachable from outside | Expected on a local install; you need a public address — see the [docs](https://docs.n8n.io/hosting/) |
| Everything is slow | Not enough memory, often on Windows | Give Docker Desktop more memory in **Settings → Resources** |
| A workflow does not run on schedule | It is saved but not **Active** | Open it and toggle **Active** in the top right |

Still stuck? The [community forum](https://community.n8n.io) is the right place
to ask. Include the output of `status` and `logs`, say which step you were on,
and leave out your API keys and the contents of `.env`.

---

## Other ways to run n8n

### B. A quick trial (no Docker, throwaway)

You need [Node.js](https://nodejs.org) installed — version 22.22 or newer for the
n8n version in this repository. Then:

```bash
npx n8n
```

n8n starts in that terminal window and opens at
<http://localhost:5678>. Data is stored in `~/.n8n` and **everything is lost**
when you delete that folder. Stopping with `Ctrl + C` stops n8n. This is for
looking around, not for work you want to keep — it uses a simpler database and
does not survive restarts.

### A manual Docker command

If you would rather see every flag than use the installer:

```bash
docker volume create n8n_data
docker run -it --rm --name n8n -p 5678:5678 \
  -v n8n_data:/home/node/.n8n \
  docker.n8n.io/n8nio/n8n
```

This is the single-container version: SQLite instead of Postgres, no pinned
version, no automatic backup, and it stops when you close the terminal. Fine for
a demo. The [Docker installation docs](https://docs.n8n.io/hosting/installation/docker/)
cover the rest.

### C. Build from source (contributors)

For working on n8n's own code. Requirements: Node.js 22.22+, pnpm 10.22+, and
Docker if you want to run the test containers.

```bash
pnpm install
pnpm build > build.log 2>&1
pnpm dev
```

`pnpm agent:setup` runs install, build and tests in one go and writes a summary,
which is what CI and automated agents use. Read
[CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request — it covers the
branch, test and review conventions, and
[AGENTS.md](AGENTS.md) covers the repository layout and the commands used
day to day.

### n8n Cloud

If you would rather not run anything yourself, [n8n
Cloud](https://app.n8n.cloud/login) is the hosted option. Everything in this
guide works the same way there, minus steps 3, 4 and 9.

---

## Key Capabilities

- **AI-Native Automation Platform**: Build and operationalize AI workflows and multi-step agents using your own data, models, and tools
- **Model Flexibility, No Lock-In**: Connect to OpenAI, Anthropic, Google, or open-source models and switch providers without changing your architecture
- **From Prototype to Production**: Design multi-step AI workflows with logic, tool use, human approvals, and full observability
- **Code When You Need It**: Combine visual building with JavaScript, Python, and npm packages for advanced AI workflows
- **Enterprise-Ready AI**: Self-host or deploy securely with role-based access, audit trails, and support for sensitive data
- **Leverage What Already Exists**: 1500+ integrations and 9,000+ workflow [templates](https://n8n.io/workflows) to connect AI with your existing systems

## Resources

- 📚 [Documentation](https://docs.n8n.io)
- 🔧 [1500+ Integrations](https://n8n.io/integrations)
- 💡 [Example Workflows](https://n8n.io/workflows)
- 🤖 [AI & LangChain Guide](https://docs.n8n.io/advanced-ai/)
- 👥 [Community Forum](https://community.n8n.io)
- 📖 [Community Tutorials](https://community.n8n.io/c/tutorials/28)
- 🛠️ [Self-hosting script reference](scripts/self-host/README.md) — every command and option

## Support

Need help? Our community forum is the place to get support and connect with other users:
[community.n8n.io](https://community.n8n.io)

## License

n8n is [fair-code](https://faircode.io) distributed under the [Sustainable Use License](https://github.com/n8n-io/n8n/blob/master/LICENSE.md) and [n8n Enterprise License](https://github.com/n8n-io/n8n/blob/master/LICENSE_EE.md).

- **Source Available**: Always visible source code
- **Self-Hostable**: Deploy anywhere
- **Extensible**: Add your own nodes and functionality

[Enterprise Licenses](mailto:license@n8n.io) available for additional features and support.

Additional information about the license model can be found in the [docs](https://docs.n8n.io/sustainable-use-license/).

## Contributing

Found a bug 🐛 or have a feature idea ✨? Check our [Contributing Guide](https://github.com/n8n-io/n8n/blob/master/CONTRIBUTING.md) for a setup guide & best practices.

## Join the Team

Want to shape the future of automation? Check out our [job posts](https://n8n.io/careers) and join our team!

## What does n8n mean?

**Short answer:** It means "nodemation" and is pronounced as n-eight-n.

**Long answer:** "I get that question quite often (more often than I expected) so I decided it is probably best to answer it here. While looking for a good name for the project with a free domain I realized very quickly that all the good ones I could think of were already taken. So, in the end, I chose nodemation. 'node-' in the sense that it uses a Node-View and that it uses Node.js and '-mation' for 'automation' which is what the project is supposed to help with. However, I did not like how long the name was and I could not imagine writing something that long every time in the CLI. That is when I then ended up on 'n8n'." - **Jan Oberhauser, Founder and CEO, n8n.io**
