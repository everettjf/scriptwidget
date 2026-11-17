using System.Text.Json.Nodes;

namespace ScriptWidget.Core.Tests;

public class JsonTests
{
    [Fact]
    public void NumbersReadTheSameWhetherParsedOrBuiltInMemory()
    {
        var parsed = Json.ParseObject("""{"i":15,"d":1.5,"s":"42","b":true,"n":null}""");
        var built = new JsonObject { ["i"] = 15, ["d"] = 1.5, ["s"] = "42", ["b"] = true, ["n"] = null, ["l"] = 9_000_000_000L, ["f"] = 2.5f, ["m"] = 3.25m };
        foreach (var json in new[] { parsed, built })
        {
            Assert.Equal(15, json.OptInt("i"));
            Assert.Equal(1.5, json.OptDouble("d"));
            Assert.Equal(42, json.OptInt("s"));
            Assert.Equal(7, json.OptInt("b", 7));
            Assert.Equal(7, json.OptInt("n", 7));
            Assert.Equal(7, json.OptInt("missing", 7));
        }
        Assert.Equal(9_000_000_000L, built.OptLong("l"));
        Assert.Equal(2.5, built.OptDouble("f"));
        Assert.Equal(3.25, built.OptDouble("m"));
    }

    [Fact]
    public void TextAccessorsConvertScalarsLikeOrgJson()
    {
        var json = new JsonObject { ["s"] = "text", ["i"] = 3, ["b"] = false, ["o"] = new JsonObject(), ["n"] = null };
        Assert.Equal("text", json.OptString("s"));
        Assert.Equal("3", json.OptString("i"));
        Assert.Equal("false", json.OptString("b"));
        Assert.Equal("fallback", json.OptString("o", "fallback"));
        Assert.Equal("fallback", json.OptString("n", "fallback"));
        Assert.Null(json.OptStringOrNull("missing"));
        Assert.True(json.IsNull("n"));
        Assert.True(json.IsNull("missing"));
        Assert.False(json.IsNull("s"));
    }

    [Fact]
    public void StringifyKeepsNonAsciiTextReadable()
    {
        Assert.Equal("""{"a":"你好 <b> & 'c'"}""", Json.Stringify(new JsonObject { ["a"] = "你好 <b> & 'c'" }));
        Assert.Equal("\"line\\nbreak\"", Json.Quote("line\nbreak"));
        Assert.Equal("null", Json.Quote(null));
    }

    [Fact]
    public void AppendAddsObjectsValuesAndNulls()
    {
        var array = new JsonArray().Append(new JsonObject { ["k"] = 1 }).Append("text").Append((string?)null);
        Assert.Equal("""[{"k":1},"text",null]""", Json.Stringify(array));
    }
}
