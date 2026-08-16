using System.Collections;
using System.Text.Json;
using RszTool;

var includeTimingAssets = args.Length == 4 && args[3] == "--include-timing-assets";
if (args.Length != 3 && !includeTimingAssets)
{
    Console.Error.WriteLine("usage: RszAiDump <input-root> <output-root> <rszmhrise.json> [--include-timing-assets]");
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

object EncodeRsz(RSZFile rsz) => new
{
    roots = rsz.ObjectList.Select(instance => instance.Index),
    instances = rsz.InstanceList.Select(instance => new
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
    }),
};

void WriteDocument(string relative, string suffix, object document)
{
    var destination = Path.Combine(outputRoot, relative + suffix);
    Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
    File.WriteAllText(destination, JsonSerializer.Serialize(document, new JsonSerializerOptions { WriteIndented = true }) + Environment.NewLine);
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
        WriteDocument(relative, ".rsz.json", document);
        succeeded.Add(relative);
    }
    catch (Exception error)
    {
        failures.Add(new { source = relative, error = error.Message, exception_type = error.GetType().FullName, stack_trace = error.StackTrace });
    }
}


if (includeTimingAssets)
{
    foreach (var source in Directory.EnumerateFiles(inputRoot, "*.rcol.*", SearchOption.AllDirectories).Order())
    {
        var relative = Path.GetRelativePath(inputRoot, source).Replace('\\', '/');
        RcolFile? file = null;
        try
        {
            using var ownedFile = new RcolFile(option, new FileHandler(source));
            file = ownedFile;
            // RszTool 0.3.5 drops the final digit from multi-digit resource
            // extensions (".20" becomes 2). RCOL uses that version while
            // decoding its header, so correct the public value before Read().
            file.Header.ExtensionVersion = int.Parse(Path.GetExtension(source)[1..]);
            if (!file.Read() || file.RSZ is null) throw new InvalidDataException("RCOL RSZ payload unavailable");
            var document = new
            {
                schema_version = 1,
                asset_type = "rcol",
                source = relative,
                header = new
                {
                    group_count = file.Header.numGroups,
                    shape_count = file.Header.numShapes,
                    request_set_count = file.Header.numRequestSets,
                },
                groups = file.Groups.Select((group, index) => new
                {
                    index,
                    name = group.Info.Name,
                    layer_index = group.Info.LayerIndex,
                    mask_bits = group.Info.MaskBits,
                    userdata_index = group.Info.UserDataIndex,
                    shapes = group.Shapes.Select(shape => new
                    {
                        name = shape.Info.Name,
                        shape_type = shape.ShapeType.ToString(),
                        layer_index = shape.Info.LayerIndex,
                        attribute = shape.Info.Attribute,
                        primary_joint = shape.Info.primaryJointNameStr,
                        secondary_joint = shape.Info.secondaryJointNameStr,
                        userdata_index = shape.Info.UserDataIndex,
                        instance = shape.Instance?.Index,
                    }),
                }),
                request_sets = file.RequestSets.Select(request => new
                {
                    index = request.Index,
                    id = request.Info.ID,
                    name = request.Info.Name,
                    key_name = request.Info.KeyName,
                    group_index = request.Info.GroupIndex,
                    shape_offset = request.Info.ShapeOffset,
                    instance = request.Instance?.Index,
                }),
                payload = EncodeRsz(file.RSZ),
            };
            WriteDocument(relative, ".rcol.json", document);
            succeeded.Add(relative);
        }
        catch (Exception error)
        {
            failures.Add(new
            {
                source = relative,
                error = error.Message,
                exception_type = error.GetType().FullName,
                rcol_header = file is null ? null : new
                {
                    version = file.Header.Version.ToString(),
                    extension_version = file.Header.ExtensionVersion,
                    group_count = file.Header.numGroups,
                    groups_offset = file.Header.groupsPtrOffset,
                    data_offset = file.Header.dataOffset,
                },
                stack_trace = error.StackTrace,
            });
        }
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
Console.WriteLine($"Assets parsed: {succeeded.Count}; failures: {failures.Count}");
return failures.Count == 0 ? 0 : 1;
