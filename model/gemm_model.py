"""Golden model and test-vector generator for the INT8 GEMM accelerator.

  a.hex      A stored transposed (K x M), 4 INT8 per word, little-endian
  b.hex      B row-major (K x N), 4 INT8 per word, little-endian
  c_exp.hex  expected C row-major (M x N), one INT32 per word
  dims.hex   M, N, K (one per line)

Usage:
  python3 model/gemm_model.py --m 8 --n 8 --k 16 --seed 1 --out build/vec
  python3 model/gemm_model.py --selftest
"""

import argparse
import os
import sys

import numpy as np

MAX_M, MAX_N, MAX_K = 64, 64, 256
MODES = ("random", "min", "max", "minmax", "identity")


def gemm(a, b):
    """C = A @ B with INT8 inputs and INT32 accumulation."""
    assert a.dtype == np.int8 and b.dtype == np.int8
    # Cast first: int8 @ int8 wraps silently in numpy.
    return a.astype(np.int32) @ b.astype(np.int32)


def make_matrices(m, n, k, mode, rng):
    if mode == "random":
        a = rng.integers(-128, 128, (m, k), dtype=np.int8)
        b = rng.integers(-128, 128, (k, n), dtype=np.int8)
    elif mode == "min":
        a = np.full((m, k), -128, np.int8)
        b = np.full((k, n), -128, np.int8)
    elif mode == "max":
        a = np.full((m, k), 127, np.int8)
        b = np.full((k, n), 127, np.int8)
    elif mode == "minmax":
        a = np.full((m, k), -128, np.int8)
        b = np.full((k, n), 127, np.int8)
    elif mode == "identity":
        # A random, B = identity (padded with zeros), so C = A[:, :n] when k >= n
        a = rng.integers(-128, 128, (m, k), dtype=np.int8)
        b = np.eye(k, n, dtype=np.int8)
    else:
        raise ValueError(f"unknown mode {mode}")
    return a, b


def pack_bytes(x):
    """Flatten an INT8 array row-major and pack 4 values per little-endian word."""
    flat = np.ascontiguousarray(x, dtype=np.int8).reshape(-1)
    assert flat.size % 4 == 0
    return flat.view("<u4")


def pack_a(a):
    return pack_bytes(a.T)   # word k*(M/4) + i/4 holds A[i..i+3][k]


def pack_b(b):
    return pack_bytes(b)     # word k*(N/4) + j/4 holds B[k][j..j+3]


def pack_c(c):
    return np.ascontiguousarray(c, dtype="<i4").reshape(-1).view("<u4")


def unpack_c(words, m, n):
    return np.asarray(words, dtype="<u4").view("<i4").reshape(m, n)


def write_hex(path, words):
    with open(path, "w") as f:
        for w in words:
            f.write(f"{int(w) & 0xFFFFFFFF:08x}\n")


def read_hex(path):
    with open(path) as f:
        return np.array([int(line, 16) for line in f if line.strip()], dtype="<u4")


def check_dims(m, n, k):
    if not (4 <= m <= MAX_M and m % 4 == 0):
        sys.exit(f"M={m}: must be a multiple of 4 in 4..{MAX_M}")
    if not (4 <= n <= MAX_N and n % 4 == 0):
        sys.exit(f"N={n}: must be a multiple of 4 in 4..{MAX_N}")
    if not (1 <= k <= MAX_K):
        sys.exit(f"K={k}: must be in 1..{MAX_K}")


def generate(m, n, k, mode, seed, out):
    check_dims(m, n, k)
    rng = np.random.default_rng(seed)
    a, b = make_matrices(m, n, k, mode, rng)
    c = gemm(a, b)
    os.makedirs(out, exist_ok=True)
    write_hex(os.path.join(out, "a.hex"), pack_a(a))
    write_hex(os.path.join(out, "b.hex"), pack_b(b))
    write_hex(os.path.join(out, "c_exp.hex"), pack_c(c))
    write_hex(os.path.join(out, "dims.hex"), [m, n, k])
    print(f"vectors: M={m} N={n} K={k} mode={mode} seed={seed} -> {out}")


def selftest():
    rng = np.random.default_rng(0)

    # gemm matches a naive triple loop
    for m, n, k in [(4, 4, 1), (8, 12, 7), (4, 8, 256)]:
        a, b = make_matrices(m, n, k, "random", rng)
        c = gemm(a, b)
        for i in range(m):
            for j in range(n):
                assert c[i, j] == sum(int(a[i, x]) * int(b[x, j]) for x in range(k))

    # worst case fits easily in INT32
    a, b = make_matrices(4, 4, MAX_K, "min", rng)
    assert gemm(a, b)[0, 0] == MAX_K * 128 * 128

    # word layout: byte 0 of a word is the lowest index
    a = np.arange(16, dtype=np.int8).reshape(4, 4)    # A[i][k] = 4*i + k
    assert pack_a(a)[0] == 0x0C080400                 # A[0..3][0] = 0, 4, 8, 12
    assert pack_b(a)[0] == 0x03020100                 # B[0][0..3] = 0, 1, 2, 3
    assert pack_bytes(np.array([-1, -128, 127, 0], np.int8))[0] == 0x007F80FF

    # C round trip, including negatives
    c = rng.integers(-2**31, 2**31, (8, 4), dtype=np.int32)
    assert (unpack_c(pack_c(c), 8, 4) == c).all()

    print("selftest passed")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--m", type=int, default=4)
    p.add_argument("--n", type=int, default=4)
    p.add_argument("--k", type=int, default=16)
    p.add_argument("--mode", choices=MODES, default="random")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--out", default="build/vec")
    p.add_argument("--selftest", action="store_true")
    args = p.parse_args()

    if args.selftest:
        selftest()
    else:
        generate(args.m, args.n, args.k, args.mode, args.seed, args.out)


if __name__ == "__main__":
    main()
