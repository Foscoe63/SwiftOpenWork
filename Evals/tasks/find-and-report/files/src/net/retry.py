import time


def retry_with_backoff(fn, max_attempts=5, base_delay=0.5):
    for attempt in range(max_attempts):
        try:
            return fn()
        except Exception:
            time.sleep(base_delay * 2 ** attempt)
    raise RuntimeError("gave up")
