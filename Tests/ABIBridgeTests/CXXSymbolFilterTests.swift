#if DEBUG
// Release bridge tests consume the production module without -enable-testing.
import Testing
@testable import ABIBridge

struct CXXSymbolFilterTests {
    @Test(arguments: [
        ("Example::Renderer::refresh()", "_ZN7Example8Renderer7refreshEv"),
        ("vtable for Example::Renderer", "_ZTVN7Example8RendererE"),
        ("vtable  for Example :: Renderer", "__ZTVN7Example8RendererE"),
        ("typeinfo name for Example::Renderer", "_ZTSN7Example8RendererE"),
        ("Example::Renderer::Renderer()", "_ZN7Example8RendererC1Ev"),
        ("Example::Renderer::~Renderer()", "_ZN7Example8RendererD1Ev"),
        ("Example::Renderer::operator int() const", "_ZNK7Example8RenderercviEv"),
        ("std::terminate()", "_ZSt9terminatev"),
        ("operator delete(void*)", "_ZdlPv"),
        ("(anonymous namespace)::value", "_ZN12_GLOBAL__N_15valueE"),
        ("void (anonymous namespace)::f<int>()", "__ZN12_GLOBAL__N_11fIiEEvv"),
        ("decltype(auto) Example::get<int>()", "_ZN7Example3getIiEEDcv"),
        ("typeinfo for int", "__ZTIi"),
        ("typeinfo name for int", "__ZTSi"),
        ("typeinfo for std::nullptr_t", "__ZTIDn"),
        ("Example::Box<int>::value() const", "_ZNK7Example3BoxIiE5valueEv"),
    ])
    func preservesMatchingSymbols(_ declaration: String, _ rawName: String) {
        #expect(CXXSymbolFilter(declaration).matches(rawName))
    }

    @Test func excludesUnrelatedOwnersAndMembersBeforeDemangling() {
        let method = CXXSymbolFilter("Example::Renderer::refresh()")
        #expect(!method.matches("_ZN7Example8Renderer4stopEv"))
        #expect(!method.matches("_ZN7Example5Other7refreshEv"))
        let table = CXXSymbolFilter("vtable for Example::Renderer")
        #expect(!table.matches("_ZTVN7Example5OtherE"))
        #expect(!table.matches("_ZN7Example4Math3addEii"))
    }

    @Test func normalizationKeepsTypeBoundariesAndEmbeddedNulls() {
        #expect(DeclarationKey.make("Example :: f ( unsigned int )") == DeclarationKey.make("Example::f(unsigned int)"))
        #expect(DeclarationKey.make("Example::f(unsigned int)") != DeclarationKey.make("Example::f(unsignedint)"))
        #expect(DeclarationKey.make("Example::f()") != DeclarationKey.make("Example::f()\0extra"))
    }

    @Test func fingerprintCandidatesRequireFullDeclarationMatch() {
        let intended = IndexedSymbol(name: "__ZN7Example1fEj", address: 1, source: .image)
        let sameDeclaration = IndexedSymbol(name: intended.name, address: 2, source: .image)
        let differentType = IndexedSymbol(name: "__ZN7Example1fE11unsignedint", address: 3, source: .image)
        let query = SymbolQuery(.init(name: "Example :: f( unsigned int )", language: .cxx))
        let matches = SymbolIndex.matching(
            [differentType, intended, sameDeclaration], query: query, extensionsOnly: false
        )
        #expect(matches.map(\.address) == [1, 2])
    }

    @Test func duplicateDefinitionsPreserveBytesAddressesAndSources() {
        let first = IndexedSymbol(name: "_\u{00E9}", address: 1, source: .image)
        let decomposed = IndexedSymbol(name: "_e\u{0301}", address: 1, source: .image)
        #expect(first.name == decomposed.name)
        let symbols = Set([
            first, first, decomposed,
            .init(name: first.name, address: 2, source: .image),
            .init(name: first.name, address: 1, source: .sharedCache),
        ])
        #expect(symbols.count == 4)
    }
}
#endif
