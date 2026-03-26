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
            var progressStream = new ProgressStream(inStream, bytesRead =>
            {
                if (bytesRead - lastReport >= reportInterval)
                {
                    Console.Write($"\rCompressing L{level}: {bytesRead / (1024 * 1024):N0} / {inputSize / (1024 * 1024):N0} MB ({(double)bytesRead / inputSize * 100:F0}%)   ");
                    lastReport = bytesRead;
                }
            });

            long compSize = StreamLzFrameCompressor.Compress(progressStream, outStream,
                cMapped.Codec, cMapped.CodecLevel, contentSize: inputSize,
                selfContained: cMapped.SelfContained);
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

                // Parse frame header to get content size
                if (!FrameSerializer.TryReadHeader(compData, out var fh))
                    throw new InvalidDataException("Invalid SLZ1 frame header.");

                // Find total decompressed size by scanning block headers
                long totalDecomp = 0;
                int pos = fh.HeaderSize;
                while (pos + 8 <= compData.Length)
                {
                    if (!FrameSerializer.TryReadBlockHeader(compData.AsSpan(pos), out int cs, out int ds, out bool unc))
                        break;
                    if (cs == 0) break; // end mark
                    totalDecomp += ds;
                    int payloadSize = unc ? ds : cs;
                    pos += 8 + payloadSize;
                }

                byte[] output2 = new byte[totalDecomp + Slz.SafeSpace];
                long decompWritten = 0;
                pos = fh.HeaderSize;
                while (pos + 8 <= compData.Length)
                {
                    if (!FrameSerializer.TryReadBlockHeader(compData.AsSpan(pos), out int cs, out int ds, out bool unc))
                        break;
                    if (cs == 0) break;
                    pos += 8;
                    if (unc)
                    {
                        compData.AsSpan(pos, ds).CopyTo(output2.AsSpan((int)decompWritten));
                    }
                    else
                    {
                        unsafe
                        {
                            fixed (byte* pComp = &compData[pos])
                            fixed (byte* pOut = &output2[decompWritten])
                            {
                                StreamLZDecoder.Decompress(pComp, cs, pOut, ds);
                            }
                        }
                    }
                    decompWritten += ds;
                    pos += unc ? ds : cs;
                }

                sw.Stop();
                double mbps2 = (double)decompWritten / sw.Elapsed.TotalSeconds / (1024 * 1024);
                Console.WriteLine($"Decompressed: {decompWritten:N0} bytes, {sw.ElapsedMilliseconds}ms, {mbps2:F1} MB/s");

                // Write output in 1MB chunks (2x faster than single large write on NVMe)
                var writeSw = System.Diagnostics.Stopwatch.StartNew();
                using (var outFs = new FileStream(outputFile, FileMode.Create, FileAccess.Write, FileShare.None, 0, FileOptions.SequentialScan))
                {
                    int off = 0;
                    while (off < (int)decompWritten)
                    {
                        int chunk = Math.Min(1024 * 1024, (int)decompWritten - off);
                        outFs.Write(output2, off, chunk);
                        off += chunk;
                    }
                }
                writeSw.Stop();
                Console.WriteLine($"Write: {writeSw.ElapsedMilliseconds}ms");
            }
            else
            {
                // Large file: streaming decompress
                long decompSize = StreamLzFrameDecompressor.DecompressFile(inputFile, outputFile);
                sw.Stop();
                double mbps = (double)decompSize / sw.Elapsed.TotalSeconds / (1024 * 1024);
                Console.WriteLine($"Decompressed: {decompSize:N0} bytes, {sw.ElapsedMilliseconds}ms, {mbps:F1} MB/s");
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

    byte[] src = File.ReadAllBytes(inputFile);

    // Resolve auto thread count
    if (threads <= 0)
        threads = StreamLZCompressor.CalculateMaxThreads(src.Length, level);

    if (threads > 1)
        Console.WriteLine($"Threads: {threads}");

    if (mode == "b")
    {
        // Benchmark mode — map unified level to internal codec + level
        var mapped = Slz.MapLevel(level);
        var codec = mapped.Codec;
        int codecLevel = mapped.CodecLevel;
        bool selfContained = mapped.SelfContained;

        int compBound = StreamLZCompressor.GetCompressBound(src.Length);
        byte[] compressed = new byte[compBound];

        // Warmup compress
        int compSize;
        fixed (byte* pSrc = src) fixed (byte* pDst = compressed)
            compSize = StreamLZCompressor.Compress(pSrc, src.Length, pDst, compressed.Length, codec, codecLevel, threads, selfContained);

        Console.WriteLine($"Level {level}: {src.Length:N0} -> {compSize:N0} bytes ({(double)compSize / src.Length * 100:F1}%)");
        Console.WriteLine();

        // Compress benchmark
        long[] compTimes = new long[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            fixed (byte* pSrc = src) fixed (byte* pDst = compressed)
                compSize = StreamLZCompressor.Compress(pSrc, src.Length, pDst, compressed.Length, codec, codecLevel, threads, selfContained);
            sw.Stop();
            compTimes[r] = sw.ElapsedMilliseconds;
            double mbps = (double)src.Length / sw.Elapsed.TotalSeconds / (1024 * 1024);
            Console.WriteLine($"  Compress run {r + 1}: {sw.ElapsedMilliseconds}ms ({mbps:F1} MB/s)");
        }

        Array.Sort(compTimes);
        long compMedian = compTimes[runs / 2];
        double compMbps = (double)src.Length / (compMedian / 1000.0) / (1024 * 1024);
        Console.WriteLine($"  Compress median: {compMedian}ms ({compMbps:F1} MB/s)");
        Console.WriteLine();

        // Decompress benchmark
        byte[] decompressed = new byte[src.Length + StreamLZDecoder.SafeSpace];

        // Pre-JIT decompressor hot paths (triggered by touching Slz)
        _ = Slz.SafeSpace;

        long[] decompTimes = new long[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            int decompSize;
            fixed (byte* pComp = compressed) fixed (byte* pDecomp = decompressed)
                decompSize = StreamLZDecoder.Decompress(pComp, compSize, pDecomp, src.Length);
            sw.Stop();
            if (decompSize < 0) Console.Error.WriteLine($"[CLI] Decompress FAILED: returned {decompSize}");
            decompTimes[r] = sw.ElapsedMilliseconds;
            double mbps = (double)src.Length / sw.Elapsed.TotalSeconds / (1024 * 1024);
            Console.WriteLine($"  Decompress run {r + 1}: {decompTimes[r]}ms ({mbps:F1} MB/s)");
        }

        Array.Sort(decompTimes);
        long decompMedian = decompTimes[runs / 2];
        double decompMbps = (double)src.Length / (decompMedian / 1000.0) / (1024 * 1024);
        Console.WriteLine($"  Decompress median: {decompMedian}ms ({decompMbps:F1} MB/s)");
        Console.WriteLine();

        // Verify
        bool match = new Span<byte>(decompressed, 0, src.Length).SequenceEqual(src);
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
        // Decompress-only benchmark: reads a pre-compressed file (4-byte LE original size
        // + compressed data, as written by -c mode), then decompresses N times.
        // No compression happens here — pure decompress profiling for VTune.
        int origSize = BitConverter.ToInt32(src, 0);
        byte[] compData = src.AsSpan(4).ToArray();

        Console.WriteLine($"Compressed input: {compData.Length:N0} bytes, original size: {origSize:N0} bytes");
        Console.WriteLine();

        // Warmup decompress
        byte[] decompressed = new byte[origSize + StreamLZDecoder.SafeSpace];
        fixed (byte* pComp = compData) fixed (byte* pDecomp = decompressed)
            StreamLZDecoder.Decompress(pComp, compData.Length, pDecomp, origSize);

        // Decompress benchmark
        long[] decompTimes = new long[runs];
        for (int r = 0; r < runs; r++)
        {
            var sw = Stopwatch.StartNew();
            int decompSize;
            fixed (byte* pComp = compData) fixed (byte* pDecomp = decompressed)
                decompSize = StreamLZDecoder.Decompress(pComp, compData.Length, pDecomp, origSize);
            sw.Stop();
            decompTimes[r] = sw.ElapsedMilliseconds;
            double mbps = (double)origSize / sw.Elapsed.TotalSeconds / (1024 * 1024);
            Console.WriteLine($"  Decompress run {r + 1}: {decompTimes[r]}ms ({mbps:F1} MB/s)");
        }

        Array.Sort(decompTimes);
        long decompMedian = decompTimes[runs / 2];
        double decompMbps = (double)origSize / (decompMedian / 1000.0) / (1024 * 1024);
        Console.WriteLine($"  Decompress median: {decompMedian}ms ({decompMbps:F1} MB/s)");
    }
    // -c and -d modes are handled above via stream API (no file size limit).
}

