import logging
import os


def configure() -> None:
    level = os.environ.get("LLAMACPP_WRAP_LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        level=getattr(logging, level, logging.INFO),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
