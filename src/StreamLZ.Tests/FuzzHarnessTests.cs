using Xunit;
using Xunit.Abstractions;

namespace StreamLZ.Tests;

/// <summary>
/// Long-running fuzz tests. Each level is a separate test method so it runs
/// in its own process when filtered individually. If the process crashes,
/// check %TEMP%/slz-fuzz-watermark.txt for the last iteration attempted.
/// </summary>
public class FuzzHarnessTests
{
    private readonly ITestOutputHelper _output;
    public FuzzHarnessTests(ITestOutputHelper output) => _output = output;

    [Fact] public void FuzzHarness_Level1() => Run(1, 100_000_000);
    [Fact] public void FuzzHarness_Level5() => Run(5, 100_000_000);
    [Fact] public void FuzzHarness_Level6() => Run(6, 100_000_000);
    [Fact] public void FuzzHarness_Level9() => Run(9, 100_000_000);

    private void Run(int level, int iterations)
    {
        int crashes = FuzzHarness.RunLevel(level, iterations);
        Assert.Equal(0, crashes);
    }
}
