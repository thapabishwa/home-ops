# Log retention. The memory log is the only durable record of what the
# controller did -- Prometheus samples gauges every 30s and misses anything
# shorter. It was seven hours before these changes.
#
# Both resources are RouterOS defaults, so both were adopted with `import`
# rather than created. If either is ever destroyed from state it must be
# re-imported at the same id (*1 info rule, *0 memory action), not created:
# RouterOS will not accept a second rule for a default topic set.

# 1. Stop logging /tool/fetch -- 27.6% of the buffer, and every line is
# immediately followed by an ISP-probe-why line carrying the same error already
# interpreted. The duplication peaks exactly when the history matters, since
# probe-why fires three fetches per 10s while a link is down.
#
# `account` is deliberately NOT excluded despite being another 15%. Most of it
# is a container re-authenticating every ten minutes, but the rest is the audit
# trail of who logged into the router; the container should hold its session
# instead.
import {
  to = routeros_system_logging.info
  id = "*1"
}

resource "routeros_system_logging" "info" {
  topics = ["info", "!fetch"]
  action = "memory"
}

# 2. A bigger buffer: 1000 -> 10000 lines, ~1.5MB against 424MB free. 1000 was
# simply the RouterOS default. Combined with dropping fetch this takes the
# window from ~7 hours to over a hundred -- though a link flapping hard can
# still burn it down to under two, since netwatch events dominate the buffer.
import {
  to = routeros_system_logging_action.memory
  id = "*0"
}

resource "routeros_system_logging_action" "memory" {
  name         = "memory"
  target       = "memory"
  memory_lines = 10000
}
