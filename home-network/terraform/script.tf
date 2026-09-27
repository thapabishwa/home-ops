# The ISP reputation controller and its scheduler. Terraform owns all of it
# including the body, so editing scripts/isp-control.src and running
# `terragrunt apply` is the whole deploy.
#
# WARNING: Terraform does not check the body. RouterOS stores a script as an
# opaque string and parses it only when it runs, so a syntax error applies
# cleanly and then shows up as missing heartbeat lines. After any apply that
# changes the body, run it once by hand and read what it prints:
#
#   /system script run ISP-control

# Comments and blank lines stripped: 17KB of annotated source becomes under 6KB
# on the router, and `/export` stays readable.
locals {
  script_source = {
    for name in ["isp-control", "isp-probe-why"] : name => join("\n", [
      for line in split("\n", file("${path.module}/scripts/${name}.src")) :
      trimspace(line)
      if trimspace(line) != "" && !startswith(trimspace(line), "#")
    ])
  }
}

resource "routeros_system_script" "isp_control" {
  name                     = "ISP-control"
  policy                   = ["read", "write", "test"]
  dont_require_permissions = false
  # Generated from scripts/isp-control.src. Do not edit it on the router: the
  # next apply puts the generated body back.
  source = local.script_source["isp-control"]
}

# 1 second, and that does NOT retune the scoring.
#
# The EWMA, hold timer and heartbeat are all counted in ticks, so this would
# normally be dangerous. The script runs at two rates instead: emergency
# demotion every pass, scoring every tenth. ispTick still advances once per
# 10s, so ispHold 90 is still 15 minutes and `a = 995` still decays per 10s.
#
# What it buys is the failover floor: ~1.2s probe interval + 0.5s timeout + 1s
# tick, against a full 10s tick before.
resource "routeros_system_scheduler" "isp_control" {
  name     = "isp-control"
  comment  = "ISP reputation controller"
  interval = "1s"
  on_event = "/system/script/run ISP-control"

  # Broader than the script's read,write,test because a scheduler cannot grant
  # a policy it does not hold. Narrowing it is a live change to failover
  # behaviour -- maintenance window, not a drive-by.
  policy = [
    "ftp", "reboot", "read", "write", "policy",
    "test", "password", "sniff", "sensitive", "romon",
  ]

  start_date = "2026-09-20"
  start_time = "08:39:35"

  lifecycle {
    # RouterOS rewrites these as the schedule advances.
    ignore_changes = [start_date, start_time]
  }

  depends_on = [routeros_system_script.isp_control]
}

# Why a probe failed -- see scripts/isp-probe-why.src. Its own scheduler so a
# re-test blocking on its timeout can never delay the controller.
resource "routeros_system_script" "isp_probe_why" {
  name                     = "ISP-probe-why"
  policy                   = ["read", "write", "test"]
  dont_require_permissions = false
  source                   = local.script_source["isp-probe-why"]
}

resource "routeros_system_scheduler" "isp_probe_why" {
  name     = "isp-probe-why"
  comment  = "re-test failed probes and log why"
  interval = "10s"
  on_event = "/system/script/run ISP-probe-why"
  policy   = ["read", "write", "test"]

  lifecycle {
    ignore_changes = [start_date, start_time]
  }

  depends_on = [routeros_system_script.isp_probe_why]
}
