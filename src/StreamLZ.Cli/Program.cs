using System.Buffers.Binary;
using System.Diagnostics;
using System.Globalization;
using StreamLZ;
using StreamLZ.Common;
using StreamLZ.Compression;
using StreamLZ.Decompression;

unsafe
{

    // Parse args
    string? inputFile = null;
    string? outputFile = null;
    string? iniPath = null;
    string mode = "c"; // c = compress, d = decompress, b = benchmark
    int level = Slz.DefaultLevel;
    int runs = 1;
    int threads = 0; // 0 = auto

    for (int i = 0; i < args.Length; i++)
    {
        switch (args[i])
        {
            case "-c": mode = "c"; break;
            case "-d": mode = "d"; break;
            case "-b": mode = "b"; break;
            case "-bc": mode = "bc"; break;
            case "-db": mode = "db"; break;
            case "-iotest": mode = "iotest"; break;
            case "-l" when i + 1 < args.Length: level = int.Parse(args[++i], CultureInfo.InvariantCulture); break;
            case "-r" when i + 1 < args.Length: runs = int.Parse(args[++i], CultureInfo.InvariantCulture); break;
            case "-t" or "--threads" when i + 1 < args.Length: threads = int.Parse(args[++i], CultureInfo.InvariantCulture); break;
            case "--ini" when i + 1 < args.Length: iniPath = args[++i]; break;
            case "-o" when i + 1 < args.Length: outputFile = args[++i]; break;
            default:
                if (!args[i].StartsWith('-'))
                    inputFile = args[i];
                break;
        }
    }

    // Load cost coefficients from INI file (explicit path or auto-detect next to exe)
    if (iniPath == null)
    {
        string exeDir = AppContext.BaseDirectory;
        string autoIni = Path.Combine(exeDir, "StreamLZ.ini");
        if (File.Exists(autoIni))
            iniPath = autoIni;
    }
    if (iniPath != null)
    {
        CostCoefficients.Load(iniPath);
        Console.WriteLine($"Loaded cost coefficients from: {iniPath}");
    }

    if (inputFile == null)
    {
        Console.WriteLine("Usage: streamlz-cli [options] <input-file>");
        Console.WriteLine("  -c              Compress (default)");
        Console.WriteLine("  -d              Decompress");
        Console.WriteLine("  -b              Benchmark (compress + decompress, verify round-trip)");
        Console.WriteLine("  -bc             Comparison benchmark (StreamLZ vs LZ4, Snappy, Zstd)");
        Console.WriteLine("  -db             Decompress benchmark (input is pre-compressed file from -c)");
        Console.WriteLine($"  -l <level>      Compression level 1-11 (default: {Slz.DefaultLevel})");
        Console.WriteLine("                    1-5: fast decompress (4-5 GB/s)");
        Console.WriteLine("                    6-8: balanced (~34% ratio, 3.8 GB/s decompress)");
        Console.WriteLine("                    9-11: max ratio (~27%, 1.4 GB/s decompress)");
        Console.WriteLine("  -r <runs>       Benchmark runs (default: 3)");
        Console.WriteLine("  -t <threads>    Compression threads (0=auto, default: auto)");
        Console.WriteLine("  -o <file>       Output file");
        Console.WriteLine("  --ini <file>    Load cost coefficients from INI file");
        return;
    }

    // For -c and -d modes, use stream-based API (no file size limit).
    // For -b, -bc, -db modes, load into memory (limited to <2GB).
    long inputSize = new FileInfo(inputFile).Length;
    Console.WriteLine($"Input: {inputFile} ({inputSize:N0} bytes, {inputSize / 1024.0 / 1024.0:F2} MB)");

    if (mode == "iotest")
    {
        int[] chunkSizes = [4096, 65536, 1024 * 1024, 16 * 1024 * 1024, 64 * 1024 * 1024, 256 * 1024 * 1024];
        foreach (int chunkSize in chunkSizes)
        {
            if (chunkSize > inputSize) continue;
            byte[] buf = new byte[chunkSize];
            long totalRead = 0;

            var sw = System.Diagnostics.Stopwatch.StartNew();
            using (var fs = new FileStream(inputFile, FileMode.Open, FileAccess.Read, FileShare.Read, 0, FileOptions.SequentialScan))
            {
                int n;
                while ((n = fs.Read(buf, 0, buf.Length)) > 0)
                    totalRead += n;
            }
            sw.Stop();
            double mbps = (double)totalRead / sw.Elapsed.TotalSeconds / (1024 * 1024);
            Console.WriteLine($"  Chunk {chunkSize / 1024,6}KB: {sw.ElapsedMilliseconds,5}ms, {mbps:F0} MB/s ({totalRead:N0} bytes)");
        }

        // Also test File.ReadAllBytes if small enough
        if (inputSize <= int.MaxValue)
        {
            var sw2 = System.Diagnostics.Stopwatch.StartNew();
            byte[] all = File.ReadAllBytes(inputFile);
            sw2.Stop();
            double mbps2 = (double)all.Length / sw2.Elapsed.TotalSeconds / (1024 * 1024);
            Console.WriteLine($"  ReadAllBytes:      {sw2.ElapsedMilliseconds,5}ms, {mbps2:F0} MB/s");
        }

        // Test write speed — multiple methods
        if (outputFile != null)
        {
            long writeSize = Math.Min(inputSize, 256L * 1024 * 1024);
            byte[] writeBuf = new byte[writeSize];

            // 1. Single big write
            {
                var sw3 = System.Diagnostics.Stopwatch.StartNew();
                using (var fs = new FileStream(outputFile, FileMode.Create, FileAccess.Write, FileShare.None, 0, FileOptions.SequentialScan))
                    fs.Write(writeBuf, 0, (int)writeSize);
                sw3.Stop();
                Console.WriteLine($"  Write single:      {sw3.ElapsedMilliseconds,5}ms, {(double)writeSize / sw3.Elapsed.TotalSeconds / (1024 * 1024):F0} MB/s");
                File.Delete(outputFile);
            }

            // 2. 64KB chunk writes
            {
                var sw3 = System.Diagnostics.Stopwatch.StartNew();
                using (var fs = new FileStream(outputFile, FileMode.Create, FileAccess.Write, FileShare.None, 0, FileOptions.SequentialScan))
                {
                    int off = 0;
                    while (off < writeSize)
                    {
                        int chunk = (int)Math.Min(65536, writeSize - off);
                        fs.Write(writeBuf, off, chunk);
                        off += chunk;
                    }
                }
                sw3.Stop();
                Console.WriteLine($"  Write 64KB chunks: {sw3.ElapsedMilliseconds,5}ms, {(double)writeSize / sw3.Elapsed.TotalSeconds / (1024 * 1024):F0} MB/s");
                File.Delete(outputFile);
            }

            // 3. 1MB chunk writes
            {
                var sw3 = System.Diagnostics.Stopwatch.StartNew();
                using (var fs = new FileStream(outputFile, FileMode.Create, FileAccess.Write, FileShare.None, 0, FileOptions.SequentialScan))
                {
                    int off = 0;
                    while (off < writeSize)
                    {
                        int chunk = (int)Math.Min(1024 * 1024, writeSize - off);
                        fs.Write(writeBuf, off, chunk);
                        off += chunk;
                    }
                }
                sw3.Stop();
                Console.WriteLine($"  Write 1MB chunks:  {sw3.ElapsedMilliseconds,5}ms, {(double)writeSize / sw3.Elapsed.TotalSeconds / (1024 * 1024):F0} MB/s");
                File.Delete(outputFile);
            }

            // 4. RandomAccess.Write
            {
                var sw3 = System.Diagnostics.Stopwatch.StartNew();
                using (var handle = File.OpenHandle(outputFile, FileMode.Create, FileAccess.Write, FileShare.None, FileOptions.SequentialScan))
                    RandomAccess.Write(handle, writeBuf.AsSpan(0, (int)writeSize), 0);
                sw3.Stop();
                Console.WriteLine($"  RandomAccess:      {sw3.ElapsedMilliseconds,5}ms, {(double)writeSize / sw3.Elapsed.TotalSeconds / (1024 * 1024):F0} MB/s");
                File.Delete(outputFile);
            }

            // 5. Memory-mapped file
            {
                var sw3 = System.Diagnostics.Stopwatch.StartNew();
                using (var mmf = System.IO.MemoryMappedFiles.MemoryMappedFile.CreateFromFile(outputFile, FileMode.Create, null, writeSize))
                using (var accessor = mmf.CreateViewAccessor(0, writeSize))
                {
                    unsafe
                    {
                        byte* ptr = null;
                        accessor.SafeMemoryMappedViewHandle.AcquirePointer(ref ptr);
                        try
                        {
                            fixed (byte* pSrc = writeBuf)
                                Buffer.MemoryCopy(pSrc, ptr, writeSize, writeSize);
                        }
                        finally
                        {
                            accessor.SafeMemoryMappedViewHandle.ReleasePointer();
                        }
                    }
                }
                sw3.Stop();
                Console.WriteLine($"  MemoryMapped:      {sw3.ElapsedMilliseconds,5}ms, {(double)writeSize / sw3.Elapsed.TotalSeconds / (1024 * 1024):F0} MB/s");
                File.Delete(outputFile);
            }
        }
        return;
    }

    if (mode == "c" || mode == "d")
    {
        // Stream-based compress/decompress — handles any file size
        if (outputFile == null)
        {
            Console.Error.WriteLine($"{(mode == "c" ? "Compress" : "Decompress")} mode requires -o <file>");
            return;
        }

        var sw = System.Diagnostics.Stopwatch.StartNew();
        if (mode == "c")
        {
            var cMapped = Slz.MapLevel(level);
            Console.Write($"Compressing L{level} ({cMapped.Codec} L{cMapped.CodecLevel}): ");
            const int ioBuf = 1024 * 1024;
            using var inStream = new FileStream(inputFile, FileMode.Open, FileAccess.Read, FileShare.Read, ioBuf, FileOptions.SequentialScan);
            using var outStream = new FileStream(outputFile, FileMode.Create, FileAccess.Write, FileShare.None, ioBuf, FileOptions.SequentialScan);

            // Wrap input in a progress-reporting stream
            long lastReport = 0;
            const long reportInterval = 256L * 1024 * 1024; // every 256MB
            using var progressStream = new ProgressStream(inStream, bytesRead =>
            {
                if (bytesRead - lastReport >= reportInterval)
                {
                    Console.Write($"\rCompressing L{level}: {bytesRead / (1024 * 1024):N0} / {inputSize / (1024 * 1024):N0} MB ({(double)bytesRead / inputSize * 100:F0}%)   ");
                    lastReport = bytesRead;
                }
            });

            long compSize = StreamLzFrameCompressor.Compress(progressStream, outStream,
                cMapped.Codec, cMapped.CodecLevel, contentSize: inputSize,
                selfContained: cMapped.SelfContained, maxThreads: threads);
            sw.Stop();
            double mbps = (double)inputSize / sw.Elapsed.TotalSeconds / (1024 * 1024);
            Console.WriteLine($"\rCompressed: {compSize:N0} bytes ({(double)compSize / inputSize * 100:F1}%), {sw.ElapsedMilliseconds / 1000.0:F1}s, {mbps:F1} MB/s   ");
        }
        else
        {
            if (inputSize <= int.MaxValue)
            {
                // Fast path: read entire compressed file into memory using optimal chunk size
                byte[] compData = new byte[inputSize];
                using (var readFs = new FileStream(inputFile, FileMode.Open, FileAccess.Read, FileShare.Read, 0, FileOptions.SequentialScan))
                {
                    int total = 0;
                    while (total < compData.Length)
                    {
                        int n = readFs.Read(compData, total, Math.Min(65536, compData.Length - total));
                        if (n == 0) break;
                        total += n;
                    }
                }

                sw.Stop();

                // Decompress using the proper framed API (handles sliding window, checksums, etc.)
                var decompSw = System.Diagnostics.Stopwatch.StartNew();
                long decompWritten = Slz.DecompressFile(inputFile, outputFile);
                decompSw.Stop();
                double mbps2 = (double)decompWritten / decompSw.Elapsed.TotalSeconds / (1024 * 1024);
                Console.WriteLine($"Decompressed: {decompWritten:N0} bytes, {decompSw.ElapsedMilliseconds:N0}ms, {mbps2:F1} MB/s");

            }
        }
        Console.WriteLine($"Written to {outputFile}");
        return;
    }

    if (inputSize > int.MaxValue)
    {
        Console.Error.WriteLine($"File too large for {mode} mode ({inputSize:N0} bytes). Use -c/-d for files >2GB.");
        return;
    }

    // In-memory benchmark needs source + compressed + decompressed buffers.
    // Check available memory upfront and cap threads to stay within 70% of system RAM.
    long availableBytes = (long)GC.GetGCMemoryInfo().TotalAvailableMemoryBytes;
    long memoryBudget = (long)(availableBytes * 0.70);
    long benchmarkOverhead = inputSize + StreamLZCompressor.GetCompressBound((int)Math.Min(inputSize, int.MaxValue))
                             + inputSize + StreamLZDecoder.SafeSpace;
    if (benchmarkOverhead > memoryBudget)
    {
        Console.Error.WriteLine($"File requires ~{benchmarkOverhead / (1024 * 1024):N0} MB for in-memory benchmark, but only {memoryBudget / (1024 * 1024):N0} MB (70% of {availableBytes / (1024 * 1024):N0} MB) is available.");
        Console.Error.WriteLine("Use -c/-d for stream-based compression of large files.");
        return;
    }

    byte[] src = File.ReadAllBytes(inputFile);

    // Cap threads so total memory (benchmark buffers + per-thread scratch) stays under 70% RAM
    if (threads <= 0)
    {
        long remainingBudget = memoryBudget - benchmarkOverhead;
        int maxByMemory = (int)Math.Max(1, remainingBudget / StreamLZConstants.PerThreadMemoryEstimate);
        int maxByCores = Environment.ProcessorCount;
        threads = Math.Min(maxByMemory, maxByCores);
    }

    if (threads > 1)
        Console.WriteLine($"Threads: {threads}");

    if (mode == "b")
    {
        // Benchmark mode — use framed API (handles multi-block correctly for large files)
        // Pre-JIT hot paths
        _ = Slz.SafeSpace;

        // Warmup: compress a small slice to trigger JIT compilation of all hot methods.
        // No need to warmup on the full file — JIT compiles on first call regardless of size.
        int warmupSize = Math.Min(src.Length, 128 * 1024);
        Slz.CompressFramed(src.AsSpan(0, warmupSize), level);

        // Compress benchmark — first run also provides the compressed data for decompress test
        byte[] compressed = null!;
        double[] compSeconds = new double[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            compressed = Slz.CompressFramed(src, level);
            sw.Stop();
            compSeconds[r] = sw.Elapsed.TotalSeconds;
            double mbps = (double)src.Length / compSeconds[r] / (1024 * 1024);
            Console.WriteLine($"  Compress run {r + 1}: {sw.ElapsedMilliseconds:N0}ms ({mbps:F1} MB/s)");
        }

        Console.WriteLine($"Level {level}: {src.Length:N0} -> {compressed.Length:N0} bytes ({(double)compressed.Length / src.Length * 100:F1}%)");
        Console.WriteLine();

        Array.Sort(compSeconds);
        double compMedianSec = compSeconds[runs / 2];
        double compMbps = (double)src.Length / compMedianSec / (1024 * 1024);
        Console.WriteLine($"  Compress median: {compMedianSec * 1000:N0}ms ({compMbps:F1} MB/s)");
        Console.WriteLine();

        // Decompress benchmark (framed fast-path: in-place block parsing, no MemoryStream)
        byte[] decompressed = new byte[src.Length + Slz.SafeSpace];
        Slz.DecompressFramed((ReadOnlySpan<byte>)compressed, (Span<byte>)decompressed);

        long[] decompTimes = new long[runs];
        double[] decompSeconds = new double[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            int decompSize = Slz.DecompressFramed((ReadOnlySpan<byte>)compressed, (Span<byte>)decompressed);
            sw.Stop();
            if (decompSize != src.Length) Console.Error.WriteLine($"[CLI] Decompress size mismatch: {decompSize} != {src.Length}");
            decompSeconds[r] = sw.Elapsed.TotalSeconds;
            double mbps = (double)src.Length / decompSeconds[r] / (1024 * 1024);
            Console.WriteLine($"  Decompress run {r + 1}: {sw.ElapsedMilliseconds:N0}ms ({mbps:F1} MB/s)");
        }

        Array.Sort(decompSeconds);
        double decompMedianSec = decompSeconds[runs / 2];
        double decompMbps = (double)src.Length / decompMedianSec / (1024 * 1024);
        Console.WriteLine($"  Decompress median: {decompMedianSec * 1000:N0}ms ({decompMbps:F1} MB/s)");
        Console.WriteLine();

        // Verify
        bool match = decompressed.AsSpan(0, src.Length).SequenceEqual(src);
        Console.WriteLine($"Round-trip: {(match ? "PASS" : "FAIL")}");
        if (!match)
        {
            for (int mi = 0; mi < src.Length; mi++)
            {
                if (decompressed[mi] != src[mi])
                {
                    Console.WriteLine($"  First mismatch at byte {mi} (0x{mi:X}): expected 0x{src[mi]:X2}, got 0x{decompressed[mi]:X2}");
                    // Show context: 16 bytes before and after
                    int ctx = Math.Max(0, mi - 8);
                    Console.Write("  Expected: ");
                    for (int ci = ctx; ci < Math.Min(src.Length, mi + 8); ci++)
                        Console.Write($"{src[ci]:X2} ");
                    Console.WriteLine();
                    Console.Write("  Got:      ");
                    for (int ci = ctx; ci < Math.Min(src.Length, mi + 8); ci++)
                        Console.Write($"{decompressed[ci]:X2} ");
                    Console.WriteLine();
                    int mismatches = 0;
                    for (int ci = mi; ci < src.Length; ci++)
                        if (decompressed[ci] != src[ci]) mismatches++;
                    Console.WriteLine($"  Total mismatches: {mismatches} of {src.Length} bytes");
                    break;
                }
            }
        }
    }
    else if (mode == "bc")
    {
        // Comparison benchmark: StreamLZ vs LZ4, Snappy, Zstd
        StreamLZ.Cli.ComparisonBenchmark.Run(src, runs);
    }
    else if (mode == "db")
    {
        // Decompress-only benchmark: reads an SLZ1-framed .slz file (produced by -c)
        // and decompresses it N times. No compression happens here — pure decompress
        // profiling for dotnet-trace / VTune / PerfView.
        // Input must be the framed format written by `-c`.
        Console.WriteLine($"Compressed input: {src.Length:N0} bytes");

        // Read the frame header to get the exact decompressed size.
        // SLZ1 frame: [magic(4)][version(1)][flags(1)][codec(1)][level(1)]
        //             [blockSizeLog2(1)][reserved(1)][contentSize(8, if flag bit 0)]...
        if (src.Length < 10 || src[0] != 0x31 || src[1] != 0x5A || src[2] != 0x4C || src[3] != 0x53)
        {
            Console.Error.WriteLine("[CLI] Input is not an SLZ1 framed file. Use `-c` to produce one.");
            return;
        }
        byte flags = src[5];
        if ((flags & 0x01) == 0)
        {
            Console.Error.WriteLine("[CLI] Framed file has no ContentSize header field. -db requires a sized frame.");
            return;
        }
        long origSizeLong = BinaryPrimitives.ReadInt64LittleEndian(src.AsSpan(10, 8));
        if (origSizeLong <= 0 || origSizeLong > int.MaxValue - Slz.SafeSpace)
        {
            Console.Error.WriteLine($"[CLI] Unsupported content size: {origSizeLong:N0}");
            return;
        }
        int origSize = (int)origSizeLong;
        Console.WriteLine($"Decompressed size: {origSize:N0} bytes");
        Console.WriteLine();

        byte[] decompressed = new byte[origSize + Slz.SafeSpace];

        // Warmup decompress (triggers JIT of the hot path before timing)
        Slz.DecompressFramed((ReadOnlySpan<byte>)src, (Span<byte>)decompressed);

        // Decompress benchmark
        double[] decompSeconds = new double[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            int decompSize = Slz.DecompressFramed((ReadOnlySpan<byte>)src, (Span<byte>)decompressed);
            sw.Stop();
            if (decompSize != origSize)
                Console.Error.WriteLine($"[CLI] Decompress size mismatch: {decompSize} != {origSize}");
            decompSeconds[r] = sw.Elapsed.TotalSeconds;
            double mbps = (double)origSize / decompSeconds[r] / (1024 * 1024);
            Console.WriteLine($"  Decompress run {r + 1}: {sw.ElapsedMilliseconds:N0}ms ({mbps:F1} MB/s)");
        }

        Array.Sort(decompSeconds);
        double decompMedianSec = decompSeconds[runs / 2];
        double decompMbps = (double)origSize / decompMedianSec / (1024 * 1024);
        Console.WriteLine($"  Decompress median: {decompMedianSec * 1000:N0}ms ({decompMbps:F1} MB/s)");
    }
    // -c and -d modes are handled above via stream API (no file size limit).
}

