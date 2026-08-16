using System.Collections;
using System.Text.Json;
using RszTool;

if (args.Length != 3)
{
    Console.Error.WriteLine("usage: RszAiDump <input-root> <output-root> <rszmhrise.json>");
    return 2;
}

var inputRoot = Path.GetFullPath(args[0]);
var outputRoot = Path.GetFullPath(args[1]);
var rszJson = Path.GetFullPath(args[2]);
if (!Directory.Exists(inputRoot)) throw new DirectoryNotFoundException(inputRoot);
if (!File.Exists(rszJson) || !Path.GetFileName(rszJson).Equals("rszmhrise.json", StringComparison.OrdinalIgnoreCase))
    throw new FileNotFoundException("Expected an rszmhrise.json type dump", rszJson);

Directory.CreateDirectory(outputRoot);
Environment.CurrentDirectory = Path.GetDirectoryName(rszJson)!;
var option = new RszFileOption(GameName.mhrise);
var succeeded = new List<string>();
var failures = new List<object>();

object? Encode(object? value)
{
    if (value is null) return null;
    if (value is RszInstance instance)
    {
        var reference = new Dictionary<string, object?>
        {
            ["$ref"] = instance.Index,
            ["$type"] = instance.RszClass.name,
        };
        if (instance.RSZUserData is RSZUserDataInfo info && info.Path is string path)
            reference["$userdata"] = path;
        return reference;
    }
    if (value is string or bool or byte or sbyte or short or ushort or int or uint or long or ulong or float or double or decimal)
        return value;
    if (value is Guid guid) return guid.ToString();
    if (value is IEnumerable enumerable)
    {
        var items = new List<object?>();
        foreach (var item in enumerable) items.Add(Encode(item));
        return items;
    }
    return value.ToString();
}

foreach (var source in Directory.EnumerateFiles(inputRoot, "*.user.*", SearchOption.AllDirectories).Order())
{
    var relative = Path.GetRelativePath(inputRoot, source).Replace('\\', '/');
    try
    {
        using var file = new UserFile(option, new FileHandler(source));
        if (!file.Read() || file.RSZ is null) throw new InvalidDataException("RSZ payload unavailable");
        var instances = file.RSZ.InstanceList.Select(instance => new
        {
            id = instance.Index,
            type = instance.RszClass.name,
            userdata = (instance.RSZUserData as RSZUserDataInfo)?.Path,
            fields = instance.Fields.Select((field, index) => new
            {
                name = field.name,
                type = field.DisplayType,
                value = Encode(instance.Values.ElementAtOrDefault(index)),
            }),
        });
        var document = new
        {
            schema_version = 1,
            source = relative,
            roots = file.RSZ.ObjectList.Select(instance => instance.Index),
            instances,
        };
        var destination = Path.Combine(outputRoot, relative + ".rsz.json");
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        File.WriteAllText(destination, JsonSerializer.Serialize(document, new JsonSerializerOptions { WriteIndented = true }) + Environment.NewLine);
        succeeded.Add(relative);
    }
    catch (Exception error)
    {
        failures.Add(new { source = relative, error = error.Message });
    }
}

var manifest = new
{
    schema_version = 1,
    parsed_count = succeeded.Count,
    failure_count = failures.Count,
    parsed_files = succeeded,
    failures,
};
File.WriteAllText(
    Path.Combine(outputRoot, "_manifest.json"),
    JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }) + Environment.NewLine
);
Console.WriteLine($"RSZ files parsed: {succeeded.Count}; failures: {failures.Count}");
return failures.Count == 0 ? 0 : 1;
