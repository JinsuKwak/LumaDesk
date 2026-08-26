using System.Drawing;
using System.Windows.Forms;
using DesCon.Windows.Models;

namespace DesCon.Windows.Services;

public sealed class TrayIconService : IDisposable
{
    private readonly NotifyIcon _icon;
    private readonly Action _openSettings;
    private readonly Action _quit;
    private readonly Func<Guid, Task> _activate;

    public TrayIconService(Action openSettings, Action quit, Func<Guid, Task> activate)
    {
        _openSettings = openSettings;
        _quit = quit;
        _activate = activate;
        _icon = new NotifyIcon
        {
            Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? "") ?? SystemIcons.Application,
            Text = "DesCon",
            Visible = true
        };
        _icon.MouseClick += (_, eventArgs) =>
        {
            if (eventArgs.Button == MouseButtons.Left) _icon.ContextMenuStrip?.Show(Cursor.Position);
        };
    }

    public void Rebuild(AppSettings settings)
    {
        var menu = new ContextMenuStrip { ShowImageMargin = true };
        var favorite = settings.Profiles.FirstOrDefault(profile => profile.Id == settings.FavoriteProfileId);
        var primary = new ToolStripMenuItem(favorite is null ? "Choose a favorite profile" : $"Switch to {favorite.Name}")
        {
            Enabled = favorite is not null,
            Font = new Font(SystemFonts.MenuFont, FontStyle.Bold)
        };
        if (favorite is not null) primary.Click += async (_, _) => await _activate(favorite.Id);
        menu.Items.Add(primary);

        if (settings.Profiles.Count > 0)
        {
            var profiles = new ToolStripMenuItem("Profiles");
            foreach (var profile in settings.Profiles)
            {
                var item = new ToolStripMenuItem(profile.Name)
                {
                    Checked = profile.Id == settings.FavoriteProfileId,
                    ShortcutKeyDisplayString = profile.WindowsHotKey?.DisplayText ?? ""
                };
                item.Click += async (_, _) => await _activate(profile.Id);
                profiles.DropDownItems.Add(item);
            }
            menu.Items.Add(profiles);
        }

        menu.Items.Add(new ToolStripSeparator());
        var settingsItem = new ToolStripMenuItem("Settings…");
        settingsItem.Click += (_, _) => _openSettings();
        menu.Items.Add(settingsItem);
        menu.Items.Add(new ToolStripSeparator());
        var quitItem = new ToolStripMenuItem("Exit");
        quitItem.Click += (_, _) => _quit();
        menu.Items.Add(quitItem);

        var oldMenu = _icon.ContextMenuStrip;
        _icon.ContextMenuStrip = menu;
        oldMenu?.Dispose();
    }

    public void SetStatus(string status)
    {
        _icon.Text = status.Length <= 63 ? status : status[..60] + "…";
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.ContextMenuStrip?.Dispose();
        _icon.Dispose();
    }
}
