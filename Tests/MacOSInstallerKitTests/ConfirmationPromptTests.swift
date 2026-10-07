import Testing
@testable import macos_installer

@Test("accepts the correct name followed by a trailing newline")
func acceptsCorrectNameWithTrailingNewline() {
    // Arrange: the default `readLine(strippingNewline: true)` already removes
    // a trailing "\n", but a piped or replaced reader may not — this is the
    // latent case the carry-forward item describes.
    let expected = "SanDisk Ultra"

    // Act
    let matched = ConfirmationPrompt.requireTypedName(expected) {
        "SanDisk Ultra\n"
    }

    // Assert
    #expect(matched)
}

@Test("accepts the correct name followed by a trailing carriage-return newline")
func acceptsCorrectNameWithTrailingCarriageReturnNewline() {
    // Arrange: a reader that preserves "\r\n" line endings intact (e.g. a
    // replaced or network-backed reader) must not cause a correctly typed
    // name to be rejected.
    let expected = "SanDisk Ultra"

    // Act
    let matched = ConfirmationPrompt.requireTypedName(expected) {
        "SanDisk Ultra\r\n"
    }

    // Assert
    #expect(matched)
}

@Test("still refuses a wrong name even with trailing whitespace")
func refusesWrongNameWithTrailingWhitespace() {
    // Arrange: widening the trim must never make the comparison accept
    // anything it should not — this is the fail-closed property the carry-
    // forward item requires be preserved.
    let expected = "SanDisk Ultra"

    // Act
    let matched = ConfirmationPrompt.requireTypedName(expected) {
        "Not The Right Drive\r\n"
    }

    // Assert
    #expect(!matched)
}
