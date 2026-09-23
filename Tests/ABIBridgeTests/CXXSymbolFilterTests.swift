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
}
#endif
