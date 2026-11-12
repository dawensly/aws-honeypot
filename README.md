**Project Title:** AWS Honeypot

**Date:** 2026-10-30

**Description:** Cloud based SSH and Telnet honeypot deployment on AWS to capture, log, and analyze automated brute-force attacks in real time. Will be built utilizing tools such as Cowrie on an EC2 instance, featuring a serverless monitoring pipeline that will route traffic data through CloudWatch and Lambda for persistent storage and analysis with DynamoDB

**Status key:** `[planned]` = written from research, not run yet. `[tested]` = run and verified (add what actually happened in the Build Log at the bottom).

---

## **Tools**

- AWS EC2
- Cowrie
- AWS DynamoDB
- AWS Lambda
- AWS CloudWatch
- AWS IAM (instance role + Lambda role)
- AWS Budgets (billing alert)

---

## Phase 1: Setup `[tested]`

> Done, except two items that are completed during Phase 2: the CloudWatch IAM role and the outbound lockdown to 443. IMDSv2 verification is also still pending (see Build Log).

AWS EC2 Configuration requires separating administrative access from exposed ports

**Port Plan:** Automated scanners overwhelmingly target the default ports (22 for SSH, 23 for Telnet), so the honeypot needs to answer there. Cowrie runs unprivileged on high ports (2222 SSH, 2223 Telnet) and iptables redirects the default ports to it. Real admin SSH moves to a non-standard port.

|Port|Protocol|Purpose|Source|
|---|---|---|---|
|22|TCP|Public-facing SSH, redirected to Cowrie 2222|0.0.0.0/0|
|23|TCP|Public-facing Telnet, redirected to Cowrie 2223|0.0.0.0/0|
|22022|TCP|Real admin SSH (terminal access)|My IP only|

- The table above is the **final** state. During testing, port 22 (and later 23) stay limited to My IP, and are only opened to 0.0.0.0/0 after the CloudWatch pipeline is verified (see the Phase 2 order of operations).
- The iptables redirect happens on the instance, after the security group, so the security group rules apply to the original ports (22 and 23). 2222 and 2223 do not need to be open to the internet.
- Telnet is off by default in Cowrie. It has to be enabled in the Cowrie config (listens on 2223).

**Inbound Rules Config:**

- **Port 22022 (Custom TCP):** Real admin SSH, secure remote access via terminal. Source is My IP only
- **Port 22 (SSH):** Exposes Cowrie emulated SSH (redirected to 2222). Source 0.0.0.0/0
- **Port 23 (Custom TCP):** Exposes Cowrie emulated Telnet (redirected to 2223). Source 0.0.0.0/0

EC2 Configuration:

1. Network isolation
    - Use a dedicated VPC (or at minimum a dedicated subnet) for the honeypot so it has no route to anything else in the account
2. Launching an EC2 Instance
    - Create a new security group and edit the inbound rules:
        - For administrative access -> Set Type to Custom TCP, port range 22022, and source to My IP
        - For Cowrie SSH -> Set Type to SSH, port 22, and source to 0.0.0.0/0
        - For Cowrie Telnet -> Set Type to Custom TCP, port range 23, and source to 0.0.0.0/0
        - Save
    - Allocate an Elastic IP and associate it with the instance (auto-assigned public IPs change on stop/start, which would break data consistency over weeks)
    - Require IMDSv2 (set metadata option to "required") so instance credentials are harder to steal if the box is compromised
3. Outbound rules
    - Open during setup (package installs, Cowrie dependencies, CloudWatch agent)
    - After setup, restrict to HTTPS (443) only for CloudWatch
    - Reason: Cowrie downloads files when attackers run wget/curl in the fake shell, so open outbound lets a compromised or abused box reach other targets
4. IAM
    - Instance role for the CloudWatch agent only (see Phase 2 for the exact setup and the policy it ends up with)
    - Lambda and DynamoDB permissions go on the Lambda's own execution role, not the instance
5. Cost control
    - Set up a billing alarm / AWS Budget alert before launch (log volume and data transfer can add up)

**Lockout warning:** when moving admin SSH from 22 to 22022, add the 22022 rule first, confirm a working login on 22022, and only then change sshd and open 22 to the world. The same goes for the iptables redirect in Phase 2: once port 22 is redirected to Cowrie, you can no longer reach the real sshd on 22, so sshd must already be on 22022.

---

## Phase 2: Deployment `[in progress]`

> Cowrie is installed and running as a systemd service (steps 2 and Telnet config done, see Build Log 2026-11-11). The iptables redirects (step 3) and the redirect test (step 4) are also done. CloudWatch (step 5) is also done and verified, including the narrowed IAM policy. Steps 6 and 7 are still planned.

**Order of operations:**

1. Move real sshd to 22022 and confirm login (Phase 1 lockout warning) -- **done 2026-11-01, see Build Log**
2. Install and start Cowrie -- **done 2026-11-11 `[tested]`**: installed in `~/honeypot`, running as a systemd service, local login and logging verified, survived a reboot
3. Add iptables redirects (22 -> 2222, 23 -> 2223) and persist them -- **done `[tested]`**, see Port Redirection for persistence details
4. Test with the security group limited to my own IP only -- **done `[tested]`**
5. Set up the CloudWatch agent and confirm logs arrive -- **done 2026-11-11 `[tested]`**
6. Open ports 22 and 23 to 0.0.0.0/0 `[planned]`
7. Restrict outbound rules to 443 `[planned]`

##### Cowrie Install & Configuration `[tested]`

Install directory is `~/honeypot` (`/home/ubuntu/honeypot`). Every path below that mentions the Cowrie directory uses this.

```bash
mkdir ~/honeypot && cd ~/honeypot

# Create the environment
python3 -m venv cowrie-env

# Activate the environment
source cowrie-env/bin/activate

# Upgrade pip and install Cowrie
(cowrie-env) $ python -m pip install --upgrade pip
(cowrie-env) $ pip install cowrie

# Initialize the Honeypot
(cowrie-env) $ cowrie init
(cowrie-env) $ $EDITOR etc/cowrie.cfg     # optional
(cowrie-env) $ cowrie start               # manual start, for first testing only (see systemd service below)
```

- The venv runs Python 3.14 (Ubuntu Server 26 LTS default). No compatibility problems showed up with Cowrie or Twisted.
- Cowrie ships with a default fake filesystem (`fs.pickle`), so no extra setup is needed. `createfs` / `fsctl` are only for customizing it later (optional).
- The fake shell presents as Debian with hostname `svr04` (Cowrie default), and accepts `root` with any password by default.

##### Running Cowrie as a systemd service `[tested]`

`cowrie start` by itself is fine for a first test, but it does not survive a reboot, and running it by hand next to a systemd unit makes two processes fight over port 2222. So Cowrie runs under systemd, and **all restarts go through systemctl** from here on (never `cowrie start` while the service exists).

`/etc/systemd/system/cowrie.service`:

```ini
[Unit]
Description=Cowrie honeypot
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/honeypot
Environment="PATH=/home/ubuntu/honeypot/cowrie-env/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=/home/ubuntu/honeypot/cowrie-env/bin/twistd --nodaemon --umask=0022 --pidfile= --logger cowrie.python.logfile.logger cowrie
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Why each non-obvious line is there:

- `WorkingDirectory`: Cowrie uses relative paths (`etc/`, `var/`), so it must start from its install directory.
- `Environment="PATH=..."`: systemd starts services with a minimal `PATH`. The `cowrie` launcher runs `twistd` by name, which lives in the venv's `bin/`, so without this the launcher fails with `FileNotFoundError`.
- `ExecStart` calls `twistd` directly with `--nodaemon` so it stays in the foreground, which is what `Type=simple` expects. The `cowrie` launcher in this version does not accept a `-n` flag (see Build Log).
- `--pidfile=` (empty): systemd tracks the process itself, so twistd does not need a pid file.
- `RestartSec=5`: keeps a crash loop from hitting systemd's "start request repeated too quickly" limit.

Enable and manage:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cowrie
sudo systemctl restart cowrie          # after any config change
sudo systemctl status cowrie --no-pager
sudo journalctl -u cowrie -n 30 --no-pager
```

**Verification checklist** (do this after any change to the unit or config):

```bash
sudo ss -tlnp | grep -E '2222|2223'
sudo systemctl status cowrie --no-pager | head -8
```

The `twistd` PID in the `ss` output must **match the service's Main PID**. If they differ, an old manually started process is still holding the port and the service is not the one serving traffic.

##### Telnet `[tested: config enabled, listener check pending]`

Telnet is enabled in `etc/cowrie.cfg` (inside the `~/honeypot` directory):

```ini
[telnet]
enabled = true
```

After changing the config, restart with `sudo systemctl restart cowrie`. Confirm Cowrie is listening on 2223 with `sudo ss -tlnp | grep 2223`

##### Port Redirection `[tested]`

In order to run a successful honeypot, most attack traffic will be on port 22. By default Cowrie runs on port 2222 and there are three methods to change that (iptables redirect, authbind, setcap). For this project, I will be running a port redirection via iptables because it keeps Cowrie fully unprivileged and is easy to toggle during testing:

```bash
sudo iptables -t nat -A PREROUTING -p tcp --dport 22 -j REDIRECT --to-port 2222
sudo iptables -t nat -A PREROUTING -p tcp --dport 23 -j REDIRECT --to-port 2223
```

- Rules do not survive a reboot by default. Persist them (look into `iptables-persistent` / `netfilter-persistent`) and verify they are still there after a reboot (`sudo iptables -t nat -L PREROUTING -n`).
- Note for analysis: because of the redirect, Cowrie logs will show the destination port as 2222/2223, not 22/23.

Testing connectivity with SSH:

```bash
# Test Cowrie directly (from the instance)
ssh -p 2222 root@localhost
```

- `localhost` only tests Cowrie itself. PREROUTING rules apply to incoming traffic, so to test the redirect, connect to port 22 on the Elastic IP **from my own machine** (security group limited to my IP at this stage).
- Confirm the login and commands show up in `var/log/cowrie/cowrie.json`.
- The direct test on 2222 from the instance is done and logs correctly (see Build Log 2026-11-11). `src_ip` shows `127.0.0.1` because the test came from the box itself.
- Redirect rules added and tested. How I tested (from my own machine on the Elastic IP, port 22 and port 23):
- Persistence (`iptables-persistent` / `netfilter-persistent`):

##### Configuring CloudWatch agent on EC2 Instance `[tested]`

1. Create a new role on IAM console
2. Use AWS Service as trusted entity and EC2 as use case
3. Attach AWS-managed policy: **CloudWatchAgentServerPolicy** (to get things working first)
4. Create role EC2-CloudWatchAgent-Role
5. Attach the role to the instance (EC2 console -> Actions -> Security -> Modify IAM role)
6. Install the CloudWatch agent. Will be using Ubuntu Server. Use the package that matches the instance architecture (amd64 for t3, arm64 for t4g) and copy the current download link from the official AWS install page, since the URL below may change:

```bash
sudo apt update -y
wget https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
sudo dpkg -i -E ./amazon-cloudwatch-agent.deb
```

(For arm64, replace `amd64` with `arm64` in the URL.)

7. Configure the agent. The wizard works, or write the config by hand so it points at the Cowrie JSON log. Save it as `/opt/aws/amazon-cloudwatch-agent/bin/config.json`. **The path below uses the real install directory (`/home/ubuntu/honeypot`), not the old `my-honeypot` name from the first draft of this doc:**

```bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-config-wizard
```

```json
{
  "agent": {
    "run_as_user": "root"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/home/ubuntu/honeypot/var/log/cowrie/cowrie.json",
            "log_group_class": "STANDARD",
            "log_group_name": "/honeypot/cowrie",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 30
          }
        ]
      }
    }
  }
}
```

This is the config the wizard actually saved. Wizard answers, in order, and why:

|Prompt|Answer|Why|
|---|---|---|
|OS|linux|Ubuntu instance|
|User to run the agent|root (option 2; the default is cwagent)|Cowrie's log is under `/home/ubuntu`, and `cwagent` would probably not be able to read it. Trade-off: the agent runs with more privilege than needed, but it only reads one file and the instance role is limited to one log group|
|StatsD / CollectD / host metrics|no to all|Only logs are needed. Custom metrics past the first 10 are billed. CollectD "yes" without CollectD installed makes the agent fail to start|
|Import old Logs agent config|no|Nothing to migrate|
|Monitor log files|yes|Path, group, and stream as in the config above|
|Log group class|STANDARD|Infrequent Access is cheaper to ingest but drops features (e.g. metric filters, and I believe subscription filters, which Phase 3 may need). Class cannot be changed after the group is created|
|Retention|30 days (menu option 7; options are numbered, not day counts)|Never-expire is the default and storage would grow forever. 30 days leaves time to build Phase 3 before data expires. Can be lowered once DynamoDB is the long-term store|
|Additional log files|no|`cowrie.log` mostly duplicates `cowrie.json` and would roughly double ingestion|
|journald logs / X-Ray traces|no|Not needed, extra volume, extra permissions|
|Store config in SSM Parameter Store|no|The instance role deliberately has no SSM permissions|

8. Start the agent

```bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json
```

9. Verify: check the log group in the CloudWatch console. If nothing arrives, check `/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log` for permission or path errors.

**Result 2026-11-11 `[tested]`:** agent started with the step 8 command, and Cowrie events appeared in log group `/honeypot/cowrie` (stream named after the instance ID) with all fields intact. Cost notes: CloudWatch's free tier is 5 GB of logs shared across ingestion, storage, and Logs Insights scans per month. Past that it is $0.50/GB ingested and $0.03/GB-month stored (us-east-1 list rates). Cowrie logs are verbose, so check ingestion after the first day or two of real traffic.

**Narrow the IAM permissions afterward.** Once logs are flowing, replace the managed policy with a custom one scoped to the single log group. Pre-create the log group so `logs:CreateLogGroup` isn't needed. If the agent fails after narrowing, the agent log will name the missing permission:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:REGION:ACCOUNT_ID:log-group:/honeypot/cowrie:*"
    }
  ]
}
```

**Narrowing done 2026-11-11 `[tested]`:** added the policy above as an inline policy named `cowrie-log-group-only` on `EC2-CloudWatchAgent-Role`, then removed `CloudWatchAgentServerPolicy`. After restarting the agent, a new Cowrie command still appeared in CloudWatch, so the three log-group permissions are enough. The inline policy shows 0 under "Attached entities" in the console, which is normal for inline policies. Agent log check for a `logs:PutRetentionPolicy` error (the config has `retention_in_days`): If it complains, either add that action or remove `retention_in_days` and set retention by hand in the console.

Reason the SSM and IAM permissions from the original draft were dropped: they are not needed to ship logs, and on a box meant to be attacked, extra permissions (like `ssm:SendCommand` on `*`) would be dangerous if the instance were compromised.

## Phase 3: Serverless Data Pipeline `[planned]`

**Note for DynamoDB table design:** Cowrie's JSON log is event-based. Candidate keys: session ID as partition key, timestamp as sort key. Use the `timestamp` field inside the Cowrie JSON event, **not** CloudWatch's own event timestamp: when the agent first started it read the existing log file from the beginning and shipped old events all at once, so CloudWatch stamped them with the ingestion time (02:42:20) while the event's real time (e.g. 01:05:03) is in the JSON.

## Phase 4: Results/Analysis

---

## Build Log

### 2026-11-01: Cost guardrail, VPC, instance, and moving real SSH to 22022

#### Pre-launch: billing alert

**~16:37** -- **Goal:** Have a billing alert in place before creating anything.

- **What I did:** Checked the existing AWS Budget, a $20 monthly cost budget.
- **Decision and why:** The budget's scope excludes the charge types **Credit** and **Refund**. The account has about $119 in credits, and if they were counted, the budget would stay near $0 and never alert.

#### Launching the EC2 instance

**16:50** -- **Goal:** Launch an EC2 instance with IMDSv2 required and an Elastic IP, inside an isolated network.

- **What I did:** Created a dedicated VPC (`cowrie-honeypot-vpc`) for the honeypot with a public subnet.
- **Result:**

|Setting|Value|
|---|---|
|VPC CIDR|10.0.0.0/16|
|Public subnet CIDR|10.0.0.0/20|

- **Tags:**

|Key|Value|
|---|---|
|Project|threat-intelligence|
|Environment|isolated|
|Name|cowrie-honeypot-vpc|
|SecurityLevel|untrusted|

- **Decision and why:** A dedicated VPC means the honeypot has no route to anything else in the account (Phase 1, item 1).

**17:09** -- **Goal:** Create a security group for the honeypot.

- **What I did:** Created a dedicated security group in the VPC. Inbound rules: TCP 22 (SSH) and TCP 22022 (custom), both from My IP only. Outbound rules left at the default (all traffic) for now.
- **Decision and why:** Port 22 stays limited to my IP during testing. It is only opened to 0.0.0.0/0 after the CloudWatch pipeline is verified, so the first attacks aren't missed. Outbound gets locked down to 443 at the end of Phase 2.

**17:29** -- **Goal:** Launch the instance in the honeypot VPC.

|Setting|Value|
|---|---|
|AMI|Ubuntu Server 26 LTS|
|Instance type|t3.micro (x86_64)|
|VPC ID|vpc-0832c57455d382cef|

- **Decision and why:** x86_64 means the CloudWatch agent package to use later is **amd64**.
- **IMDSv2:** Set to required at launch. **Verification pending.** From the instance, `curl -s -o /dev/null -w "%{http_code}\n" http://169.254.169.254/latest/meta-data/` should print `401` if IMDSv2 is enforced (`200` means it isn't).

**17:34** -- Allocated an Elastic IP and associated it with the instance, so the address doesn't change on stop/start.

**17:45** -- **Goal:** First login from my own machine.

```bash
ssh -i .\key.pem ubuntu@<elastic-ip>
```

- **Result:** Login succeeded on port 22. SSH saved the host key to `known_hosts` on first connection, which is expected.
- **Problem:** The first attempt failed with `hostname contains invalid characters`. Cause: [not yet written]

#### Moving real SSH off port 22

**18:14** -- **Goal:** Move the real sshd to port 22022, so port 22 can be used by Cowrie later.

- **What I found:** Ubuntu starts SSH through `ssh.socket` (systemd socket activation), so editing `sshd_config` alone does not move the port. systemd owns the listening port.
- **First attempt:** Added a bare `ListenStream=22022` to the socket override (`sudo systemctl edit ssh.socket`).
- **Problem:** From a second terminal, SSH on 22022 returned `connection refused`. `ss -tlnp` showed the port listening on `[::]` (IPv6) only. Cause: the stock unit sets `BindIPv6Only=ipv6-only`, so a bare port number binds to IPv6 only.
- **Fix:** Listed each address explicitly in the override:

```ini
[Socket]
ListenStream=
ListenStream=0.0.0.0:22
ListenStream=[::]:22
ListenStream=0.0.0.0:22022
ListenStream=[::]:22022
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart ssh.socket
sudo ss -tlnp | grep -E ':22\b|:22022'
```

- **Result:** Login from the second terminal on 22022 succeeded. I kept the original session open until it did, as a way back in.
- **Lesson:** "Connection refused" (reached the instance, nothing listening) is different from a timeout (blocked by the security group). That tells you which layer to look at.

**18:25** -- Removed the port 22 lines from the override and restarted `ssh.socket`.

- **Result:** `ss -tlnp` shows sshd listening only on `0.0.0.0:22022` and `[::]:22022`, nothing on port 22. Port 22 is now free for the Cowrie redirect.

**18:31** -- Checked the security group inbound rules before leaving the instance running overnight.

- **Result:** Both rules (22 and 22022) are sourced from a single `/32` (my IP). No `0.0.0.0/0` inbound. Outbound is still the default all-traffic rule, which is expected until the end of Phase 2.

#### End of day status

- **Done:** VPC, security group, instance, Elastic IP, first login, real SSH moved to 22022.
- **Still to do:** IMDSv2 verification, `apt update && apt upgrade`, Cowrie install, Telnet config, iptables redirects + persistence, CloudWatch pipeline, opening 22/23 to 0.0.0.0/0, outbound lockdown to 443.

---

### 2026-11-11: Cowrie install, systemd service, and verification

#### Install and Telnet

-- **Goal:** Install Cowrie in a venv and confirm it runs.

- **What I did:** Created `~/honeypot` and a venv (`cowrie-env`, Python 3.14), installed Cowrie with pip, ran `cowrie init`, and enabled Telnet in `etc/cowrie.cfg`.
- **Result:** Cowrie runs and accepts logins on 2222. Listener check for Telnet on 2223: 
- **Deviation from plan:** The install directory is `~/honeypot`, not `~/my-honeypot` as first written. The doc and the CloudWatch config path were updated to match.

#### Making Cowrie a systemd service

 -- **Goal:** Run Cowrie as a service that starts on boot instead of by hand.

- **What I did:** Wrote `/etc/systemd/system/cowrie.service` pointing `ExecStart` at the venv's `cowrie start`, then ran `daemon-reload`, `restart`, and `enable --now`.
- **Problem 1:** `systemctl` reported `control process exited with error code`. The journal showed `FileNotFoundError` at `os.execvp` inside the `cowrie` launcher script.
- **Cause:** The launcher script builds a `twistd ...` command and runs it by name. When I run it from my shell, the venv's `bin/` is on `PATH`. Systemd starts services with a minimal `PATH`, so `twistd` was not found.
- **Fix:** Added `Environment="PATH=..."` with the venv's `bin/` first, and `WorkingDirectory=/home/ubuntu/honeypot`.
- **Problem 2:** After that, the status looked healthy (`active (running)`), but the screenshot was taken 32 ms after start. The journal later showed `cowrie: error: unrecognized arguments: -n`. I had added `-n` (no daemonize) from memory, and this version of the launcher does not accept it. Systemd retried until it hit `Start request repeated too quickly`.
- **Fix:** Skipped the launcher and called `twistd --nodaemon ...` directly in `ExecStart` (final unit file is in Phase 2).
- **Lesson:** A status check taken right after start proves nothing. Wait a few seconds and look again, and read the journal, not just `status`.

#### The duplicate-process trap

 -- **Problem:** Cowrie answered on 2222 and logged my test commands, yet `ss` showed the listener as `twistd` PID **61642** while the service's Main PID was **63704**. An older `twistd`, started by hand during earlier testing, was still holding port 2222. My test logins had gone to that process, not the service.

- **Fix:** `sudo kill 61642`, then `sudo systemctl restart cowrie`. Afterwards the `ss` listener PID (63861) matched the service Main PID (63861).
- **Lesson:** "Port answers" and "service is healthy" are different things. After any change, check that the PID on the port matches `systemctl status` Main PID.

#### Verification

- **Local login test:** `ssh -p 2222 root@localhost` returned the fake Debian banner and a `root@svr04:~#` prompt. Cowrie accepted `root` with an arbitrary password, which is its default.
- **Logging test:** Ran `whoami`, `ls`, and `exit`. `var/log/cowrie/cowrie.json` recorded each command (`cowrie.command.input`), the TTY log closing (`cowrie.log.closed`), and the session closing (`cowrie.session.closed`). Repeated against the systemd-managed process after the fix, with fresh timestamps after the restart.
- **Reboot test:** After `sudo reboot`, `twistd` was listening on 2222 and the service was `active (running)` with a low boot-time PID (617) matching the listener, with no manual start. The service survives reboots.
- **Note:** `src_ip` in these events is `127.0.0.1` because the tests came from the instance itself. Real attacker IPs will appear once ports are exposed.

#### iptables redirect

-- **Goal:** Redirect ports 22 and 23 to Cowrie (2222 and 2223).

- **What I did:** Added the two PREROUTING REDIRECT rules from Phase 2 and tested them. 
- **Check:** `sudo iptables -t nat -L PREROUTING -n` shows `REDIRECT tcp dpt:22 redir ports 2222` and `REDIRECT tcp dpt:23 redir ports 2223`. The destination column reads `0.0.0.0/0`, which is normal (the rules match on port, not destination address).
- **Persistence:** not yet confirmed. Check `/etc/iptables/rules.v4` for the two REDIRECT lines, and re-run the list command after a reboot.

#### CloudWatch agent

 -- **Goal:** Ship `cowrie.json` to CloudWatch Logs.

- **IAM role:** Created `EC2-CloudWatchAgent-Role` (trusted entity AWS service, use case EC2) with `CloudWatchAgentServerPolicy`, and attached it to the instance via Actions, Security, Modify IAM role.
- **Problem:** I started in the Create **user** wizard ("Specify user details"), which has no use-case step. Roles are under IAM, Roles, Create role. Users are for people and access keys, not for instance credentials.
- **Install:** SSH'd to the real admin port (`ssh -i key.pem -p 22022 ubuntu@<elastic-ip>`; landing in the fake `svr04` shell means I hit port 22 by mistake), installed the amd64 package, and ran the config wizard. Wizard answers and the saved config are in Phase 2.
- **Lesson:** Most wizard prompts default to "yes", but the answer I wanted was usually "no" (StatsD, CollectD, host metrics, X-Ray, journald). Read each prompt instead of pressing Enter.
- **Started agent** with the step 8 command. Events from the existing log file (including my earlier test sessions) appeared in the log group right away.
- **Filtering:** The log group's search box takes a JSON filter pattern, e.g. `{ $.eventid = "cowrie.command.input" }`.
- **Narrowing the policy:** Added the inline policy `cowrie-log-group-only`, then removed the managed policy. I deleted the managed policy before the new one existed, so the agent briefly had no permissions. No data was lost, since the agent tracks its position in the file. Better order next time: add the new policy first, then remove the old one.
- **Result:** After restarting the agent, a new `whoami` run in Cowrie appeared in CloudWatch. The narrowed policy works.

#### End of day status

- **Done:** Cowrie installed, Telnet enabled in config, systemd service created and enabled, local login and logging verified, reboot-tested, iptables redirects (22 -> 2222, 23 -> 2223) added and tested, CloudWatch agent configured and verified, IAM policy narrowed to the single log group.
- **Still to do:** confirm the iptables rules persist across a reboot (`/etc/iptables/rules.v4`), confirm the CloudWatch agent is enabled on boot (`systemctl is-enabled amazon-cloudwatch-agent`), Telnet listener check (2223), IMDSv2 verification, `apt update && apt upgrade` (before the outbound lockdown, since some mirrors use port 80), then open 22/23 to 0.0.0.0/0 and restrict outbound to 443 (last, in that order). Plus the open placeholders in the 2026-11-01 log (budget thresholds, `hostname contains invalid characters` cause).