# Agent Dusk — llama.cpp Inference Service on Bazzite

A repeatable build for Dusk's inference backend: `llama-server` from llama.cpp, on
Vulkan, in a rootless, capability-stripped Podman container, run by a dedicated
service account, managed by Quadlet, and deployed entirely from this repository.

Every directive here was validated on hardware unless it is marked otherwise.
Where a step exists because something failed during the build, the failure is
recorded in the [Troubleshooting appendix](#troubleshooting-appendix).

**Validated:** 2026-10-20 on Bazzite (`ghcr.io/ublue-os/bazzite-dx:stable`), host
`xtx`. The full [done-stamp cycle](#the-done-stamp-cycle) (A–E) passes, including
a purge from zero, a re-pull by digest returning the same image, and a cold boot.

---

## TL;DR

1. **Vulkan, not ROCm.** The `server-vulkan` image needs only the GPU render node.
   No `/dev/kfd`, no custom SELinux module, a narrower kernel interface.
2. **A dedicated `dusk` user runs it; root owns its definition.** Units live in
   `/etc/containers/systemd/users/<uid>/`. The service cannot edit its own config.
3. **The repo is the source of truth.** `base/` is host-agnostic, `hosts/<host>/`
   fulfils it. Deploying replaces the host's copy; it never merges.
4. **Nothing persistent and writable feeds the next start.** Digest-pinned image with
   `Pull=never`, read-only root filesystem, read-only weights (on the host *and* in
   the container), read-only key file.
5. **One lifecycle, six scripts.** Bootstrap, install, verify; teardown, verify-absent;
   and an `/etc` snapshot for proving teardown leaves nothing behind.

```bash
sudo scripts/bootstrap-bazzite.sh          # one-time host prep (idempotent)
sudo scripts/install-bazzite.sh            # deploy repo -> host
sudo tests/verify.sh                       # 13 checks
sudo scripts/teardown-bazzite.sh [--purge] # undeploy, or back to before bootstrap
sudo tests/verify-absent.sh [--purge]      # prove nothing is left
```

End state on `xtx`:

```
13/13 checks after a cold boot, with no login as dusk
Qwen3-VL-4B-Instruct Q4_K_M at 8k context:
  3.58 GB VRAM, 143-162 tok/s decode, load 1.3 s (warm page cache) / ~22 s (cold, gigabit NFS)
```

---

## Context

| Component | Value |
|---|---|
| Host | `xtx`: Bazzite (Fedora Atomic, ostree), KDE Plasma, SELinux enforcing |
| GPU | AMD Radeon RX 7900 XTX (gfx1100, RDNA3) at PCI `0000:0e:00.0` |
| Runtime | rootless Podman, `crun`, Quadlet |
| Image | `ghcr.io/ggml-org/llama.cpp:server-vulkan`, pinned by digest (pulled 2026-10-19). Authoritative value: `Image=` in `base/llama-dusk.container` |
| Model (smoke) | `Qwen/Qwen3-VL-4B-Instruct-GGUF`, `Qwen3VL-4B-Instruct-Q4_K_M.gguf`, text side only (no `--mmproj`). Commit not yet pinned |
| Model store | NFSv4.2 `192.168.2.188:/mnt/array/AIModels` mounted read-only at `/var/mnt/duskmodels` |
| Service identity | `dusk`: no login shell, member of `render` only |
| Endpoint | `http://127.0.0.1:8080/v1`, OpenAI-compatible; API key required on inference endpoints |

---

## Threat model

### What is being protected

This is a daily-driver desktop. The service shares a kernel with the browser, Steam,
Proton and your home directory. The goal: a compromised `llama-server` lands as an
unprivileged UID that owns nothing of yours, cannot change its own definition, and
has nowhere persistent to stage anything for its next start.

### Controls

| Control | Mechanism | Defends against |
|---|---|---|
| Separate identity | `dusk` user, `nologin`, own subuid range | An escape landing on a UID that owns your files |
| Definition the service can't write | Units root-owned under `/etc/containers/systemd/users/<uid>/` | The service rewriting its own flags or mounts for next start |
| Minimum device | Render node only, via `/dev/dri/dusk-render` | The KFD ioctl surface: `/dev/kfd` is never passed |
| No privileges | `DropCapability=all`, `NoNewPrivileges=true` | Capability abuse, setuid escalation |
| Read-only root filesystem | `ReadOnly=true` | Persistence inside the container |
| Read-only weights, twice | NFS mounted `ro` on the host, plus `:ro` on the bind | Weight tampering. On this host the `ro` mount is the *only* write control on the path: see the NAS note below |
| Single-file model mount | `Volume=<file>:/models/model.gguf:ro` | The server reading anything else on the share (a credential file was once found there) |
| Image provenance | Digest pin plus `Pull=never` | Tag or registry substitution; the serving unit never fetches code |
| Loopback publish | `PublishPort=127.0.0.1:8080:8080` | LAN exposure. Fedora's stock Workstation firewall zone opens 1025-65535 inbound; this host has a customised zone file. The loopback bind is the control either way |
| API key | Podman secret, file-mounted `0400`, read via `LLAMA_ARG_API_KEY_FILE` | Unauthenticated callers, and any web page in your browser calling `localhost` (the server allows every CORS origin by default). The key is never in the environment, the unit, the repo or a command line |
| Host preconditions, asserted | `verify.sh` fails if `docker`, `libvirt` or `incus-admin` has members | Passwordless root on the desktop account, which makes every control above moot |

### What this does not protect against

- **The render node is still a kernel interface.** Narrower than KFD, but a kernel
  driver all the same. Rootless limits where an escape lands; it does not narrow the
  ioctl surface.
- **The API key is not authorization.** It stops unauthenticated and cross-origin
  callers. Deciding which caller may do what belongs to the agent harness.
  `/health` and `/v1/models` answer without a key by design.
- **Egress.** The container can reach your LAN and the internet. Open item.
- **The built-in web UI** at `http://127.0.0.1:8080/` is enabled. Open item.
- **The deploy path.** Root runs scripts that `bazzite` can edit. Whoever controls the
  desktop account controls what gets deployed: read `git diff` before every install.
- **The NAS.** Root on this client was able to write into `AIModels/` over NFS, so
  the export is either `no_root_squash` or squashes everyone to UID 1000. Either way,
  the host's `ro` mount is the only thing keeping weights read-only. Open item.
- **Physical access.** Out of scope. SDDM autologin is configured on this host.

---

## Repository layout

```
dusk-iac/
├── base/
│   └── llama-dusk.container                   # the service, host-agnostic
├── hosts/
│   └── xtx/
│       ├── 70-dusk-gpu.rules                  # creates /dev/dri/dusk-render from the PCI address
│       ├── llama-dusk.container.d/
│       │   └── 20-model.conf                  # which model, and the sizing that fits this card
│       └── var-mnt-duskmodels.mount           # read-only, container-labelled NFS model store
├── node/                                      # Butane, for the CoreOS appliance (later)
├── scripts/
│   ├── bootstrap-bazzite.sh                   # identity, group, linger, API key
│   ├── install-bazzite.sh                     # deploy repo -> host
│   └── teardown-bazzite.sh                    # undeploy, or --purge back to before bootstrap
├── tests/
│   ├── verify.sh                              # 13 post-deploy checks
│   ├── verify-absent.sh                       # post-teardown checks
│   └── etc-snapshot.sh                        # content snapshot of /etc drift vs the image
└── docs/
    └── BUILD.md                               # this file
```

### The contract between `base/` and `hosts/`

`base/llama-dusk.container` asks for two things it does not define:

- **A GPU at `/dev/dri/dusk-render`.** Each host's udev rule creates it from that
  host's PCI address. The host's kernel can renumber render nodes; the name stays fixed.
- **A model at `/models/model.gguf`, plus its sizing.** Each host's drop-in supplies the
  `Volume=` line and the `LLAMA_ARG_*` sizing variables.

A new machine is a new `hosts/<name>/` directory and a `HOST=` change in
`install-bazzite.sh` and `verify.sh`. `base/` is not edited. See [Adding a host](#adding-a-host).

### The base unit, line by line

| Directive | Why |
|---|---|
| `Image=…@sha256:…` with `Pull=never` | Content-addressed, and the service cannot fetch. A missing image is a hard failure, never a silent pull. |
| `AddDevice=/dev/dri/dusk-render:/dev/dri/renderD128` | Stable host name in, fixed name inside. Podman follows the symlink (tested). The `/dev/dri/by-path/` names cannot be used: their colons collide with `--device`'s `host:container:perms` syntax. |
| `GroupAdd=keep-groups` | Carries `dusk`'s `render` membership into the user namespace. Implemented by `crun`; under `runc` it silently does nothing. |
| `DropCapability=all`, `NoNewPrivileges=true` | Vulkan enumeration and dispatch need neither (tested). |
| `ReadOnly=true` | Disables Mesa's shader disk cache (a warning in the logs). Accepted: load takes 1.3 s anyway, and a writable cache would be persistent state that the GPU driver reads at start. |
| `PublishPort=127.0.0.1:8080:8080` with `--host 0.0.0.0` | The container's network namespace is the boundary; the publish is the policy. Binding `127.0.0.1` *inside* the container would make the port unreachable. |
| `Secret=dusk-api-key,type=mount,…,mode=0400` with `Environment=LLAMA_ARG_API_KEY_FILE=…` | The environment carries only a path. `--api-key-file` also allows several keys, one per line, for rotation. |
| `Exec=-m /models/model.gguf --host 0.0.0.0 --port 8080` | No sizing flags here: command-line flags override environment variables, so `-c` or `-ngl` in `Exec=` would silently defeat the drop-in. |
| `Restart=on-failure`, `RestartSec=30` | Covers a NAS that is down at boot (`remote-fs.target` only *wants* the mount). |
| `WantedBy=default.target` | This is how a Quadlet unit is enabled. `systemctl enable` does not apply to generated units. |

The drop-in sets `LLAMA_ARG_CTX_SIZE` and `LLAMA_ARG_N_GPU_LAYERS`. Quadlet merges
`*.conf` files from `llama-dusk.container.d/` in alphabetical order.

### Boot chain

```
remote-fs.target ──wants──▶ var-mnt-duskmodels.mount   (ro, container_file_t)
        ▲
        │ After=
systemd-user-sessions.service
        ▲
        │ After=
user@<dusk-uid>.service   ◀── started by linger, with no login
        │
        └─ Quadlet generator ──▶ llama-dusk.service   (WantedBy=default.target)

udev ──▶ /dev/dri/dusk-render   (matched on PCI address)
```

Both ordering links were checked on `xtx`:
`systemctl show systemd-user-sessions.service -p After` contains `remote-fs.target`,
and `systemctl show user@1001.service -p After` contains `systemd-user-sessions.service`.
A user service cannot order itself against a system mount directly; this chain does it
without any reference between them.

---

## Lifecycle

### Spin up

```bash
sudo scripts/bootstrap-bazzite.sh
sudo scripts/install-bazzite.sh
sudo tests/verify.sh
```

**`bootstrap-bazzite.sh`** (idempotent; a second run changes nothing):

- refuses to run unless SELinux is enforcing and the OCI runtime is `crun`;
- creates `dusk` with no login shell, and confirms it received subuid/subgid ranges;
- copies the `render` line from `/usr/lib/group` into `/etc/group` if missing, then adds
  `dusk` to it (on ostree, `usermod` cannot edit groups that exist only in the image);
- enables linger, restarts `dusk`'s user manager if group membership changed;
- creates the `dusk-api-key` Podman secret if it does not exist.

**`install-bazzite.sh`** (rerun after any repo change):

1. installs the host's udev rule, re-triggers render nodes only (never display nodes,
   so KWin sees no hotplug), and refuses to continue if `/dev/dri/dusk-render` is missing;
2. installs the mount unit, stops the service, `reenable`s and `restart`s the mount, so
   option changes take effect and stale enable links are dropped;
3. pulls the image by digest only if it is not already present (the only network step);
4. replaces `dusk`'s Quadlet directory wholesale, reloads, restarts the service.

**`verify.sh`** waits up to three minutes for the model to load, then checks:

| Check | Proves |
|---|---|
| model store is read-only | the host mount enforces `ro` (the live mount, not just the unit file) |
| model store labelled `container_file_t` | the `context=` option applied; containers can read without `virt_use_nfs` |
| write to model store rejected | `ro` actually holds, tested by attempting a write |
| service active | the generated unit is running |
| model mounted from `/var/mnt/duskmodels` | the container reads through the hardened mount, not some other path |
| health ok | the model loaded |
| context size applied | the drop-in's `LLAMA_ARG_CTX_SIZE` reached the server (read from the server's own log line) |
| no key → 401, bad key → 401 | authentication is enforced on an inference endpoint |
| good key → 200 | the real key works and the GPU dispatches |
| no members in docker / libvirt / incus-admin | no passwordless path to root undermines the isolation |

### Changing anything

1. Edit the repo as `bazzite`.
2. `git diff`. You are about to run this as root.
3. `sudo scripts/install-bazzite.sh`
4. `sudo tests/verify.sh`
5. Commit.

Never edit the copies under `/etc`: the next deploy replaces them.

### Swapping the model

1. **Acquire as `bazzite`, never as `dusk`.** The serving identity must not be able to
   write its own weights. Download from the publisher's own organization, with the
   commit SHA in the URL rather than `main`. Replace every `<…>` before running:
   in bash, angle brackets are redirections.

   ```bash
   curl -L --fail -o /var/mnt/nas/AIModels/<org>/<repo>/<file>.gguf \
     "https://huggingface.co/<org>/<repo>/resolve/<commit-sha>/<file>.gguf"
   sha256sum /var/mnt/nas/AIModels/<org>/<repo>/<file>.gguf   # compare with the HF page
   ```

   Downloads go through the general read-write `/var/mnt/nas` mount; the service only
   ever sees the read-only `/var/mnt/duskmodels` mount of the same directory.
   GGUF is not pickle, but it is untrusted input to a C++ parser that has had
   vulnerabilities: official source, pinned commit, checked hash, read-only mount.
2. **Do the memory arithmetic** before deploying: weights + KV cache at the chosen
   context + compute buffers must fit in free VRAM. With the desktop running, about
   1.7 GB of the 24 GB card is already in use.
3. **Edit `hosts/xtx/llama-dusk.container.d/20-model.conf`:** the `Volume=` source path,
   `LLAMA_ARG_CTX_SIZE`, `LLAMA_ARG_N_GPU_LAYERS`, and the provenance comment
   (source, commit, file hash).
4. **Deploy and verify.** The context check reads its expected value from the drop-in,
   so it follows the change automatically.
5. **Measure placement from the kernel,** not the logs. See [Measuring](#measuring-where-memory-went).

### Tearing down

```bash
sudo scripts/teardown-bazzite.sh            # undeploy
sudo tests/verify-absent.sh                 # 9 checks

sudo scripts/teardown-bazzite.sh --purge    # back to before bootstrap
sudo tests/verify-absent.sh --purge         # 11 checks
```

| | plain | `--purge` |
|---|---|---|
| Service stopped, Quadlet directory removed | removed | removed |
| Every container in `dusk`'s account, including leftovers from manual tests | removed | removed |
| Model mount stopped, disabled, unit file removed, empty mount point removed | removed | removed |
| udev rule removed and `/dev/dri/dusk-render` dropped | removed | removed |
| `dusk` user, home directory, rootless storage (image, API key) | **kept** | removed |
| Linger flag, subuid/subgid ranges | **kept** | removed |
| `render` line in `/etc/group` | kept | kept: identical to the image's own entry |
| `bazzite` removed from `docker` / `libvirt` | kept | kept: host hardening, not Dusk |
| `container-kfd` SELinux module | untouched | untouched: belongs to the vLLM build |

After `--purge`, the next bootstrap generates a **new API key** (anything holding the old
one stops working), and the next install **re-pulls the image** by digest (network; the
same bytes, guaranteed by the digest).

Teardown is idempotent: running it twice must finish cleanly the second time. It
refuses to remove the mount unit while `/var/mnt/duskmodels` is still mounted.

### The done-stamp cycle

Run every step. Each one either passes or tells you exactly what was left behind.

```bash
# A. Start from nothing. Run the purge twice: the second run must be a clean no-op.
sudo scripts/teardown-bazzite.sh --purge
sudo scripts/teardown-bazzite.sh --purge
sudo tests/verify-absent.sh --purge                  # 11 PASS
sudo tests/etc-snapshot.sh > /tmp/etc-clean-1

# B. Spin up from zero.
sudo scripts/bootstrap-bazzite.sh
sudo scripts/install-bazzite.sh                      # re-pulls the image
sudo tests/verify.sh                                 # 13 PASS

# C. Plain teardown, then redeploy without bootstrap.
sudo scripts/teardown-bazzite.sh
sudo tests/verify-absent.sh                          # 9 PASS, dusk kept
sudo scripts/install-bazzite.sh
sudo tests/verify.sh                                 # 13 PASS

# D. Purge again; /etc must match step A.
sudo scripts/teardown-bazzite.sh --purge
sudo tests/verify-absent.sh --purge                  # 11 PASS
diff /tmp/etc-clean-1 <(sudo tests/etc-snapshot.sh)

# E. Final build, then a cold boot.
sudo scripts/bootstrap-bazzite.sh
sudo scripts/install-bazzite.sh
sudo tests/verify.sh                                 # 13 PASS
sudo systemctl reboot
# After boot, before anything runs as dusk:
loginctl list-sessions                               # note dusk's session IDs
for s in $(loginctl list-sessions --no-legend | awk '$3=="dusk"{print $1}'); do
  loginctl show-session "$s" -p Class -p Service -p TTY
done                                                 # every one: Class=manager, no TTY
sudo tests/verify.sh                                 # 13 PASS
```

Reading step D's `diff`:

- **No output** is the target.
- **Expected noise** is files that change on their own (`adjtime`, CUPS subscription
  files) and shadow-utils backup copies (`passwd-`, `group-`, `shadow-`, `gshadow-`,
  `subuid-`, `subgid-`), whose contents depend on the step before them.
- **`systemd/system.control/user@<uid>.service.d/` or `user-<uid>.slice.d/` entries**
  are per-user resource settings written by the desktop's resource manager for any
  active user, most likely `uresourced`, not by this repo.
- **Anything else is a teardown bug.** Fix the script, not the host, and rerun from A.

Step E's session check is the real linger proof. Current systemd registers a session
of class `manager` for every user manager, lingering ones included, so `dusk` *will*
appear in `loginctl list-sessions`. What must not appear is a `dusk` session of class
`user`: that would mean a real login. All `manager`, no TTY, plus a running service,
means linger alone started it. (The first version of this check tested for `dusk`'s
absence, and failed on a correct system.)

**Done** when A–E all pass.

---

## Operating

Run as root, or with `sudo`. Everything targets `dusk`'s user manager.

```bash
systemctl --user -M dusk@ status  llama-dusk.service
systemctl --user -M dusk@ restart llama-dusk.service
systemctl --user -M dusk@ stop    llama-dusk.service     # until the next boot or start
systemctl --user -M dusk@ start   llama-dusk.service
machinectl shell dusk@ /usr/bin/podman logs -f llama-dusk  # Ctrl+C to quit
```

To stop it starting at boot, remove `WantedBy=` from `[Install]` in the repo and redeploy.

Two ways to run things as `dusk`, which has no login shell (`su dusk` correctly fails):

- **`machinectl shell dusk@ <cmd>`** for interactive use. It opens a real session.
- **`systemd-run --machine=dusk@ --user --pipe --quiet --wait <cmd>`** in scripts and
  whenever output is captured. `machinectl shell` allocates a terminal, which mangles
  captured output.

### Using the API

```bash
KEY=$(sudo systemd-run --machine=dusk@ --user --pipe --quiet --wait \
  podman secret inspect --showsecret --format '{{.SecretData}}' dusk-api-key)

curl -s 127.0.0.1:8080/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hi."}]}'
```

Clients (the agent harness, OpenAI-compatible SDKs): base URL `http://127.0.0.1:8080/v1`
with that key. Keep the key in a password manager, not in a config file in your home
directory: anything that can read the file can use the model. Never print the key; to
check you captured it, `echo "${#KEY}"` should show 64.

### Measuring where memory went

The server's log level (verbosity 3) hides its buffer-placement lines. Ask the kernel:

```bash
cat /sys/class/drm/card*/device/mem_info_vram_used   # with the service running
sudo systemctl --user -M dusk@ stop llama-dusk.service
cat /sys/class/drm/card*/device/mem_info_vram_used   # stopped
cat /sys/class/drm/card*/device/mem_info_gtt_used    # stopped
sudo systemctl --user -M dusk@ start llama-dusk.service
```

- **VRAM freed by stopping ≈ weights + KV + compute buffers:** everything was on the GPU.
- **GTT (host memory the GPU maps over PCIe) dropping by gigabytes:** weights were
  spilled to system RAM. That is a large bandwidth cliff, and it happens silently.
- A few hundred MB of GTT while running is host-side staging, released on stop.

Measured on `xtx` with the 4B smoke model at 8k context: VRAM 5.27 → 1.70 GB
(**3.58 GB freed**), GTT 927 → 291 MB (staging only).

---

## Adding a host

1. Find the GPU's PCI address and confirm the vendor (`0x1002` is AMD):

   ```bash
   for n in /sys/class/drm/renderD*; do
     echo "$n vendor=$(cat "$n/device/vendor") pci=$(basename "$(readlink -f "$n/device")")"
   done
   ```

2. Create `hosts/<name>/` with:
   - `70-dusk-gpu.rules`, using that PCI address in `KERNELS==`;
   - a model store: the NFS mount unit, or a local path for an appliance with its own disk;
   - `llama-dusk.container.d/20-model.conf`, sized for that card.
3. Set `HOST=<name>` in `install-bazzite.sh` and `verify.sh`.
4. Layered validation before trusting the service:
   - **Enumeration.** The GPU crosses the container boundary:

     ```bash
     IMG=$(sed -n 's/^Image=//p' base/llama-dusk.container)
     sudo machinectl shell dusk@ /usr/bin/podman run --rm \
       --device /dev/dri/dusk-render:/dev/dri/renderD128 --group-add keep-groups \
       --cap-drop=ALL --security-opt no-new-privileges --network=none \
       "$IMG" --list-devices
     ```

     Expect a `Vulkan0` entry naming the card (RADV). Only `llvmpipe` means the device
     did not cross.
   - **Dispatch and serving.** Install, then `verify.sh`. `good key -> 200` means the
     GPU executed real work.
   - **Placement.** The sysfs VRAM/GTT measurement above.
5. Check the variable names against the pinned binary whenever the image changes:

   ```bash
   sudo machinectl shell dusk@ /usr/bin/podman run --rm --network=none "$IMG" --help 2>&1 \
     | grep -oE 'LLAMA_ARG_(CTX_SIZE|N_GPU_LAYERS|API_KEY_FILE)' | sort -u
   ```

   All three names must print. A missing one means that drop-in line is silently ignored.

On a stock Fedora or CoreOS host, the device nodes are `0660 root:render`, unlike
Bazzite's `0666`. That will be the first real test of the `render` group path: on
Bazzite the permissive mode masks it.

---

## Measured results

| Measurement | Value |
|---|---|
| Free VRAM reported by Vulkan in the container | 22,941 of 24,576 MiB (desktop running) |
| Desktop VRAM baseline (sysfs, service stopped) | 1.70 GB |
| Smoke model VRAM at 8k context (4 slots, unified KV) | 3.58 GB |
| Decode, Qwen3-VL-4B Q4_K_M | 143-162 tok/s (6.2-7.0 ms per token) |
| Model load, warm page cache | 1.3 s |
| Model load, cold over gigabit NFS | ~22 s |
| GTT while serving | +636 MB over a 291 MB baseline (staging, released on stop) |

Vulkan's free-memory figure (1,635 MiB in use) closely matched the host's sysfs reading
of the desktop's usage (1,618 MiB, taken at a different moment). In the vLLM build, ROCm's `hipMemGetInfo` inside a container could
not see other processes' VRAM at all. One sample is not proof: re-measure under load.

---

## Troubleshooting appendix

**`usermod -aG render dusk` exits 0, but `id dusk` doesn't show `render`.**
On ostree, image-shipped groups live in `/usr/lib/group`, which `usermod` cannot edit,
and it reports success anyway. Copy the line into `/etc/group` first (bootstrap does this).

**The group is in `id dusk`, but containers still can't open the device** (on a `0660` host).
`dusk`'s user manager kept the groups it started with. Restart `user@<uid>.service`.
Check what it actually holds: `grep Groups /proc/$(pgrep -u dusk -x systemd)/status`.

**`su dusk`: "This account is currently not available."**
Expected: `dusk` has `nologin`. Use `machinectl shell dusk@` or `systemd-run --machine=dusk@`.
`su -s /bin/bash` gives a shell with no `XDG_RUNTIME_DIR` and no user manager, so rootless
Podman misbehaves in confusing ways.

**`systemctl --user -M dusk@ …`: "Failed to connect to system scope bus … Permission denied."**
Run it as root. Only root can reach another user's manager, which is the point of the
separate identity.

**A variable captured from `machinectl shell` is empty or garbled.**
It allocates a terminal. Capture with `systemd-run --pipe` instead.

**`parsing reference "": repository name must have at least one component`.**
An empty variable: a new shell lost `IMG`. Derive it from the Quadlet
(`IMG=$(sed -n 's/^Image=//p' base/llama-dusk.container)`) and `echo` variables before use.

**`syntax error near unexpected token 'newline'` or `No such file or directory` around `<…>`.**
A placeholder was pasted literally. In bash, `<` and `>` are redirections.

**`--device /dev/dri/by-path/pci-0000:…-render` fails to parse.**
Podman splits `--device` on colons. Use the udev rule's colon-free `dusk-render` name.

**A container started with `-d --rm` vanished and left no logs.**
`--rm` deletes it on exit, logs included. Leave `--rm` off while debugging.

**`common_fit_params: failed to fit params to free device memory … abort`.**
Weights plus KV cache exceed free VRAM with `-ngl` pinned. If no context size was set,
recent builds use the model's full trained context, which can dwarf the weights.
Always set the context explicitly; choose a model that fits.

**A smoke-test model dies silently at load.**
Likely an architecture this build doesn't support (state-space and Mamba hybrids, for
example). Smoke-test with a standard transformer from the publisher's own organization,
so the test exercises the attention and KV-cache path the real workload uses.

**No `offloaded N/N layers` or buffer-size lines in the logs.**
Hidden at verbosity 3. Use the sysfs measurement, or run with `-lv 4`.

**Inference answers with no key, or with any key.**
The key isn't applied. `LLAMA_ARG_API_KEY` does not exist: `--api-key` reads
`LLAMA_API_KEY`, and this build uses `--api-key-file` via `LLAMA_ARG_API_KEY_FILE`.
Confirm any name with `--help` on the pinned image before using it. The log line
`security: no API key is set and CORS allows all origins` means no key is in effect.

**`/v1/models` or `/health` return 200 without a key.**
By design. Test authentication on `/v1/chat/completions`.

**The mount unit says `ro`, but `findmnt` shows `rw`.**
The live mount predates the edit. `daemon-reload` changes definitions, not running
state, and `enable --now` on an active unit does nothing. Stop the service, then
`systemctl reenable` and `restart` the mount (install now does this every time).

**An old `.wants` link survives a `WantedBy=` change.**
`enable` adds links for the current `[Install]` and never removes old ones. Use `reenable`.

**`Failed to create /root/.cache for shader cache (Read-only file system)`.**
Expected with `ReadOnly=true`, and accepted. See the base-unit table.

**`control-looking token … was not control-type`.**
A quirk in the model's metadata. Harmless.

**`LLAMA_ARG_HOST environment variable is set, but will be overwritten`.**
The image sets defaults; the command line wins. That is why sizing must stay out of `Exec=`.

**Every check passes, but the answers are nonsense.**
Model quality, not the stack: a 4B model at the default temperature (0.8). Raw
`/completion` calls also skip the chat template; use `/v1/chat/completions`.

**`verify.sh`: `docker has members` or `libvirt has members`.**
Passwordless root for that user. `sudo gpasswd -d <user> <group>`; it takes full effect
at the next login. For system VMs without the group, virt-manager prompts for a password
through polkit; for Docker-compatible tooling, use rootless Podman's socket.

**`verify-absent.sh`: `N container(s) left for dusk`.**
A container created outside the repo, typically a manual smoke test that was stopped
but never removed. A stopped container keeps its device, mount and port configuration,
ready to start; the one found during this build predated the API key, so starting it
would have served unauthenticated on 8080. List with
`sudo systemd-run --machine=dusk@ --user --pipe --quiet --wait podman ps -a`.
Teardown now removes every container in `dusk`'s account.

**Something from an earlier attempt is still on the host.**
`sudo ostree admin config-diff` lists every `/etc` path that differs from the image;
`tests/etc-snapshot.sh` adds content hashes so changes inside a file show up too.

---

## What we learned

- **Check the binary, not memory.** An assumed environment-variable name silently left
  authentication off. `--help` on the pinned image is the authority for flag and
  variable names.
- **Test the request that must fail.** The first authentication test passed with
  authentication completely disabled, because it only tried the request that should
  succeed, on an endpoint that is open anyway.
- **Definitions and running state are different things.** `daemon-reload` and `enable`
  change definitions; `restart` and remount change state. A deploy must do both.
- **Ask the kernel.** sysfs for VRAM placement, `findmnt` for live mount options, the
  audit log for denials. Applications' reports about themselves are guesses.
- **A smoke test must take the production path,** from a trusted source, at a size that
  removes "too big" as a variable. Two variables in one test produce failures that
  explain nothing.
- **Stable contracts make the base/host split work.** `base/` names
  `/dev/dri/dusk-render` and `/models/model.gguf`; each host fulfils them.
- **One source of truth.** The image digest lives only in the Quadlet; scripts and tests
  derive from it. Two copies of a fact eventually disagree.
- **Isolation is only as strong as its edges.** `bazzite` in `docker` and `libvirt` meant
  root without a password, which collapsed every boundary above it. Host preconditions
  now fail the verification.
- **"Assume nothing was applied" was false.** A mount unit from an earlier attempt had
  been live since Oct 14, with the old options. On ostree, `config-diff` answers what
  changed; snapshots answer what is inside.
- **Manual testing leaves state behind.** A stopped smoke-test container survived the
  whole build inside `dusk`'s account, carrying a pre-authentication configuration.
  A service account's teardown must own everything in that account, not just what the
  install created.
- **No persistent writable input to the next start.** That is the practical answer to
  "what could a compromised server change about its own next start?" The shader cache
  was declined for that reason, at a measured cost of zero.
- **On ostree, image-shipped groups live in `/usr/lib/group`,** and `usermod` silently
  does nothing for them.
- **User managers keep the groups they started with,** so group changes need a manager
  restart, the service-account equivalent of logging out and in.
- **Tooling details that bite:** `machinectl shell` breaks captured output;
  `--rm -d` destroys evidence; `--device` cannot take paths containing colons;
  `pipefail` with `grep -q` reports false failures.

---

## Open items

- [x] Run the done-stamp cycle (A–E). Passed 2026-10-20.
- [ ] Egress lockdown for the serving container.
- [ ] API surface audit: the built-in web UI, `/slots`, `/props`, the CORS policy.
      Confirm the relevant flags in `--help`.
- [ ] Parallel slots: the server defaulted to 4 slots sharing one 8k KV pool. Dusk is
      single-user; decide the slot count and confirm its variable name in `--help`.
- [ ] Pin the smoke model by commit SHA and record its hash in the drop-in comment.
- [ ] Decide on `container-kfd`: keep it for the ROCm A/B and vLLM work, with its `.te`
      file committed wherever that work lives, or remove it with `semodule -r`.
- [ ] NAS export squash settings (`/etc/exports` on the Pi).
- [ ] Test with `virt_use_nfs` off. The mount's `context=` option should make it unnecessary.
- [ ] Re-measure Vulkan's free-memory accuracy under desktop load.
- [ ] Dusk's real model, and the Vulkan vs ROCm A/B, measuring prefill and decode separately.
- [ ] Butane (`node/`) for the CoreOS appliance: the same `base/`, a new host directory.
- [ ] Host hardening outside Dusk: `/dev/kfd` is `0666` on Bazzite.

---

## Document maintenance

```
Last verified : 2026-10-20  done-stamp cycle A–E passed, including cold boot
Host          : xtx, Bazzite (ghcr.io/ublue-os/bazzite-dx:stable)
Image         : ghcr.io/ggml-org/llama.cpp:server-vulkan
                @sha256:fa677644887843555b844fdcdb8756c7bae39ddb03db25e83c3d5f3472bd3a10
Model         : Qwen3-VL-4B-Instruct Q4_K_M (smoke test)
GPU           : Radeon RX 7900 XTX (gfx1100) at 0000:0e:00.0
```

Update this document, and rerun the full done-stamp cycle, when:

- the image digest changes: recheck the variable names with `--help`;
- the model changes: redo the memory arithmetic, and do not carry old sizing forward;
- any script changes;
- a host is added;
- an open item closes.
