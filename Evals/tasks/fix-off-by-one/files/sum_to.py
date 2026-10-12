def sum_to(n):
    """Return 1 + 2 + ... + n."""
    total = 0
    for i in range(1, n):
        total += i
    return total
