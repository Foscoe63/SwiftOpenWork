from .retry import retry_with_backoff


def fetch(url):
    return retry_with_backoff(lambda: url)
