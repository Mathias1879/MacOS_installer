import Testing
@testable import MacOSInstallerKit

@Test("formats zero bytes as 0.0 GB")
func zeroBytesFormatsAsZeroGigabytes() {
    // Arrange
    let bytes: Int64 = 0

    // Act
    let result = ByteSize.gigabytes(bytes)

    // Assert
    #expect(result == "0.0 GB")
}

@Test("formats exactly one gigabyte as 1.0 GB")
func exactlyOneGigabyteFormatsAsOnePointZero() {
    // Arrange
    let bytes: Int64 = 1_000_000_000

    // Act
    let result = ByteSize.gigabytes(bytes)

    // Assert
    #expect(result == "1.0 GB")
}

@Test("formats a two terabyte drive as 2000.0 GB")
func twoTerabytesFormatsAsTwoThousandGigabytes() {
    // Arrange
    let bytes: Int64 = 2_000_000_000_000

    // Act
    let result = ByteSize.gigabytes(bytes)

    // Assert
    #expect(result == "2000.0 GB")
}
