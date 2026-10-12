def retry(fn, times=3):
    """Not the one you are looking for."""
    for _ in range(times):
        try:
            return fn()
        except Exception:
            pass
