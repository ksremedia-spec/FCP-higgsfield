import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A minimal immutable XML element tree built with `XMLParser` (available on
/// macOS and Linux, unlike `XMLDocument`).
public final class MiniXMLElement {
    public let name: String
    public let attributes: [String: String]
    public private(set) var children: [MiniXMLElement] = []
    public private(set) var text: String = ""
    public private(set) weak var parent: MiniXMLElement?

    init(name: String, attributes: [String: String], parent: MiniXMLElement?) {
        self.name = name
        self.attributes = attributes
        self.parent = parent
    }

    public subscript(attribute: String) -> String? { attributes[attribute] }

    public func children(named name: String) -> [MiniXMLElement] {
        children.filter { $0.name == name }
    }

    public func firstChild(named name: String) -> MiniXMLElement? {
        children.first { $0.name == name }
    }

    /// Depth-first search of all descendants.
    public func descendants(named name: String) -> [MiniXMLElement] {
        var result: [MiniXMLElement] = []
        for child in children {
            if child.name == name { result.append(child) }
            result += child.descendants(named: name)
        }
        return result
    }

    fileprivate func append(_ child: MiniXMLElement) { children.append(child) }
    fileprivate func appendText(_ s: String) { text += s }

    public static func parse(_ data: Data) throws -> MiniXMLElement {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let reason = parser.parserError?.localizedDescription ?? "unknown error"
            throw HiggsfieldError.invalidInput("Couldn’t read the Final Cut Pro XML (\(reason)).")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: MiniXMLElement?
        var stack: [MiniXMLElement] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let element = MiniXMLElement(name: elementName, attributes: attributeDict, parent: stack.last)
            stack.last?.append(element)
            if root == nil { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.appendText(string)
        }
    }
}
