"""Timestamped logging to the terminal and a rotating file, with secret redaction."""

from __future__ import annotations

import logging
import logging.handlers
from pathlib import Path

FORMAT = "%(asctime)s %(levelname)-7s %(name)s: %(message)s"


class RedactSecrets(logging.Filter):
    def __init__(self, secrets: list[str]):
        super().__init__()
        self._secrets = [s for s in secrets if s and len(s) >= 6]

    def filter(self, record: logging.LogRecord) -> bool:
        if self._secrets:
            msg = record.getMessage()
            redacted = msg
            for s in self._secrets:
                redacted = redacted.replace(s, "***")
            if redacted != msg:
                record.msg, record.args = redacted, None
        return True


def setup_logging(level: str = "INFO", log_file: str | None = None, secrets: list[str] | None = None) -> None:
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(level)
    redact = RedactSecrets(secrets or [])
    formatter = logging.Formatter(FORMAT)

    handlers: list[logging.Handler] = [logging.StreamHandler()]
    if log_file:
        Path(log_file).parent.mkdir(parents=True, exist_ok=True)
        handlers.append(logging.handlers.RotatingFileHandler(log_file, maxBytes=2_000_000, backupCount=5))
    for h in handlers:
        h.setFormatter(formatter)
        h.addFilter(redact)
        root.addHandler(h)

    # httpx logs every request URL at INFO; keep that quiet.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
