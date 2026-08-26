using System.Runtime.InteropServices;

namespace DesCon.Windows.Services;

/// <summary>
/// Minimal dynamic binding to NVIDIA's public NVAPI I2C functions. The NVIDIA
/// display driver provides nvapi64.dll, so no SDK DLL or NuGet package ships
/// with DesCon. Function IDs and NV_I2C_INFO_V3 layout are from NVIDIA's MIT
/// licensed nvapi_interface.h and nvapi.h.
/// </summary>
public sealed class NvApiI2cService
{
    private const int NvApiOk = 0;
    private const uint InitializeId = 0x0150E828;
    private const uint GetAssociatedDisplayHandleId = 0x35C29134;
    private const uint GetPhysicalGpusFromDisplayId = 0x34EF9506;
    private const uint GetAssociatedDisplayOutputId = 0xD995937E;
    private const uint I2cWriteId = 0xE812EB07;
    private const int MaxPhysicalGpus = 64;

    private readonly InitializeDelegate? _initialize;
    private readonly GetDisplayHandleDelegate? _getDisplayHandle;
    private readonly GetPhysicalGpusDelegate? _getPhysicalGpus;
    private readonly GetOutputIdDelegate? _getOutputId;
    private readonly I2cWriteDelegate? _i2cWrite;

    public bool IsAvailable { get; }

    public NvApiI2cService()
    {
        try
        {
            _initialize = Bind<InitializeDelegate>(InitializeId);
            _getDisplayHandle = Bind<GetDisplayHandleDelegate>(GetAssociatedDisplayHandleId);
            _getPhysicalGpus = Bind<GetPhysicalGpusDelegate>(GetPhysicalGpusFromDisplayId);
            _getOutputId = Bind<GetOutputIdDelegate>(GetAssociatedDisplayOutputId);
            _i2cWrite = Bind<I2cWriteDelegate>(I2cWriteId);
            IsAvailable = _initialize() == NvApiOk;
        }
        catch (DllNotFoundException) { IsAvailable = false; }
        catch (EntryPointNotFoundException) { IsAvailable = false; }
        catch { IsAvailable = false; }
    }

    public bool TryWriteDdcPacket(
        string gdiDisplayName,
        byte packetSourceAddress,
        byte vcpCode,
        ushort value,
        out string error)
    {
        error = "";
        if (!IsAvailable || _getDisplayHandle is null || _getPhysicalGpus is null || _getOutputId is null || _i2cWrite is null)
        {
            error = "NVIDIA NVAPI is unavailable.";
            return false;
        }

        if (_getDisplayHandle(gdiDisplayName, out var displayHandle) != NvApiOk || displayHandle == IntPtr.Zero)
        {
            error = $"NVAPI could not map {gdiDisplayName}.";
            return false;
        }

        var gpuHandles = new IntPtr[MaxPhysicalGpus];
        if (_getPhysicalGpus(displayHandle, gpuHandles, out var gpuCount) != NvApiOk || gpuCount == 0)
        {
            error = "NVAPI could not find the physical GPU for this display.";
            return false;
        }

        if (_getOutputId(displayHandle, out var outputMask) != NvApiOk || outputMask == 0)
        {
            error = "NVAPI could not find the GPU output mask.";
            return false;
        }

        // Register address is the DDC packet source byte. NVAPI expects the I2C
        // slave address left-shifted, so DDC/CI 7-bit address 0x37 becomes 0x6E.
        var register = new[] { packetSourceAddress };
        var packet = new byte[]
        {
            0x84,
            0x03,
            vcpCode,
            (byte)(value >> 8),
            (byte)(value & 0xFF),
            0
        };
        packet[^1] = Checksum(0x6E, register, packet.AsSpan(0, packet.Length - 1));

        var registerPointer = Marshal.AllocHGlobal(register.Length);
        var packetPointer = Marshal.AllocHGlobal(packet.Length);
        try
        {
            Marshal.Copy(register, 0, registerPointer, register.Length);
            Marshal.Copy(packet, 0, packetPointer, packet.Length);

            var info = new NvI2cInfo
            {
                Version = (uint)(Marshal.SizeOf<NvI2cInfo>() | (3 << 16)),
                DisplayMask = outputMask,
                IsDdcPort = 1,
                I2cDeviceAddress = 0x6E,
                RegisterAddress = registerPointer,
                RegisterAddressSize = 1,
                Data = packetPointer,
                DataSize = (uint)packet.Length,
                I2cSpeedDeprecated = 0xFFFF,
                I2cSpeedKhz = 0,
                PortId = 0,
                IsPortIdSet = 0
            };

            var status = _i2cWrite(gpuHandles[0], ref info);
            if (status == NvApiOk) return true;
            error = $"NvAPI_I2CWrite failed ({status}).";
            return false;
        }
        finally
        {
            Marshal.FreeHGlobal(registerPointer);
            Marshal.FreeHGlobal(packetPointer);
        }
    }

    private static byte Checksum(byte seed, ReadOnlySpan<byte> register, ReadOnlySpan<byte> data)
    {
        var value = seed;
        foreach (var item in register) value ^= item;
        foreach (var item in data) value ^= item;
        return value;
    }

    private static T Bind<T>(uint id) where T : Delegate
    {
        var pointer = NvApiQueryInterface(id);
        if (pointer == IntPtr.Zero) throw new EntryPointNotFoundException($"NVAPI 0x{id:X8}");
        return Marshal.GetDelegateForFunctionPointer<T>(pointer);
    }

    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr NvApiQueryInterface(uint id);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int InitializeDelegate();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    private delegate int GetDisplayHandleDelegate([MarshalAs(UnmanagedType.LPStr)] string displayName, out IntPtr displayHandle);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int GetPhysicalGpusDelegate(
        IntPtr displayHandle,
        [Out, MarshalAs(UnmanagedType.LPArray, SizeConst = MaxPhysicalGpus)] IntPtr[] gpuHandles,
        out uint gpuCount);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int GetOutputIdDelegate(IntPtr displayHandle, out uint outputId);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int I2cWriteDelegate(IntPtr physicalGpu, ref NvI2cInfo i2cInfo);

    [StructLayout(LayoutKind.Sequential)]
    private struct NvI2cInfo
    {
        public uint Version;
        public uint DisplayMask;
        public byte IsDdcPort;
        public byte I2cDeviceAddress;
        public IntPtr RegisterAddress;
        public uint RegisterAddressSize;
        public IntPtr Data;
        public uint DataSize;
        public uint I2cSpeedDeprecated;
        public uint I2cSpeedKhz;
        public byte PortId;
        public uint IsPortIdSet;
    }
}
