# swhw: SERVERware hardware report for DT Collector

`swhw` collects the hardware details of a SERVERware host and uploads them
to DT Collector as a hardware-only report. It needs no installation and no
PBXware access: only a SERVERware admin API token and a DT Collector upload
key.

## Run

From any Linux shell that can reach the SERVERware controller over HTTPS
and DT Collector over the internet (the controller itself works too):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/galijas/swhw/main/swhw.sh)
```

The script asks for:

1. the SERVERware controller: an IP address, DNS name, or URL
   (`https://10.1.101.10`, `http://sw.example.com` and `10.1.101.10` all work)
2. the SERVERware API key (an admin API token), which is checked right away
3. the DT Collector upload key (`dtk_...`), which is checked right away

Keys are read without echo. When SERVERware has several hosts (a cluster),
the script lists them and asks which one to report.

## What it does

1. Reads the Observability setting in SERVERware.
2. Enables Observability if it is disabled. This starts the SRW exporter,
   the only source of the SERVERware version.
3. Collects the host's hardware details from the SERVERware API and its
   Prometheus.
4. Restores Observability to its previous state (disabled again, if the
   script enabled it).
5. Uploads the report to DT Collector and prints the report ID.
6. Deletes its temporary directory and exits.

Observability is restored on every exit path, including errors and
Ctrl+C. If restoring fails, the script says so; disable it manually in
SERVERware under System Settings > Observability.

## Options

```
--controller ADDR  SERVERware controller (skips the prompt)
--host NAME        host to report (skips the host prompt on a cluster)
--dt-url URL       DT Collector address (default: https://dtcollector.dtbicom.xyz)
--dry-run          print the report instead of uploading it (no DT Collector key needed)
-h, --help         show help
-V, --version      show the version
```

Options go after the command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/galijas/swhw/main/swhw.sh) --dry-run
```

The prompts can also be answered through environment variables:
`SW_CONTROLLER`, `SW_TOKEN` and `DT_KEY`.

## Requirements

- `bash` and `curl`
- `jq` 1.5 or newer. If it is missing, the script downloads a static
  jq 1.7.1 build from GitHub into its temporary directory, verifies its
  SHA-256 checksum, and deletes it on exit.
- `gzip` (optional; the report is sent compressed when it is available)

## What the report contains

CPU model, sockets, cores, threads and maximum clock; memory size; system
vendor and model; motherboard and BIOS versions; disk models and types;
network link speeds; storage controller and NIC models; bond sizes; and the
SERVERware version and edition (standalone, mirror or cluster).

It never contains API keys, IP addresses, host or node names, VPS details,
serial numbers, asset tags or UUIDs (other than the random report ID).

## Security notes

- The controller's certificate is not verified, since SERVERware
  controllers typically use a self-signed certificate. DT Collector's
  certificate is always verified.
- Keys are passed to `curl` through temporary config files readable only by
  the current user, never on the command line, so they do not appear in
  the process list.
