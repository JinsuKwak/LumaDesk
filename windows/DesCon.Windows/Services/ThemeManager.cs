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
        SetBrush("WindowBrush", isLight ? "#F2F3F5F8" : "#F217191E");
        SetBrush("SidebarBrush", isLight ? "#DDF9FAFC" : "#B51D2026");
        SetBrush("SurfaceBrush", isLight ? "#D9FFFFFF" : "#A724272E");
        SetBrush("SurfaceRaisedBrush", isLight ? "#F2FFFFFF" : "#D22A2E36");
        SetBrush("SurfaceHoverBrush", isLight ? "#FFE8EBF0" : "#E1323740");
        SetBrush("InputBrush", isLight ? "#E8FFFFFF" : "#B51A1D22");
        SetBrush("BorderBrush", isLight ? "#24000000" : "#2FFFFFFF");
        SetBrush("DividerBrush", isLight ? "#16000000" : "#1FFFFFFF");
        SetBrush("PrimaryTextBrush", isLight ? "#FF17191D" : "#FFF4F5F7");
        SetBrush("SecondaryTextBrush", isLight ? "#FF60656E" : "#FFA5AAB3");
        SetBrush("AccentBrush", isLight ? "#FF1674D1" : "#FF4C9DFF");
        SetBrush("AccentSoftBrush", isLight ? "#211674D1" : "#294C9DFF");
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

        // Match the native Windows 11 frame to the app surface instead of
        // leaving the default black one-pixel border around the window.
        var borderColor = isDark ? 0x001E1917 : 0x00F8F5F3;
        NativeMethods.DwmSetWindowAttribute(handle, 34, ref borderColor, sizeof(int));

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
        System.Windows.Application.Current.Resources[key] = new SolidColorBrush(
            (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(color));
    }
}
