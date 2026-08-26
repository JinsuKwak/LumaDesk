using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using DesCon.Windows.Interop;
using DesCon.Windows.Models;
using Microsoft.Win32;

namespace DesCon.Windows.Services;

public static class ThemeManager
{
    public static void Apply(AppTheme theme)
    {
        var isLight = theme == AppTheme.Light || (theme == AppTheme.System && SystemUsesLightTheme());
        SetBrush("WindowBrush", isLight ? "#EAF4F5F8" : "#EE15171B");
        SetBrush("SurfaceBrush", isLight ? "#BFFFFFFF" : "#991F2228");
        SetBrush("SurfaceHoverBrush", isLight ? "#E6FFFFFF" : "#CC292D34");
        SetBrush("BorderBrush", isLight ? "#26000000" : "#35FFFFFF");
        SetBrush("PrimaryTextBrush", isLight ? "#FF17191D" : "#FFF4F5F7");
        SetBrush("SecondaryTextBrush", isLight ? "#FF60656E" : "#FFA5AAB3");
        SetBrush("AccentBrush", isLight ? "#FF1674D1" : "#FF4C9DFF");
        SetBrush("SuccessBrush", isLight ? "#FF168A4B" : "#FF34D17B");
        SetBrush("DangerBrush", isLight ? "#FFCA3434" : "#FFFF6B6B");
    }

    public static void ApplyBackdrop(Window window, AppTheme theme)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero) return;
        var isDark = theme == AppTheme.Dark || (theme == AppTheme.System && !SystemUsesLightTheme());
        var darkValue = isDark ? 1 : 0;
        NativeMethods.DwmSetWindowAttribute(handle, 20, ref darkValue, sizeof(int));

        // DWMSBT_MAINWINDOW enables Mica on Windows 11 and is ignored cleanly
        // on Windows 10, where the semi-transparent surface colors remain.
        var backdrop = 2;
        NativeMethods.DwmSetWindowAttribute(handle, 38, ref backdrop, sizeof(int));
    }

    private static bool SystemUsesLightTheme()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("AppsUseLightTheme") is not int value || value != 0;
    }

    private static void SetBrush(string key, string color)
    {
        Application.Current.Resources[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
    }
}
