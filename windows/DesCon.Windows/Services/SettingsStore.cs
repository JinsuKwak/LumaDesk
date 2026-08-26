using System.Text.Json;
using System.Text.Json.Serialization;
using DesCon.Windows.Models;

namespace DesCon.Windows.Services;

public sealed class SettingsStore
{
    private readonly string _path;
    private readonly JsonSerializerOptions _json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    public SettingsStore()
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DesCon");
        Directory.CreateDirectory(directory);
        _path = Path.Combine(directory, "settings.json");
    }

    public AppSettings Load()
    {
        try
        {
            return File.Exists(_path)
                ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(_path), _json) ?? new AppSettings()
                : new AppSettings();
        }
        catch
        {
            var backup = _path + ".invalid-" + DateTimeOffset.Now.ToUnixTimeSeconds();
            if (File.Exists(_path)) File.Copy(_path, backup, overwrite: true);
            return new AppSettings();
        }
    }

    public void Save(AppSettings settings)
    {
        settings.Revision++;
        var temporary = _path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(settings, _json));
        File.Move(temporary, _path, overwrite: true);
    }
}
