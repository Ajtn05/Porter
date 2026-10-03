# Testing notes

## `#expect` and optional integers

Swift Testing's `#expect` macro captures each operand of a binary operator
separately, and that changes how the compiler infers their types. When the left
side is an *optional* integer and the right side is a non-literal integer
*expression*, the comparison evaluates to `false` even when the two values are
equal:

```swift
let value: Int64? = 5
#expect(value == 5)            // passes
#expect(value == 4 + 1)        // FAILS, and prints "5 == 5"
#expect(Int64(5) == 4 + 1)     // passes
#expect(value == Int64(4 + 1)) // passes
```

The failure message shows both sides rendered identically, which makes it look
like a bug in the code under test. It is not.

**Rule for this repository:** unwrap the optional first, or make the types
match explicitly.

```swift
let free = try #require(ADBParsing.parseDiskFree(output))
#expect(free.totalBytes == 112_000_000 * 1024)
```

This bites in one direction only — a passing assertion never becomes a failing
one — but the inverse is worth knowing: `#expect(optional != expression)` will
pass unconditionally, so do not write that form.

## Keypaths as predicates

`#expect(items.allSatisfy(\.isDirectory))` does not compile: the macro's
rewriting makes the key-path-as-function look like a throwing closure to
`rethrows`. Use an explicit closure, or compute the `Bool` before the macro.

## What the engine tests actually prove

`Kit/Tests/PorterKitTests/EngineTests.swift` is written against
`FakeTransport`, an in-memory device. That is deliberate: the guarantees worth
testing are the failure paths, and a cable pulled at exactly 50% of a 4 GB file
is not something you can stage reliably against real hardware.

The tests that matter most:

| Test | Guarantee |
| --- | --- |
| `pullInterruptedLeavesPartial` | A broken transfer never leaves a file under its final name |
| `pullResumes` | Reconnecting continues from a block-aligned offset, and reads only twice |
| `checksumMismatchDiscards` | A file that fails verification is deleted, not kept |
| `noChecksumToolStillWorks` | A device without `sha256sum` completes, and reports that nothing was verified |
| `pushMismatchLeavesDestinationUntouched` | A bad upload never takes the real filename on the device |
| `cancelCleansUp` | Cancelling removes the partial file |

What they do **not** prove is that `ADBTransport` speaks to a real phone
correctly. That needs hardware; see `Docs/status.md`.
