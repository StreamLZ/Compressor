// This file is used by Code Analysis to maintain SuppressMessage
// attributes that are applied to this project.

using System.Diagnostics.CodeAnalysis;

// CLI tool does not need resource tables for literal strings.
[assembly: SuppressMessage("Globalization", "CA1303:Do not pass literals as localized parameters", Justification = "CLI tool does not need resource tables for literal strings.")]
