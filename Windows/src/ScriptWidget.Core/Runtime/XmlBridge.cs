using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Xml;

namespace ScriptWidget.Core.Runtime;

/// <summary>
/// Bounded XML parser behind <c>$xml.parse</c>, with the limits and output
/// shape of ScriptWidgetXMLParser: {name, attributes, text, children}. DTDs
/// and entity declarations are rejected and external entities are never
/// resolved.
/// </summary>
public static partial class XmlBridge
{
    private const int MaximumBytes = 256 * 1024;
    private const int MaximumElements = 2048;
    private const int MaximumDepth = 32;

    private sealed class Node(string name, JsonObject attributes)
    {
        public readonly StringBuilder Text = new();
        public readonly JsonArray Children = new();
        public JsonObject ToJson() => new() { ["name"] = name, ["attributes"] = attributes, ["text"] = Text.ToString(), ["children"] = Children };
    }

    public static string Parse(string source)
    {
        try
        {
            return Json.Stringify(new JsonObject { ["ok"] = true, ["value"] = ParseDocument(source) });
        }
        catch (Exception error) when (error is ArgumentException or XmlException)
        {
            return Json.Stringify(new JsonObject { ["ok"] = false, ["error"] = string.IsNullOrEmpty(error.Message) ? "Invalid XML" : error.Message });
        }
    }

    private static JsonObject ParseDocument(string source)
    {
        if (Encoding.UTF8.GetByteCount(source) > MaximumBytes) throw new ArgumentException($"XML exceeds the {MaximumBytes}-byte limit");
        if (Declaration().IsMatch(source)) throw new ArgumentException("XML document type and entity declarations are not allowed");
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null,
            IgnoreComments = true,
            IgnoreProcessingInstructions = true,
            MaxCharactersFromEntities = 0,
            MaxCharactersInDocument = MaximumBytes * 2L,
        };
        using var reader = XmlReader.Create(new StringReader(source), settings);
        var stack = new Stack<Node>();
        Node? root = null;
        var elements = 0;
        var textBytes = 0;
        void Close()
        {
            var node = stack.Pop();
            if (stack.TryPeek(out var parent)) parent.Children.Append(node.ToJson());
        }
        while (reader.Read())
        {
            switch (reader.NodeType)
            {
                case XmlNodeType.Element:
                {
                    elements += 1;
                    if (elements > MaximumElements) throw new ArgumentException($"XML exceeds the {MaximumElements}-element limit");
                    if (stack.Count >= MaximumDepth) throw new ArgumentException($"XML exceeds the {MaximumDepth}-level depth limit");
                    var attributes = new JsonObject();
                    var empty = reader.IsEmptyElement;
                    var name = reader.Name;
                    if (reader.MoveToFirstAttribute())
                    {
                        do { attributes[reader.Name] = reader.Value; } while (reader.MoveToNextAttribute());
                        reader.MoveToElement();
                    }
                    var node = new Node(name, attributes);
                    if (stack.Count == 0)
                    {
                        if (root is not null) throw new ArgumentException("XML has more than one root element");
                        root = node;
                    }
                    stack.Push(node);
                    if (empty) Close();
                    break;
                }
                case XmlNodeType.Text or XmlNodeType.CDATA or XmlNodeType.Whitespace or XmlNodeType.SignificantWhitespace:
                {
                    var text = reader.Value;
                    textBytes += Encoding.UTF8.GetByteCount(text);
                    if (textBytes > MaximumBytes) throw new ArgumentException($"XML text exceeds the {MaximumBytes}-byte limit");
                    if (stack.TryPeek(out var current)) current.Text.Append(text);
                    break;
                }
                case XmlNodeType.EntityReference: throw new ArgumentException("XML entity references are not allowed");
                case XmlNodeType.DocumentType: throw new ArgumentException("XML document type declarations are not allowed");
                case XmlNodeType.EndElement: Close(); break;
            }
        }
        return (root ?? throw new ArgumentException("XML has no root element")).ToJson();
    }

    [GeneratedRegex(@"<!\s*(DOCTYPE|ENTITY)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex Declaration();
}
