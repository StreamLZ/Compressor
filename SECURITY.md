# Security Policy

## Safe for Untrusted Input

StreamLZ is designed to handle untrusted compressed data safely. The
decompression pipeline validates all header fields, chunk boundaries,
entropy table parameters, and pointer arithmetic before accessing memory.

Use `TryDecompress` or `DecompressFramed` for untrusted data — these
APIs return `false` or throw managed exceptions on corrupt input rather
than crashing the process.

For maximum safety when processing untrusted data:
- Enable content checksums (`useContentChecksum: true`)
- Prefer the framed APIs (`CompressFramed` / `DecompressFramed`)
- Set `maxThreads` conservatively in server environments

## Testing

The decoder is fuzz-tested with brute-force mutation across all codec
levels (L1 through L11) and the framed API. Mutations include bit flips,
truncation, zeroed sections, duplicated blocks, and randomized headers.

## Reporting a Vulnerability

If you discover a security vulnerability, please report it privately via
GitHub's Security Advisories:

https://github.com/StreamLZ/Compressor/security/advisories/new

Do not open a public issue for security vulnerabilities.
