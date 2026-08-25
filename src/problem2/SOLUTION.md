# Problem 2: Diagnose Me Doctor

<aside>
⏰ Duration: You should not spend more than **12 hours** on this problem.
*Time estimation is for internship roles, if you are a software professional you should spend significantly less time.*

</aside>

# Task

Provide steps to troubleshoot two production issues.

### Scenario

You are working as a DevOps Engineer on a cloud-based infrastructure where a virtual machine (VM), running Ubuntu 24.04, with 64GB of storage is under your management. Recently, your monitoring tools have reported that the VM is consistently running at 99% storage usage. This VM is responsible for only running one service - a NGINX load balancer as a traffic router for upstream services. 

### Challenge

Describe how you would troubleshoot the issue, and what causes/scenario do you expect to encounter, as well as what are the impacts and recovery steps for each possible root cause.

---

# Solution

## 1. Classify the cause immediately.

At 99% on a 64GB disk, the VM is one bad log burst away from 100% and a total outage (NGINX can hang on writes, SSH/cron/systemd can fail, cert renewal breaks). Before deep-diving root cause, buy more space or free some space immediately. The first step is to classify the cause of the disk usage:

```bash
# Confirm it's actually block space, not inodes
df -h

# Find which top-level mount/dir is heavy
du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -20

# Drill into the worst offender
du -xh --max-depth=2 /var 2>/dev/null | sort -rh | head -20
```

If a log file is the culprit and something still has it open, **truncate, don't delete** - `rm` on a file a live process holds open doesn't free space until the process closes/reopens it:

```bash
: > /var/log/nginx/access.log   # truncate in place, safe for an open file handle
journalctl --vacuum-size=200M   # reclaim journald space immediately
apt-get clean                   # drop downloaded .deb cache
```

## 2. Systematic Diagnosis

```bash
# 1. Inode exhaustion look-alike (df shows 99% used but du shows little data = tons of tiny files)
df -i

# 2. Largest directories tree-wide
ncdu / --exclude /proc          # or: du -xh --max-depth=3 / | sort -rh | head -30

# 3. Files deleted but still held open by a process (classic "phantom" disk usage)
lsof +L1 | grep -i deleted

# 4. NGINX-specific paths
du -sh /var/log/nginx/* /var/lib/nginx/* /var/cache/nginx/* 2>/dev/null

# 5. journald usage
journalctl --disk-usage

# 6. Package cache / orphaned kernels
du -sh /var/cache/apt/archives
dpkg -l | grep linux-image | wc -l

# 7. Core dumps
find / -xdev -iname 'core*' -size +5M 2>/dev/null
coredumpctl list 2>/dev/null

# 8. Volume vs filesystem size mismatch (cloud disk resized but partition/FS never grown)
lsblk
df -h /
```

## 3. Root Causes, Impact, and Recovery

| # | Root Cause | How to Confirm | Impact if Unaddressed | Recovery |
|---|-----------|-----------------|------------------------|----------|
| 1 | **Unrotated / runaway NGINX access & error logs** (no `logrotate`, misconfigured rotation, or verbose `error_log debug;` left on) | `du -sh /var/log/nginx/*`; check `logrotate.status` and `cat /etc/logrotate.d/nginx` | Disk fills continuously; once at 100%, NGINX can't write logs (may stall or error on write syscalls), `certbot` renewals fail silently → future cert expiry outage | Truncate/rotate now; fix or install a proper `/etc/logrotate.d/nginx` (daily, compress, `rotate 7`, `copytruncate` so NGINX's open FD stays valid); ship logs off-box (rsyslog/Fluent Bit → CloudWatch/ELK) so local retention can be short |
| 2 | **journald unbounded** - no `SystemMaxUse` cap in `journald.conf`, persistent logging accumulating in `/var/log/journal` | `journalctl --disk-usage` | Slowly consumes disk in the background even with light traffic; symptom is easy to miss since it's not in `/var/log/nginx` | `journalctl --vacuum-size=200M`; set `SystemMaxUse=200M` in `/etc/systemd/journald.conf`, `systemctl restart systemd-journald` |
| 3 | **Cloud volume resized but filesystem never grown** - someone expanded the disk in the console/API but never ran `growpart`/`resize2fs` | `lsblk` shows a larger block device than `df -h /` reports as filesystem size | Team believes they "fixed" capacity but usage % doesn't budge - false sense of security while actual free space stays the same | `growpart /dev/xvda 1` (or provider's NVMe device name) then `resize2fs /dev/xvda1` (ext4) or `xfs_growfs /` (XFS) |
| 4 | **NGINX temp-buffer files piling up** (`client_body_temp_path`, `proxy_temp_path`) from large/slow uploads, slow upstreams, or a deliberate slow-POST style DoS | `du -sh /var/lib/nginx/* /var/cache/nginx/*` while under load | Under traffic spikes this can fill disk in minutes, not days - most acute of the bunch | Tune `client_max_body_size`, `proxy_buffering`/`proxy_max_temp_file_size`; add per-IP rate limiting (`limit_req`, `limit_conn`); move temp dirs to a dedicated, larger volume so this can't starve the root disk |
| 5 | **Malicious / abusive traffic used as a disk-fill DoS** (log flooding via crafted requests, zip-bomb style uploads, deliberate large slow uploads) | Spike correlates with unusual traffic in access logs; unfamiliar source IPs, unusual request patterns | Availability incident - this is a DoS vector against a single-purpose LB, and depending on entry point could indicate broader compromise attempt | Block/rate-limit offending IPs (WAF or `nginx` rate limiting/`fail2ban`), rotate any exposed credentials, review for signs of compromise before assuming "just noisy traffic" |

## 4. General Impact of Reaching 100% on This VM

Because this VM's sole job is routing traffic, disk exhaustion affects it indirectly but severely:
- NGINX workers can hang or error on any disk write (logs, temp buffer files), degrading or dropping connections despite CPU/network being fine.
- SSH, cron, `systemd`, and `journald` can all fail to write, making the box hard to even log into or diagnose remotely - worth keeping an out-of-band console/SSM access path for exactly this scenario.
- Any monitoring/agent process that buffers to local disk can crash right when visibility is most needed.

## 5. Longer-Term Prevention

- Alert at **70%/85%** disk usage, not 99% - give the team time to react before impact.
- Put `/var/log` (and NGINX temp dirs) on a **separate volume** from `/`, so log growth can never starve the OS/root filesystem.
- Ship logs to a centralized system (CloudWatch, ELK, Loki) and keep local retention short (24–72h).
- Enforce `logrotate` with `compress`, `rotate N`, `maxsize`, and `copytruncate` for any log NGINX holds open.
- Automate volume-resize + filesystem-grow as a single IaC step so cause #3 can't recur.