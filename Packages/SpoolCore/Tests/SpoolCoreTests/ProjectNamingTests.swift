import Testing
@testable import SpoolCore

/// Ported test-by-test from the source app's `tests/common/test_text.py` — same
/// input/output pairs, so this stays a faithful behavioral port, not just a
/// reimplementation that happens to look similar.
@Suite struct ProjectNamingTests {
    @Test func cleanNameDecodesPercentEncoding() {
        #expect(ProjectNaming.cleanName("Anker%20Nano%20Bracket.stl") == "Anker Nano Bracket.stl")
    }

    @Test func cleanNameDecodesPlusWhenNoRealSpaces() {
        #expect(ProjectNaming.cleanName("AAA+battery+tray+mk2.stl") == "AAA battery tray mk2.stl")
    }

    @Test func cleanNameLeavesRealSpacesAndPlussesAlone() {
        #expect(ProjectNaming.cleanName("C++ Project") == "C++ Project")
    }

    @Test func cleanNameLeavesPlainNamesAlone() {
        #expect(ProjectNaming.cleanName("widget.stl") == "widget.stl")
    }

    @Test func cleanNameHandlesEmpty() {
        #expect(ProjectNaming.cleanName("") == "")
    }

    @Test func cleanNameHandlesMixedPercentAndPlus() {
        #expect(ProjectNaming.cleanName("Double%20holder+20mm.STL") == "Double holder 20mm.STL")
    }

    @Test func suggestCleanProjectNameStripsModelFilesSuffix() {
        #expect(ProjectNaming.suggestCleanName("towel-hanger-model_files") == "Towel Hanger")
    }

    @Test func suggestCleanProjectNameConvertsSeparatorsToSpaces() {
        #expect(ProjectNaming.suggestCleanName("Hex3D_SaberPack4_Shroud_Extensions") == "Hex3D SaberPack4 Shroud Extensions")
    }

    @Test func suggestCleanProjectNameStripsLongStandaloneAssetId() {
        #expect(ProjectNaming.suggestCleanName("Desktop Mini conveyor - 5415144") == "Desktop Mini Conveyor")
        #expect(ProjectNaming.suggestCleanName("4635682_Credit_card_cutlery") == "Credit Card Cutlery")
    }

    @Test func suggestCleanProjectNameKeepsShortMeaningfulNumbers() {
        #expect(ProjectNaming.suggestCleanName("doll-house-kitchen-sink-112-model_files") == "Doll House Kitchen Sink 112")
    }

    @Test func suggestCleanProjectNameLeavesAlreadyCleanNamesAlone() {
        #expect(ProjectNaming.suggestCleanName("Dry Box Caps") == "Dry Box Caps")
    }

    @Test func suggestCleanProjectNameCapitalizesEveryWordIncludingConnectors() {
        #expect(ProjectNaming.suggestCleanName("4th of July Uncle Sam Hat") == "4th Of July Uncle Sam Hat")
    }

    @Test func suggestCleanProjectNamePreservesAcronymsAndMixedCase() {
        #expect(ProjectNaming.suggestCleanName("ryobi-usb-lithium-model_files") == "Ryobi Usb Lithium")
        #expect(ProjectNaming.suggestCleanName("nespresso-VertuoNext-model_files") == "Nespresso VertuoNext")
    }

    @Test func suggestCleanProjectNameCombinesWithPercentDecoding() {
        #expect(ProjectNaming.suggestCleanName("Anker%20Nano-model_files") == "Anker Nano")
    }

    @Test func suggestCleanProjectNameCapitalizesAfterAnOpeningParen() {
        #expect(
            ProjectNaming.suggestCleanName("Other (ikea-mini-kallax-collection-model_files)")
                == "Other (Ikea Mini Kallax Collection)"
        )
    }

    @Test func suggestCleanProjectNameStripsStraySpaceBeforeClosingParen() {
        #expect(
            ProjectNaming.suggestCleanName("Other Containers (gridfinity-master-collection-model_files)")
                == "Other Containers (Gridfinity Master Collection)"
        )
    }

    @Test func suggestCleanProjectNameExpandsScaleNotationWithoutInventingTheWordScale() {
        #expect(ProjectNaming.suggestCleanName("1_12_US_Mail_box_3520864") == "1/12 US Mail Box")
    }

    @Test func suggestCleanProjectNameScaleNotationPreservesExistingScaleWordWithoutDoubling() {
        #expect(ProjectNaming.suggestCleanName("1_12_scale_bookshelf_4218879 (1)") == "1/12 Scale Bookshelf (1)")
    }

    @Test func suggestCleanProjectNameExpandsFusedOrdinalScaleNotation() {
        #expect(ProjectNaming.suggestCleanName("110th-scale-fire-hydrant-model_files") == "1/10th Scale Fire Hydrant")
    }

    @Test func suggestCleanProjectNameExpandsFusedPlainScaleNotation() {
        #expect(
            ProjectNaming.suggestCleanName("125-scale-boat-for-the-bathtub-model_files")
                == "1/25 Scale Boat For The Bathtub"
        )
    }

    @Test func suggestCleanProjectNameLeavesFusedNumberAloneWithoutScaleAnchor() {
        #expect(ProjectNaming.suggestCleanName("110th anniversary model") == "110th Anniversary Model")
        #expect(ProjectNaming.suggestCleanName("125 widget mount") == "125 Widget Mount")
    }

    @Test func suggestCleanProjectNameFusedScaleRejectsZeroDenominator() {
        #expect(ProjectNaming.suggestCleanName("10 scale model") == "10 Scale Model")
    }

    @Test func suggestCleanProjectNameFusedDigitsAreNotTreatedAsScaleNotation() {
        #expect(ProjectNaming.suggestCleanName("doll-house-kitchen-sink-112-model_files") == "Doll House Kitchen Sink 112")
    }

    @Test func suggestCleanProjectNameScaleConversionIsIdempotent() {
        let once = ProjectNaming.suggestCleanName("1_12_scale_bookshelf")
        #expect(once == "1/12 Scale Bookshelf")
        #expect(ProjectNaming.suggestCleanName(once) == once)
    }

    @Test func suggestCleanProjectNameScaleConversionIdempotentWithoutScaleWord() {
        let once = ProjectNaming.suggestCleanName("1_12_US_Mail_box")
        #expect(once == "1/12 US Mail Box")
        #expect(ProjectNaming.suggestCleanName(once) == once)
    }
}
