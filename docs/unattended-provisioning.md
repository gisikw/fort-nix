# Unattended provisioning

Fort can install a preassigned NixOS host by booting one reusable USB drive. No live-CD account setup, temporary SSH exposure, laptop-side `nixos-anywhere`, or post-install `just assign` is required.

## Operator workflow

### 1. Preassign the logical host

Add the host normally under `clusters/bedlam/hosts/<name>`, but use `device = "pending";`, and add its installation profile to `provisioning/targets.json`:

```json
[
  { "host": "newbox", "profile": "beelink" }
]
```

The pending host is not evaluated until the installer privately substitutes the hardware UUID. After a successful run, the registrar command below commits the real device entry and updates the host manifest.

### 2. Create the reusable USB

Create one high-entropy fleet bootstrap credential, encrypt it as `apps/provisioner/bootstrap-secret.sops`, and retain a local plaintext copy with mode `0600` for image creation.

```bash
export FORT_BOOTSTRAP_SECRET_FILE=$HOME/.config/fort/provision-bootstrap-secret
just boot-drive /dev/sdc
```

The command refuses mounted drives and non-USB transports, displays model/serial/size, and requires typing the exact device path before `sudo dd`. The secret is baked into the immutable ISO. Treat the drive as a cluster credential and rotate both the server secret and image if it is lost.

### 3. Arm and boot

1. Open `https://provision.gisi.network` and authenticate as an admin.
2. Press **Arm** beside the intended host. This creates one global five-minute lease; arming another host replaces it.
3. Boot the target from the USB during that window.
4. The first device presenting the fleet credential atomically claims the lease. Further devices are rejected.
5. The installer fingerprints hardware, generates a fresh host SSH key, reports the resulting device entry, waits while the controller prepares and rekeys a private host-specific source snapshot, partitions the target according to the assigned profile, installs the full host configuration, and reboots.

### 4. Register the completed device

The broker deliberately does not mutate the durable Git checkout. It builds a private rekeyed snapshot for installation; after installation, apply its completion artifact from the fort-nix checkout:

```bash
just register-provisioned newbox
```

Review, commit, and push the generated device and host changes. Remove the host from `provisioning/targets.json` once it has a durable device assignment.

## Security model

- The USB fleet secret proves that a claimant has the controlled boot medium. It is necessary but insufficient: no machine receives source or an identity unless a human has armed a host.
- The dashboard is protected by Fort identity SSO and the `admin` group. The service also refuses browser actions without the trusted identity header and rejects cross-origin mutations.
- Exactly one global lease exists. It expires after five minutes, and claim is serialized under the broker lock before a one-time 256-bit token is returned.
- The source archive and completion API require that claim token. Completion consumes it.
- TLS terminates through the normal Fort public service path. The machine endpoints bypass browser SSO but authenticate at the application layer.
- Host SSH keys are generated on the booted device and never traverse the network privately.
- The static secret prevents random internet callers from consuming armed leases. It does **not** distinguish two copies of the authorized USB; the one-device property comes from the narrow, one-shot lease.

## Failure behavior

Before disk partitioning, failures are retried or stop visibly on tty1. A lease claim remains consumed to avoid letting a second machine inherit the identity after an ambiguous partial failure; disarm and re-arm explicitly to retry. The client reports its hardware metadata before destructive work. The controller then inserts the device and generated public key into a private source copy and reruns `rekey`, ensuring the installed host can decrypt its assigned secrets on first boot; the registrar artifact normally exists even if installation later fails.

## Validation

```bash
just test-provisioner
just build-boot-image
just test-boot-image
```

`test-boot-image` boots the actual ISO under QEMU with serial console output and requires the systemd provisioning client marker. This establishes that firmware can load the hybrid ISO, Linux and userspace start, systemd reaches the unattended unit, and the baked credential is readable. It does not prove a particular physical machine's UEFI/NIC support or execute destructive disk installation; the first real box remains the hardware integration test.

## Decisions and open questions

Decisions made here:

- a single global lease rather than one live lease per host, because the operator is physically provisioning one box and wants accidental parallel claim to fail closed;
- a fleet credential plus short human lease, not hardware-MAC preauthorization (MAC/DMI identity is not trustworthy before enrollment);
- immutable source snapshot after claim, rather than a forge deploy token on the USB;
- Git mutation is performed by an explicit registrar, not by the internet-facing broker;
- generated per-device SSH identity, preserving the existing sops recipient model.

Open questions before calling the physical path fully proven:

- Whether the HP t640 needs extra firmware in the installer image (the stock NixOS ISO is broad, but only a physical boot proves this).
- Whether to move the broker from drhorrible to a Reaches coordinator when that trust plane exists.
- Whether completion registration should become an authenticated Kobold workflow after the initial manual-review phase.
- The image currently targets x86_64 UEFI/BIOS machines. Raspberry Pi provisioning needs a separate SD-card image and profile-specific boot path.
- A compromised fleet USB can race an intentionally armed lease. Rotation/revocation is whole-fleet in this first version; per-drive credentials would improve attribution and revocation.
